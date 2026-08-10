# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A multi-arch Alpine container image that turns an Xray client (VLESS/Trojan over REALITY or TLS) into a transparent gateway, intended to run as a MikroTik RouterOS container. It is pure POSIX shell + Docker — no compiled code, no test suite, no package manager.

Inside the container: `xray` exposes a local SOCKS5 proxy on `127.0.0.1:$SOCKS_PORT` (default `10800`), `tun2socks` bridges a `tun0` device to that proxy, and `start.sh` rewrites the container's routing table so everything except the Xray server itself, RFC1918 nets, and the DNS resolver goes through `tun0`. RouterOS then routes selected client traffic into the container's veth.

## Commands

All builds go through `make` (Docker buildx, multi-arch: `linux/amd64,linux/arm64,linux/arm/v7`):

```sh
make test                  # build locally + drop into a shell with ./scripts bind-mounted at /opt/develop
make build-to-file-arm64   # (also -arm, -amd64) → docker-xray-vless-<arch>.tar for RouterOS import
make build-push-docker     # push :latest and :$(XRAY_VERSION) to Docker Hub
make build-push-private    # same, to the private registry in $(PRIVATE_REPO)
```

**Config layering** — the Makefile `-include`s `.env` then `.env.local`, so later wins. `.env` **is committed** and holds the shared defaults/template (keys with empty values are normal); `.env.local` is gitignored and holds real per-developer values. Command line beats both (`make test TEST_URL=…`). Values are make syntax, not shell: unquoted, `#` starts a comment, `$` must be written `$$`.

Both files are also passed wholesale to the test container via `--env-file`, so any container-level variable (`SOCKS_PORT`, `CHECK_URL`, `LOCAL_NETS`, `IGNORE_RFC_PRIVATE_NETS`, `TUN_IP`) works by just naming it. The `TEST_` prefix exists only where the container's name differs: `TEST_URL`→`URL`, `TEST_XRAY_XMUX`→`XRAY_XMUX`, both mapped with an explicit `-e`. `$(call require_var,NAME,example)` guards the targets that need `TEST_URL` / `PRIVATE_REPO` / `DOCKERHUB_REPO`.

Every build target passes `--build-arg XRAY_VERSION=${XRAY_VERSION}`, so the Makefile is the single source of truth for the Xray version. The `ARG XRAY_VERSION` default in the Dockerfile only applies to a bare `docker build`; keep the two in sync when upgrading, since a stale default there is silent rather than fatal.

Manual smoke test of a config generator (no container needed, requires `jq`):

```sh
XRAY_CONFIG_FILE=/tmp/x.json XRAY_TYPE=xhttp XRAY_SECURITY=reality SERVER_ADDRESS=… XRAY_ID=… … \
  sh scripts/vless_xhttp_reality_config.sh && jq . /tmp/x.json
```

## Architecture

**Entrypoint flow** — [scripts/start.sh](scripts/start.sh):

1. `URL` env var is either a single `vless://`/`trojan://` link or an HTTP(S) subscription URL. Subscriptions are fetched with `curl` and base64-decoded into a whitespace-separated list of links; `main()` iterates them, calling `init()` then `cleanup()` per link, so a failing link falls through to the next one.
2. `init()` parses the link with `sed`/`cut` into exported variables: `XRAY_PROTO`, `XRAY_ID`, `SERVER_ADDRESS`, `SERVER_PORT`, and every query parameter as `XRAY_<KEY_UPPERCASED>` (URL-decoded, quote-escaped, `eval export`ed). So `?pbk=abc&sni=x` becomes `$XRAY_PBK` / `$XRAY_SNI`.
3. Config generator is selected purely by filename convention:
   `scripts/${XRAY_PROTO}_${XRAY_TYPE}_${XRAY_SECURITY}_config.sh`. Adding a new transport/security combination means adding a file with that exact name — nothing else needs to change in `start.sh`.
4. Routing is set up (see below), then `xray` and `tun2socks` are started in the background, health-checked, and `wait`ed on.
5. `trap cleanup EXIT INT` kills both PIDs, restores the original default route from `ORIG_GATEWAY_IP`/`ORIG_NET_IFACE`, and deletes `tun0`.

**Shared library** — [scripts/common.sh](scripts/common.sh) is sourced by `start.sh`, `healthcheck.sh` and all five generators (each does `SCRIPT_DIR=$(dirname "$0")` first, so every script must stay in the same directory). It owns the `log_*` helpers, the sole `SOCKS_PORT` default, `validate_socks_port`, and the generator helpers `config_init` / `require_vars` / `render_config`. Cross-cutting changes belong here, not in five copies.

**Config generators** — each `scripts/*_config.sh` is now just: source `common.sh`, `config_init`, log the target, `require_vars "…"`, then `render_config <jq args> '<jq program>'`. `render_config` supplies `--argjson socks_port`, merges the program onto [scripts/config_base.json](scripts/config_base.json) (which holds only the SOCKS inbound + empty routing), and writes to `$XRAY_CONFIG_FILE` **via a temp file + `mv`** — a direct redirect would truncate the target before `jq` runs, so bad JSON in `XRAY_XMUX`/`XRAY_EXTRA` would leave an empty config instead of the previous working one; every program starts with `.inbounds[0].port = $socks_port`, so the literal `10800` in `config_base.json` is only a standalone-valid placeholder. The reality/tls pairs differ only in `realitySettings` vs `tlsSettings` and their required vars.

Optional JSON-valued env vars (`XRAY_XMUX`, `XRAY_EXTRA`) are passed through `--argjson` and default to `null`, so they must be valid JSON if set.

**Routing** — done with `ip` inside `init()`: default route moved to `tun0` (`TUN_IP`, default `172.31.200.10/30`), with `/32` host route for the resolved server IP and for the first `/etc/resolv.conf` nameserver kept on the original gateway. `IGNORE_RFC_PRIVATE_NETS` (any value but `0`, and unset counts) keeps RFC1918 on the LAN gateway; `LOCAL_NETS` is a space-separated list of extra CIDRs to exclude.

**Health check** — [scripts/healthcheck.sh](scripts/healthcheck.sh) is both the Docker `HEALTHCHECK` and the post-start gate in `start.sh`. It verifies both processes, `tun0` up, the SOCKS port, and an end-to-end `curl --proxy socks5h` to `CHECK_URL` (default google.com).

## Conventions

- Everything targets Alpine `/bin/sh` (BusyBox ash), not bash — no arrays, no `[[ ]]`, no `${var,,}`.
- Comments and log strings mix Russian and English; keep matching the surrounding file.
- The README is the user-facing MikroTik setup guide, written in Russian. Its `/container envs` section still documents the older one-env-var-per-field interface (`SERVER_ADDRESS`, `PBK`, `SID`, …) and third-party `catesin/*` images; the current `start.sh` takes a single `URL` instead. Treat the scripts as the source of truth and flag the drift rather than silently trusting the README.
