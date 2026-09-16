#!/bin/sh

SCRIPT_DIR=$(dirname "$0")
. "${SCRIPT_DIR}/common.sh"

config_init

log_info "Saving config VLESS ${XRAY_TYPE} ${XRAY_SECURITY} to ${XRAY_CONFIG_FILE}"

require_vars "XRAY_TYPE XRAY_SECURITY SERVER_ADDRESS XRAY_ID XRAY_FLOW XRAY_FP XRAY_SNI XRAY_PBK XRAY_SID XRAY_SPX"

# pqv (mldsa65Verify) 3x-ui отдаёт только если на инбаунде задан mldsa65Seed,
# поэтому он необязателен.
render_config \
  --arg type "$XRAY_TYPE" \
  --arg sec "$XRAY_SECURITY" \
  --arg addr "$SERVER_ADDRESS" \
  --argjson port "${SERVER_PORT:-443}" \
  --arg id "$XRAY_ID" \
  --arg enc "${XRAY_ENCRYPTION:-none}" \
  --arg flow "$XRAY_FLOW" \
  --arg fp "$XRAY_FP" \
  --arg sni "$XRAY_SNI" \
  --arg pbk "$XRAY_PBK" \
  --arg sid "$XRAY_SID" \
  --arg spx "$XRAY_SPX" \
  --arg pqv "${XRAY_PQV:-}" \
  '.inbounds[0].port = $socks_port
  | .outbounds = [
    {
      "protocol": "vless",
      "tag": ("vless" + "-" + $type + "-" + $sec),
      "settings": {
        "vnext": [
          {
            "address": $addr,
            "port": $port,
            "users": [
              {
                "id": $id,
                "encryption": $enc,
                "flow": $flow
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": $type,
        "security": $sec,
        "realitySettings": {
          "fingerprint": $fp,
          "serverName": $sni,
          "publicKey": $pbk,
          "shortId": $sid,
          "spiderX": $spx,
          "mldsa65Verify": $pqv
        }
      }
    }
  ]'
