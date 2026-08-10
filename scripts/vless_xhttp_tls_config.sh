#!/bin/sh

SCRIPT_DIR=$(dirname "$0")
. "${SCRIPT_DIR}/common.sh"

config_init

log_info "Saving config VLESS ${XRAY_TYPE} ${XRAY_SECURITY} to ${XRAY_CONFIG_FILE}"

require_vars "XRAY_TYPE XRAY_SECURITY SERVER_ADDRESS XRAY_ID XRAY_FP XRAY_SNI XRAY_PATH XRAY_MODE"

render_config \
  --arg type "$XRAY_TYPE" \
  --arg sec "$XRAY_SECURITY" \
  --arg addr "$SERVER_ADDRESS" \
  --argjson port "${SERVER_PORT:-443}" \
  --arg enc "${XRAY_ENCRYPTION:-none}" \
  --arg id "$XRAY_ID" \
  --arg fp "$XRAY_FP" \
  --arg sni "$XRAY_SNI" \
  --arg pqv "$XRAY_PQV" \
  --arg path "$XRAY_PATH" \
  --arg mode "$XRAY_MODE" \
  --arg xpb "${XRAY_X_PADDING_BYTES:-}" \
  --arg host "${XRAY_HOST:-}" \
  --argjson extra "${XRAY_EXTRA:-null}" \
  --argjson xmux "${XRAY_XMUX:-null}" \
  '.inbounds[0].port = $socks_port
  | .outbounds = [
    {
      "protocol": "vless",
      "tag": ("vless" + "-" + $type + "-" + $sec),
      "settings": {
        "vnext": [{
          "address": $addr,
          "port": $port,
          "users": [{ "id": $id, "encryption": $enc }]
        }]
      },
      "streamSettings": {
        "network": $type,
        "security": $sec,
        "tlsSettings" : {
          "serverName" : $sni,
          "enableSessionResumption" : true,
          "rejectUnknownSni" : true,
          "disableSystemRoot" : false,
          "fingerprint" : $fp,
          "allowInsecure" : false,
        },
        "xhttpSettings": {
          "path" : $path,
          "mode" : $mode,
          "host" : $host,
          "pqv": $pqv,
          "x_padding_bytes" : $xpb,
          "extra": $extra,
          "xmux": $xmux
        }
      }
    }
  ]'
