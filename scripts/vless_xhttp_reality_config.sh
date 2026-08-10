#!/bin/sh

SCRIPT_DIR=$(dirname "$0")
. "${SCRIPT_DIR}/common.sh"

config_init

log_info "Saving config VLESS ${XRAY_TYPE} ${XRAY_SECURITY} to ${XRAY_CONFIG_FILE}"

require_vars "XRAY_TYPE XRAY_SECURITY SERVER_ADDRESS XRAY_ID XRAY_FP XRAY_SNI XRAY_PBK XRAY_SID XRAY_SPX XRAY_PQV XRAY_PATH XRAY_MODE"

render_config \
  --arg type "$XRAY_TYPE" \
  --arg sec "$XRAY_SECURITY" \
  --arg addr "$SERVER_ADDRESS" \
  --argjson port "${SERVER_PORT:-443}" \
  --arg id "$XRAY_ID" \
  --arg enc "${XRAY_ENCRYPTION:-none}" \
  --arg fp "$XRAY_FP" \
  --arg sni "$XRAY_SNI" \
  --arg pbk "$XRAY_PBK" \
  --arg sid "$XRAY_SID" \
  --arg spx "$XRAY_SPX" \
  --arg pqv "$XRAY_PQV" \
  --arg path "$XRAY_PATH" \
  --arg mode "$XRAY_MODE" \
  --arg host "${XRAY_HOST:-}" \
  --arg xpb "${XRAY_X_PADDING_BYTES:-100-1000}" \
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
        "realitySettings": {
          "fingerprint": $fp,
          "serverName": $sni,
          "publicKey": $pbk,
          "shortId": $sid,
          "spx": $spx,
          "pqv": $pqv
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
