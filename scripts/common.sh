#!/bin/sh
#
# Общие функции для start.sh, healthcheck.sh и генераторов конфига.
# Подключается как `. "${SCRIPT_DIR}/common.sh"`; SCRIPT_DIR должен быть задан до подключения.

# Единственное место, где живёт порт по умолчанию для локального SOCKS5 инбаунда.
SOCKS_PORT="${SOCKS_PORT:-10800}"

# Логирование
log_info() { echo -e "[INFO] $1"; }
log_success() { echo -e "[SUCCESS] $1"; }
log_warning() { echo -e "[WARNING] $1"; }
log_error() { echo -e "[ERROR] $1"; }

# SOCKS_PORT попадает в конфиг через jq --argjson, поэтому нечисловое значение
# сломало бы генерацию уже после усечения файла. Проверяем заранее.
validate_socks_port() {
    case "$SOCKS_PORT" in
        ''|*[!0-9]*)
            log_error "SOCKS_PORT must be a number (got '$SOCKS_PORT')"
            return 1
            ;;
    esac
    return 0
}

# Предусловия, общие для всех генераторов конфига.
config_init() {
    validate_socks_port || exit 1

    if [ -z "$XRAY_CONFIG_FILE" ]; then
        log_error "Environment variable XRAY_CONFIG_FILE is not set"
        exit 1
    fi

    if [ ! -f "${SCRIPT_DIR}/config_base.json" ]; then
        log_error "Error: Base config file '${SCRIPT_DIR}/config_base.json' not found!"
        exit 1
    fi
}

# Проверка обязательных переменных: require_vars "XRAY_TYPE XRAY_SECURITY ..."
require_vars() {
    for _var in $1; do
        if [ -z "$(eval "echo \$$_var")" ]; then
            log_error "Failed to extract $_var from URL"
            exit 1
        fi
    done
}

# Сборка конфига: render_config <аргументы jq...> <программа jq>
# Порт SOCKS-инбаунда подставляется здесь, поэтому генераторам достаточно
# сослаться на $socks_port в своей программе.
#
# Пишем во временный файл и переносим только при успехе: прямой редирект
# в $XRAY_CONFIG_FILE усекает файл ДО запуска jq, поэтому любая ошибка
# (невалидный JSON в XRAY_XMUX / XRAY_EXTRA, битый порт) оставляла бы
# пустой конфиг вместо предыдущего рабочего.
render_config() {
    _tmp="${XRAY_CONFIG_FILE}.tmp.$$"

    if jq --argjson socks_port "$SOCKS_PORT" "$@" \
            "${SCRIPT_DIR}/config_base.json" > "$_tmp"; then
        mv "$_tmp" "$XRAY_CONFIG_FILE"
        return 0
    fi

    rm -f "$_tmp"
    log_error "Failed to render config (invalid JSON in XRAY_XMUX / XRAY_EXTRA?)"
    return 1
}
