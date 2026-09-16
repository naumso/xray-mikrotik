#!/bin/sh

SCRIPT_DIR=$(dirname "$0")
. "${SCRIPT_DIR}/common.sh"

config_init

log_info "Saving config TROJAN ${XRAY_TYPE} ${XRAY_SECURITY} to ${XRAY_CONFIG_FILE}"

require_vars "XRAY_TYPE XRAY_SECURITY SERVER_ADDRESS XRAY_ID XRAY_FP XRAY_SNI XRAY_PATH XRAY_MODE"

# Если задан "extra", Xray берёт его целиком, а с верхнего уровня xhttpSettings
# оставляет только host/path/mode. Поэтому xmux кладём внутрь extra.
render_config \
  --arg type "$XRAY_TYPE" \
  --arg sec "$XRAY_SECURITY" \
  --arg addr "$SERVER_ADDRESS" \
  --argjson port "${SERVER_PORT:-443}" \
  --arg id "$XRAY_ID" \
  --arg fp "$XRAY_FP" \
  --arg sni "$XRAY_SNI" \
  --arg alpn "${XRAY_ALPN:-}" \
  --arg ech "${XRAY_ECH:-}" \
  --arg path "$XRAY_PATH" \
  --arg mode "$XRAY_MODE" \
  --arg xpb "${XRAY_X_PADDING_BYTES:-100-1000}" \
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
          "alpn" : (if $alpn == "" then null else ($alpn | split(",")) end),
          "echConfigList" : $ech,
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
          "xPaddingBytes" : $xpb,
          "extra": (if $xmux == null then $extra
                    else ($extra // {"xPaddingBytes": $xpb}) + {"xmux": $xmux} end)
        },
        "network" : $type
      },
      "tag": ("trojan" + "-" + $type + "-" + $sec),
      "protocol" : "trojan"
    }
  ]'
