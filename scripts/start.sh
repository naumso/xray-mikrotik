#!/bin/sh

# URL -- vless url (URL='vless://uuid@example.com:443?type=xhttp&security=reality&sni=example.com') or subscription url (URL='https://example.com/sub/fwu3923fsife')
#
# IGNORE_RFC_PRIVATE_NETS -- если задан (1/true/yes/on), частные сети RFC1918 тоже идут через VPN.
#                            По умолчанию (не задан) частные сети идут мимо VPN через LAN шлюз.
# LOCAL_NETS -- локальные сети через трафик к которым не должен идти через VPN (LOCAL_NETS=1.0.0.0/24 2.0.0.0/24)
# CHECK_URL -- url для проверки подключения (CHECK_URL=https://google.com)
# SOCKS_PORT -- порт локального SOCKS5 инбаунда xray (по умолчанию 10800)
# TUN_IP -- адрес tun-интерфейса внутри контейнера (по умолчанию 172.31.200.10)

SCRIPT_DIR=$(dirname "$0")
. "${SCRIPT_DIR}/common.sh"

CONFIG_FILE_PATH=/etc/xray.json
export SOCKS_PORT

# Адрес tun-интерфейса внутри контейнера (/30 сеть создаётся вокруг него)
TUN_IP="${TUN_IP:-172.31.200.10}"

# Global variables to track process IDs and state for rollback
XRAY_PID=""
TUN_PID=""
ORIG_GATEWAY_IP=""
ORIG_NET_IFACE=""
# Newline separated list of routes added by init(), newest first
ADDED_ROUTES=""

# Snapshot of the XRAY_* variables supplied by the container environment, so
# that per-link parsing can be rolled back without losing operator overrides
# (e.g. XRAY_XMUX / XRAY_EXTRA passed with `docker run -e`).
XRAY_ENV_BASE=$(env | grep '^XRAY_' | grep -v '^XRAY_CONFIG_FILE=')

is_true() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

# TUN_IP уходит в `ip addr add` / `ip route add`. Кривое значение там всплывает
# уже как отвалившаяся ссылка, поэтому проверяем формат заранее.
# Маску писать не нужно -- /30 добавляется скриптом.
validate_tun_ip() {
    case "$TUN_IP" in
        */*)
            log_error "TUN_IP must be a bare IPv4 address without a mask (got '$TUN_IP')"
            return 1
            ;;
    esac

    _n=0
    _old_ifs=$IFS
    IFS=.
    for _o in $TUN_IP; do
        _n=$((_n + 1))
        case "$_o" in
            ''|*[!0-9]*) IFS=$_old_ifs
                log_error "TUN_IP must be a valid IPv4 address (got '$TUN_IP')"
                return 1
                ;;
        esac
        if [ "$_o" -gt 255 ]; then
            IFS=$_old_ifs
            log_error "TUN_IP octet out of range (got '$TUN_IP')"
            return 1
        fi
    done
    IFS=$_old_ifs

    if [ "$_n" -ne 4 ]; then
        log_error "TUN_IP must be a valid IPv4 address (got '$TUN_IP')"
        return 1
    fi

    return 0
}

validate_socks_port || exit 1
validate_tun_ip || exit 1

# =============================================================================
# State helpers
# =============================================================================

# Drop everything init() derived from the previous link, then restore the
# operator supplied XRAY_* environment. Without this a link that omits a
# parameter silently inherits the previous link's value.
reset_state() {
    for _v in $(env | sed -n 's/^\(XRAY_[A-Za-z0-9_]*\)=.*/\1/p'); do
        unset "$_v"
    done
    unset SERVER_ADDRESS SERVER_PORT SERVER_IP QUERY

    if [ -n "$XRAY_ENV_BASE" ]; then
        _old_ifs=$IFS
        IFS='
'
        for _kv in $XRAY_ENV_BASE; do
            [ -n "$_kv" ] && export "$_kv"
        done
        IFS=$_old_ifs
    fi
}

# Add a route and remember it so cleanup() can remove exactly what we created.
add_route() {
    if ip route add "$@" 2>/dev/null; then
        ADDED_ROUTES="$*
$ADDED_ROUTES"
        return 0
    fi
    log_warning "Failed to add route: $*"
    return 1
}

# Terminate a background process and reap it, so the next iteration does not
# see a stale xray/tun2socks in the process table.
stop_proc() {
    _pid=$1
    _pname=$2

    [ -n "$_pid" ] || return 0
    kill -0 "$_pid" 2>/dev/null || return 0

    log_info "Stopping $_pname (PID: $_pid)..."
    kill "$_pid" 2>/dev/null

    _i=0
    while [ "$_i" -lt 10 ] && kill -0 "$_pid" 2>/dev/null; do
        sleep 0.5 2>/dev/null || sleep 1
        _i=$((_i + 1))
    done

    if kill -0 "$_pid" 2>/dev/null; then
        log_warning "$_pname did not stop, sending KILL"
        kill -9 "$_pid" 2>/dev/null
    fi

    wait "$_pid" 2>/dev/null
}

