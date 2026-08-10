#!/bin/sh

SCRIPT_DIR=$(dirname "$0")
. "${SCRIPT_DIR}/common.sh"

config_init

log_info "Saving config TROJAN ${XRAY_TYPE} ${XRAY_SECURITY} to ${XRAY_CONFIG_FILE}"

require_vars "XRAY_TYPE XRAY_SECURITY SERVER_ADDRESS XRAY_ID XRAY_FP XRAY_SNI XRAY_PATH XRAY_MODE"

render_config \
  --arg type "$XRAY_TYPE" \
  --arg sec "$XRAY_SECURITY" \
  --arg addr "$SERVER_ADDRESS" \
  --argjson port "${SERVER_PORT:-443}" \
  --arg id "$XRAY_ID" \
  --arg fp "$XRAY_FP" \
  --arg sni "$XRAY_SNI" \
  --arg path "$XRAY_PATH" \
  --arg mode "$XRAY_MODE" \
  --arg xpb "${XRAY_X_PADDING_BYTES:-}" \
  --arg host "${XRAY_HOST:-}" \
  --argjson extra "${XRAY_EXTRA:-null}" \
  --argjson xmux "${XRAY_XMUX:-null}" \
  '.inbounds[0].port = $socks_port
  | .outbounds = [
    {
      "settings" : {
        "servers" : [
          {
            "port" : $port,
            "password" : $id,
            "address" : $addr
          }
        ]
      },
      "streamSettings" : {
        "tlsSettings" : {
          "serverName" : $sni,
          "enableSessionResumption" : true,
          "rejectUnknownSni" : true,
          "disableSystemRoot" : false,
          "fingerprint" : $fp,
          "allowInsecure" : false,
        },
        "security" : $sec,
        "xhttpSettings" : {
          "path" : $path,
          "mode" : $mode,
          "host" : $host,
          "x_padding_bytes" : $xpb,
          "extra": $extra,
          "xmux": $xmux
        },
        "network" : $type
      },
      "tag": ("trojan" + "-" + $type + "-" + $sec),
      "protocol" : "trojan"
    }
  ]'
