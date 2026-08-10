#!/bin/sh

# Configuration (SOCKS_PORT и его значение по умолчанию живут в common.sh)
SCRIPT_DIR=$(dirname "$0")
. "${SCRIPT_DIR}/common.sh"

# Default to google if URL isn't set
CHECK_URL="${CHECK_URL:-https://www.google.com}"

# 1. Check if Xray process is running
if ! pgrep xray > /dev/null; then
    echo "[FAIL] Xray process not found"
    exit 1
fi

# 2. Check if tun2socks process is running
if ! pgrep tun2socks > /dev/null; then
    echo "[FAIL] tun2socks process not found"
    exit 1
fi

# 3. Check if tun0 interface exists and is UP
if ! ip link show tun0 | grep -q "UP"; then
    echo "[FAIL] tun0 interface is down or missing"
    exit 1
fi

# 4. Check if SOCKS5 proxy is responding locally
if ! nc -z 127.0.0.1 $SOCKS_PORT; then
    echo "[FAIL] Xray SOCKS port $SOCKS_PORT is not reachable"
    exit 1
fi

# 5. Check https traffic to google.com (need DNS)
# Note: 'socks5h' ensures DNS is also resolved over the proxy
if ! curl -sf --proxy socks5h://127.0.0.1:${SOCKS_PORT} "${CHECK_URL}" --connect-timeout 5 --max-time 8 > /dev/null; then
    echo "[FAIL] Proxy connectivity check to $CHECK_URL failed"
    exit 1
fi

exit 0;