# =============================================================================
# Cleanup / Rollback Function
#
# Idempotent: it resets every global it acts on, so running it twice (per loop
# iteration and again from the EXIT trap) is a no-op the second time.
# =============================================================================
cleanup() {

    log_info "Cleaning up modified states..."

    # 1. Kill background processes if they exist
    stop_proc "$TUN_PID" "tun2socks"
    stop_proc "$XRAY_PID" "Xray core"
    TUN_PID=""
    XRAY_PID=""

    # 2. Remove the tun0 interface FIRST -- it owns the current default route,
    #    and the kernel refuses a second default route while it is still up.
    if ip link show tun0 >/dev/null 2>&1; then
        log_info "Removing tun0 interface..."
        ip link delete tun0 >/dev/null 2>&1
    fi

    # 3. Remove the routes we added (tun0 removal already took its own with it)
    if [ -n "$ADDED_ROUTES" ]; then
        _old_ifs=$IFS
        IFS='
'
        for _r in $ADDED_ROUTES; do
            [ -n "$_r" ] || continue
            IFS=$_old_ifs
            # shellcheck disable=SC2086 -- $_r is our own multi-word route spec
            ip route del $_r 2>/dev/null
            IFS='
'
        done
        IFS=$_old_ifs
        ADDED_ROUTES=""
    fi

    # 4. Restore the original default route if it is now missing
    if [ -n "$ORIG_GATEWAY_IP" ] && [ -n "$ORIG_NET_IFACE" ]; then
        _gw_re=$(printf '%s' "$ORIG_GATEWAY_IP" | sed 's/\./\\./g')
        if ! ip route show default 2>/dev/null | grep -qE "via ${_gw_re}( |$)"; then
            log_info "Restoring original default route via $ORIG_GATEWAY_IP..."
            if ! ip route add default via "$ORIG_GATEWAY_IP" dev "$ORIG_NET_IFACE" 2>/dev/null; then
                log_error "Failed to restore default route via $ORIG_GATEWAY_IP dev $ORIG_NET_IFACE"
            fi
        fi
        ORIG_GATEWAY_IP=""
        ORIG_NET_IFACE=""
    fi

    log_info "Cleanup complete."
}

on_signal() {
    log_info "Received shutdown signal, stopping..."
    cleanup
    exit 0
}

trap on_signal INT TERM HUP
trap cleanup EXIT

# =============================================================================
# Main script execution
# =============================================================================

main() {
    log_info "Starting setup container..."

    # Пример URL
    # url="vless://83b6b52d-b43b-4b82-8f1d-efg2323@vless.domain.com:443?type=xhttp&encryption=none&path=%2F&host=&mode=packet-up&security=reality&pbk=ishgesoig&fp=chrome&sni=www.microsoft.com&sid=segeg&spx=%2F&pqv=QqWTg7cE9qyd09YHVvpp_8SM1vSsf07xqHyXkFxBFtuVjh57PK-#myname"

    if [ -z "$URL" ]; then
        log_error "Environment variable URL is not set"
        log_info "Example URL format: https://xray.server.com/sub/fwu3923fsife or vless://uuid@xray.server.com:443?type=xhttp&security=reality&sni=example.com..."
        return 1
    fi

    # If URL is a subscription URL, fetch the actual URL
    if echo "$URL" | grep -q "^http"; then
        urls=$(curl -sfL "$URL" | base64 -d)

        if [ -z "$urls" ]; then
            log_error "Invalid subscription URL. Can\`t get vless config"
            return 1
        fi
    else
        urls="$URL"
    fi

    started_any=""

    # Read line by line (not `for url in $urls`) so that a node name containing
    # spaces does not split the URL, and so no pathname expansion happens.
    while IFS= read -r url; do
        url=$(printf '%s' "$url" | tr -d '\r')
        [ -n "$url" ] || continue

        case "$url" in
            *#*) name=${url##*#} ;;
            *)   name="unnamed" ;;
        esac

        log_info "Init '$name' VPN"

        reset_state

        if init "$url" "$name"; then
            started_any=1
        fi

        cleanup
    done <<EOF
$urls
EOF

    if [ -n "$started_any" ]; then
        log_warning "All configured VPN links have stopped."
    else
        log_error "No VPN link could be started."
    fi

    return 1
}

init() {

    url=$1
    name=$2

    export XRAY_PROTO=$(echo "$url" | cut -d':' -f1)

    # Validate URL format
    if [ "$XRAY_PROTO" != "vless" ] && [ "$XRAY_PROTO" != "trojan" ]; then
        log_error "Invalid URL format ($XRAY_PROTO). Must start with 'vless://' or 'trojan://' ($name)"
        return 1
    fi

    # Extract ID (user)
    export XRAY_ID=$(echo "$url" | sed -n 's|^[^:]*://\([^@]*\)@.*|\1|p')
    if [ -z "$XRAY_ID" ]; then
        log_error "Failed to extract ID from URL ($name)"
        return 1
    fi

    # Extract server address (hostname)
    export SERVER_ADDRESS=$(echo "$url" | sed -n 's|^[^:]*://[^@]*@\([^:/]*\).*|\1|p')
    if [ -z "$SERVER_ADDRESS" ]; then
        log_error "Failed to extract server address from URL ($name)"
        return 1
    fi

    # Extract server port. The pattern is anchored to the host part so that a
    # ":<digits>" inside a query value or the #fragment cannot be picked up.
    SERVER_PORT=$(printf '%s' "$url" | sed -n 's|^[^:]*://[^@]*@[^:/?#]*:\([0-9]\{1,5\}\).*|\1|p')
    [ -n "$SERVER_PORT" ] || SERVER_PORT="443"
    export SERVER_PORT

    # Извлекаем Query String (пустая, если '?' в URL нет)
    case "$url" in
        *\?*)
            QUERY=${url#*\?}
            QUERY=${QUERY%%#*}
            ;;
        *)
            QUERY=""
            ;;
    esac

    # Парсим параметры, переводим КЛЮЧИ в UPPERCASE.
    # Значения приходят из недоверенной подписки, поэтому имя переменной
    # строго проверяется и присваивание идёт без eval.
    old_ifs=$IFS
    IFS='&'
    for param in $QUERY; do

        case "$param" in
            *=*) ;;
            *) continue ;;
        esac

        key=$(printf '%s' "${param%%=*}" | tr '[:lower:]' '[:upper:]')
        val=${param#*=}

        case "$key" in
            ''|*[!A-Z0-9_]*)
                log_warning "Ignoring query parameter with unsupported name ($name)"
                continue
                ;;
            CONFIG_FILE|PROTO|ID)
                log_warning "Ignoring reserved query parameter '$key' ($name)"
                continue
                ;;
        esac

        # url decode
        val=$(printf '%b' "$(printf '%s' "$val" | sed 's/+/ /g; s/%\([0-9a-fA-F][0-9a-fA-F]\)/\\x\1/g')")

        export "XRAY_$key=$val"

    done
    IFS=$old_ifs

    # Check enviroment
    if [ -z "$XRAY_TYPE" ]; then
        log_error "Failed to extract TYPE from URL query params ($name)"
        return 1
    fi

    if [ -z "$XRAY_SECURITY" ]; then
        log_error "Failed to extract SECURITY from URL query params ($name)"
        return 1
    fi

    XRAY_TYPE=$(echo "$XRAY_TYPE" | tr '[:upper:]' '[:lower:]');
    XRAY_SECURITY=$(echo "$XRAY_SECURITY" | tr '[:upper:]' '[:lower:]');

    # XRAY_SECURITY is interpolated into a script path below, so keep it to a
    # plain identifier -- no separators, no path traversal.
    case "$XRAY_SECURITY" in
        *[!a-z0-9]*)
            log_error "Invalid SECURITY value in URL ($name)"
            return 1
            ;;
    esac

    if [ "$XRAY_TYPE" = "xhttp" ] || [ "$XRAY_TYPE" = "tcp" ]; then

        CONFIG_SCRIPT="${SCRIPT_DIR}/${XRAY_PROTO}_${XRAY_TYPE}_${XRAY_SECURITY}_config.sh"

        if [ ! -f "$CONFIG_SCRIPT" ]; then
            log_error "Config script $CONFIG_SCRIPT not found."
            return 1
        fi

        log_info "Config script $CONFIG_SCRIPT."

        # Set from a constant, never from the URL, so a query parameter cannot
        # redirect where the generated config is written and read from.
        export XRAY_CONFIG_FILE="$CONFIG_FILE_PATH"

        sh "$CONFIG_SCRIPT" || return 1;
    else
        log_error "Config generator for $XRAY_TYPE not found"
        return 1
    fi

    if echo "$SERVER_ADDRESS" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        SERVER_IP=$SERVER_ADDRESS
    else
        # Use getent or nslookup as fallback for 'host'
        SERVER_IP=$(getent hosts "$SERVER_ADDRESS" | awk '{print $1; exit}')
        [ -z "$SERVER_IP" ] && SERVER_IP=$(nslookup "$SERVER_ADDRESS" 2>/dev/null | awk '/Address/ {print $2}' | tail -n1)
    fi

    if [ -z "$SERVER_IP" ]; then
        log_error "Could not resolve $SERVER_ADDRESS";
        return 1;
    fi

    if ping -c 2 -W 2 "$SERVER_IP" > /dev/null 2>&1; then
        log_info "Xray server $SERVER_IP is accessible"
    else
        log_error "Xray server $SERVER_IP is unreachable"
        return 1;
    fi

    # --- Настройка маршрутизации ---
    # Read the default route once, so gateway and interface always come from
    # the same route entry.
    default_route=$(ip route show default 2>/dev/null | grep -vE 'dev (lo|tun)' | head -n 1)
    ORIG_GATEWAY_IP=$(printf '%s' "$default_route" | awk '{print $3}')
    ORIG_NET_IFACE=$(printf '%s' "$default_route" | awk '{print $5}')

    if [ -z "$ORIG_GATEWAY_IP" ] || [ -z "$ORIG_NET_IFACE" ]; then
        log_error "Failed to find default gateway / network interface"
        return 1
    fi

    log_info "Configuring routes (Gateway: $ORIG_GATEWAY_IP via $ORIG_NET_IFACE)"

    sleep 1

    ip link delete tun0 >/dev/null 2>&1
    ip tuntap add mode tun dev tun0
    ip addr add "${TUN_IP}/30" dev tun0
    ip link set dev tun0 up
    add_route "$SERVER_IP/32" via "$ORIG_GATEWAY_IP" dev "$ORIG_NET_IFACE"
    ip route del default via "$ORIG_GATEWAY_IP" dev "$ORIG_NET_IFACE"
    add_route default via "$TUN_IP"

    if is_true "$IGNORE_RFC_PRIVATE_NETS"; then
        log_info "IGNORE_RFC_PRIVATE_NETS is set: RFC1918 traffic goes through the VPN"
    else
        add_route 10.0.0.0/8 via "$ORIG_GATEWAY_IP" dev "$ORIG_NET_IFACE"
        add_route 172.16.0.0/12 via "$ORIG_GATEWAY_IP" dev "$ORIG_NET_IFACE"
        add_route 192.168.0.0/16 via "$ORIG_GATEWAY_IP" dev "$ORIG_NET_IFACE"
    fi

    if [ -n "$LOCAL_NETS" ]; then
        for net in $LOCAL_NETS; do
            add_route "$net" via "$ORIG_GATEWAY_IP" dev "$ORIG_NET_IFACE"
            log_info "Set LOCAL NET route $net -> $ORIG_GATEWAY_IP"
        done
    fi

    # exclude DNS ip from vpn
    DNS_IP=$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf)

    if [ -n "$DNS_IP" ]; then

        add_route "$DNS_IP/32" via "$ORIG_GATEWAY_IP"
        log_info "Set DNS route $DNS_IP -> $ORIG_GATEWAY_IP"
    fi

    log_info "Start Xray core"
    /opt/xray run -config "${XRAY_CONFIG_FILE}" &
    XRAY_PID=$!

    sleep 2

    if ! kill -0 $XRAY_PID 2>/dev/null; then
        log_error "Xray failed to start! Check your config.json or logs."
        return 1
    fi

    socks_ready=""
    for i in $(seq 1 10); do
        if nc -z 127.0.0.1 $SOCKS_PORT 2>/dev/null; then
            log_info "SOCKS port is up!"
            socks_ready=1
            break
        fi
        if ! kill -0 $XRAY_PID 2>/dev/null; then
            log_error "Xray exited while waiting for the SOCKS port"
            return 1
        fi
        log_warning "Port Xray ($SOCKS_PORT) not ready, retrying..."
        sleep 1
    done

    if [ -z "$socks_ready" ]; then
        log_error "Xray SOCKS port $SOCKS_PORT never became ready"
        return 1
    fi

    log_info "Start tun2socks"
    /opt/tun2socks -loglevel silent -tcp-sndbuf 3m -tcp-rcvbuf 3m -device tun0 -proxy socks5://127.0.0.1:$SOCKS_PORT -interface $ORIG_NET_IFACE &
    TUN_PID=$!

    sleep 2;

    if ! kill -0 $TUN_PID 2>/dev/null; then
        log_error "Tun2socks failed to start!"
        return 1
    fi

    health_ok=""
    for i in $(seq 1 5); do
        if sh "$SCRIPT_DIR/healthcheck.sh"; then
            health_ok=1
            break
        fi

        log_warning "VPN '$name' health check not pass..."
        sleep 1
    done

    if [ -z "$health_ok" ]; then
        log_error "VPN '$name' did not pass the health check"
        return 1
    fi

    log_success "VPN '$name' is up and running!"

    wait
}


# Execute main function
main "$@"
exit $?
