#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
#  MTProto Guardian — Self-Healing Proxy Launcher
#  Автоматически устанавливает, запускает и восстанавливает MTProto
# ═══════════════════════════════════════════════════════════════════

# ─── Настройки ────────────────────────────────────────────────────
PROXY_PORT=${MTPROTO_PORT:-443}
PROXY_SECRET=${MTPROTO_SECRET:-""}          # оставь пустым — сгенерируется автоматически
INSTALL_DIR="/opt/mtproto-proxy"
LOG_FILE="/var/log/mtproto_guardian.log"
PID_FILE="/var/run/mtproto_proxy.pid"
MAX_RESTARTS=999999                         # фактически бесконечно
RESTART_DELAY=5                             # секунд между перезапусками
HEALTH_CHECK_INTERVAL=30                    # секунд между проверками здоровья
MAX_CRASH_WINDOW=60                         # окно для подсчёта краш-петли (сек)
CRASH_LOOP_THRESHOLD=5                      # краш-петля если столько краш в окно
PYTHON_REPO="https://github.com/alexbers/mtprotoproxy.git"
GO_BINARY_URL="https://github.com/9seconds/mtg/releases/latest/download/mtg-linux-amd64"

# ─── Цвета ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ─── Логирование ──────────────────────────────────────────────────
log() {
    local level="$1"; shift
    local msg="$*"
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    local color="$NC"
    case "$level" in
        INFO)  color="$CYAN"   ;;
        OK)    color="$GREEN"  ;;
        WARN)  color="$YELLOW" ;;
        ERROR) color="$RED"    ;;
        HEAD)  color="$BOLD$BLUE" ;;
    esac
    echo -e "${color}[${ts}] [${level}] ${msg}${NC}" | tee -a "$LOG_FILE"
}

banner() {
    echo -e "${BOLD}${BLUE}"
    cat << 'EOF'
  ╔══════════════════════════════════════════════════════╗
  ║       MTProto Guardian  —  Self-Healing Proxy        ║
  ║         Автоматический запуск и восстановление       ║
  ╚══════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# ─── Утилиты ──────────────────────────────────────────────────────
is_root() { [[ $EUID -eq 0 ]]; }

cmd_exists() { command -v "$1" &>/dev/null; }

port_in_use() {
    ss -tlnp 2>/dev/null | grep -q ":${PROXY_PORT} " || \
    netstat -tlnp 2>/dev/null | grep -q ":${PROXY_PORT} "
}

get_public_ip() {
    curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
    curl -s --max-time 5 https://ifconfig.me 2>/dev/null || \
    echo "?"
}

generate_secret() {
    python3 -c "import secrets; print(secrets.token_hex(16))" 2>/dev/null || \
    openssl rand -hex 16 2>/dev/null || \
    cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 32 | head -n 1
}

# ─── Управление пакетами ──────────────────────────────────────────
detect_pkg_manager() {
    if cmd_exists apt-get; then echo "apt"
    elif cmd_exists yum;     then echo "yum"
    elif cmd_exists dnf;     then echo "dnf"
    elif cmd_exists pacman;  then echo "pacman"
    else echo "unknown"; fi
}

install_pkg() {
    local pkg="$1"
    local pm; pm=$(detect_pkg_manager)
    log INFO "Установка пакета: $pkg (менеджер: $pm)"
    case "$pm" in
        apt)    apt-get install -y -q "$pkg" 2>&1 | tail -3 ;;
        yum)    yum install -y "$pkg"  2>&1 | tail -3 ;;
        dnf)    dnf install -y "$pkg"  2>&1 | tail -3 ;;
        pacman) pacman -S --noconfirm "$pkg" 2>&1 | tail -3 ;;
        *)      log ERROR "Неизвестный пакетный менеджер!"; return 1 ;;
    esac
}

update_pkg_cache() {
    local pm; pm=$(detect_pkg_manager)
    log INFO "Обновление кэша пакетов..."
    case "$pm" in
        apt)    apt-get update -q 2>&1 | tail -2 ;;
        yum|dnf) : ;;
        pacman) pacman -Sy --noconfirm 2>&1 | tail -2 ;;
    esac
}

# ─── Проверка и установка зависимостей ───────────────────────────
ensure_dependency() {
    local dep="$1"
    local pkg="${2:-$1}"
    if ! cmd_exists "$dep"; then
        log WARN "Зависимость отсутствует: $dep — устанавливаю..."
        install_pkg "$pkg" && log OK "✓ $dep установлен" || {
            log ERROR "✗ Не удалось установить $dep"
            return 1
        }
    fi
}

install_dependencies() {
    log HEAD "=== Проверка зависимостей ==="
    update_pkg_cache
    ensure_dependency git git
    ensure_dependency python3 python3
    ensure_dependency pip3 python3-pip
    ensure_dependency curl curl
    ensure_dependency ss iproute2 || ensure_dependency netstat net-tools
    # Python зависимости
    for pymod in aiohttp asyncio; do
        python3 -c "import $pymod" 2>/dev/null || {
            log WARN "Python модуль $pymod отсутствует — устанавливаю..."
            pip3 install "$pymod" --quiet 2>&1 | tail -2
        }
    done
}

# ─── Методы установки MTProto ─────────────────────────────────────

# Метод 1: Python (alexbers/mtprotoproxy)
install_python_proxy() {
    log INFO "Установка MTProto (Python / alexbers)..."
    ensure_dependency git git || return 1
    ensure_dependency python3 python3 || return 1

    mkdir -p "$INSTALL_DIR"
    if [[ -d "$INSTALL_DIR/python" ]]; then
        log INFO "Репозиторий уже клонирован — обновляю..."
        git -C "$INSTALL_DIR/python" pull --quiet 2>&1 | tail -2
    else
        git clone --quiet "$PYTHON_REPO" "$INSTALL_DIR/python" 2>&1 | tail -2
    fi

    [[ -f "$INSTALL_DIR/python/mtprotoproxy.py" ]] || return 1
    echo "python_proxy" > "$INSTALL_DIR/.backend"
    log OK "✓ Python MTProto установлен"
}

# Метод 2: MTG (Go binary)
install_go_proxy() {
    log INFO "Установка MTG (Go бинарник)..."
    ensure_dependency curl curl || return 1
    mkdir -p "$INSTALL_DIR/bin"
    curl -sL "$GO_BINARY_URL" -o "$INSTALL_DIR/bin/mtg" 2>&1 | tail -2
    chmod +x "$INSTALL_DIR/bin/mtg"
    "$INSTALL_DIR/bin/mtg" --version &>/dev/null || return 1
    echo "go_proxy" > "$INSTALL_DIR/.backend"
    log OK "✓ MTG (Go) установлен"
}

# Метод 3: Docker (запасной)
install_docker_proxy() {
    log INFO "Попытка запуска через Docker..."
    ensure_dependency docker docker.io || ensure_dependency docker docker || return 1
    echo "docker_proxy" > "$INSTALL_DIR/.backend"
    log OK "✓ Docker бэкенд выбран"
}

install_mtproto() {
    log HEAD "=== Установка MTProto прокси ==="
    mkdir -p "$INSTALL_DIR"

    # Попробуй методы по очереди
    install_python_proxy && return 0
    log WARN "Python метод не удался — пробую Go бинарник..."
    install_go_proxy && return 0
    log WARN "Go метод не удался — пробую Docker..."
    install_docker_proxy && return 0

    log ERROR "Все методы установки провалились!"
    return 1
}

# ─── Конфигурация ─────────────────────────────────────────────────
setup_config() {
    mkdir -p "$INSTALL_DIR"
    local backend; backend=$(cat "$INSTALL_DIR/.backend" 2>/dev/null || echo "python_proxy")

    # Генерация секрета если не задан
    if [[ -z "$PROXY_SECRET" ]]; then
        if [[ -f "$INSTALL_DIR/.secret" ]]; then
            PROXY_SECRET=$(cat "$INSTALL_DIR/.secret")
            log INFO "Использую сохранённый секрет"
        else
            PROXY_SECRET=$(generate_secret)
            echo "$PROXY_SECRET" > "$INSTALL_DIR/.secret"
            log OK "Сгенерирован новый секрет: $PROXY_SECRET"
        fi
    fi

    if [[ "$backend" == "python_proxy" ]]; then
        cat > "$INSTALL_DIR/python/config.py" << EOF
# MTProto Proxy config (авто-сгенерировано Guardian'ом)
PORT = $PROXY_PORT
USERS = {
    "guardian_user": "$PROXY_SECRET",
}
# Режим fake-TLS (рекомендован)
AD_TAG = ""  # опционально: тег для статистики @MTProxybot
EOF
    fi
}

# ─── Запуск прокси ────────────────────────────────────────────────
start_proxy() {
    local backend; backend=$(cat "$INSTALL_DIR/.backend" 2>/dev/null || echo "python_proxy")
    log INFO "Запускаю прокси (бэкенд: $backend)..."

    # Освободи порт если занят
    if port_in_use; then
        log WARN "Порт $PROXY_PORT занят — пытаюсь освободить..."
        fuser -k "${PROXY_PORT}/tcp" 2>/dev/null || true
        sleep 2
    fi

    case "$backend" in
        python_proxy)
            cd "$INSTALL_DIR/python" || return 1
            python3 mtprotoproxy.py &
            ;;
        go_proxy)
            "$INSTALL_DIR/bin/mtg" run \
                --bind "0.0.0.0:$PROXY_PORT" \
                "dd${PROXY_SECRET}" &
            ;;
        docker_proxy)
            docker run -d --rm \
                --name mtproto_guardian \
                -p "${PROXY_PORT}:443" \
                telegrammessenger/proxy:latest \
                -p 443 -s "$PROXY_SECRET" &
            ;;
        *)
            log ERROR "Неизвестный бэкенд: $backend"
            return 1
            ;;
    esac

    echo $! > "$PID_FILE"
    log OK "Прокси запущен (PID: $!)"
}

# ─── Диагностика и авто-исправление ──────────────────────────────
diagnose_and_fix() {
    local exit_code="$1"
    log WARN "Диагностика сбоя (exit code: $exit_code)..."

    # Проверка свободного места на диске
    local disk_free; disk_free=$(df / | awk 'NR==2{print $4}')
    if [[ "$disk_free" -lt 102400 ]]; then  # < 100MB
        log WARN "Мало места на диске! Очищаю кэш..."
        apt-get clean 2>/dev/null || yum clean all 2>/dev/null || true
        journalctl --vacuum-size=50M 2>/dev/null || true
        find /tmp -mtime +1 -delete 2>/dev/null || true
    fi

    # Проверка памяти
    local mem_free; mem_free=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo 999999)
    if [[ "$mem_free" -lt 51200 ]]; then  # < 50MB
        log WARN "Мало оперативной памяти! Сбрасываю кэши..."
        sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    fi

    # Порт занят другим процессом?
    if port_in_use; then
        log WARN "Порт $PROXY_PORT занят — принудительно освобождаю..."
        fuser -k "${PROXY_PORT}/tcp" 2>/dev/null || true
        sleep 2
    fi

    # Файлы прокси повреждены/удалены?
    local backend; backend=$(cat "$INSTALL_DIR/.backend" 2>/dev/null || echo "none")
    local needs_reinstall=false

    case "$backend" in
        python_proxy)
            [[ -f "$INSTALL_DIR/python/mtprotoproxy.py" ]] || needs_reinstall=true
            ;;
        go_proxy)
            [[ -x "$INSTALL_DIR/bin/mtg" ]] || needs_reinstall=true
            ;;
        *)
            needs_reinstall=true
            ;;
    esac

    if $needs_reinstall; then
        log WARN "Файлы прокси отсутствуют или повреждены — переустанавливаю..."
        rm -rf "$INSTALL_DIR" 2>/dev/null || true
        install_dependencies
        install_mtproto
        setup_config
    fi

    # Проверка подключения к интернету
    if ! curl -s --max-time 10 https://1.1.1.1 &>/dev/null; then
        log ERROR "Нет подключения к интернету! Жду 30 сек..."
        sleep 30
    fi

    # Обновить репозиторий если python бэкенд
    if [[ "$backend" == "python_proxy" && -d "$INSTALL_DIR/python/.git" ]]; then
        log INFO "Обновляю исходники MTProto..."
        git -C "$INSTALL_DIR/python" pull --quiet 2>&1 | tail -2 || true
    fi
}

# ─── Показ ссылки для подключения ────────────────────────────────
print_connection_info() {
    local ip; ip=$(get_public_ip)
    local secret; secret=$(cat "$INSTALL_DIR/.secret" 2>/dev/null || echo "$PROXY_SECRET")
    echo -e "\n${BOLD}${GREEN}══════════════════════════════════════════════"
    echo -e "  MTProto Proxy активен!"
    echo -e "══════════════════════════════════════════════${NC}"
    echo -e "  ${CYAN}IP:${NC}     ${ip}"
    echo -e "  ${CYAN}Порт:${NC}   ${PROXY_PORT}"
    echo -e "  ${CYAN}Секрет:${NC} ${secret}"
    echo -e ""
    echo -e "  ${YELLOW}Ссылка для Telegram:${NC}"
    echo -e "  ${GREEN}tg://proxy?server=${ip}&port=${PROXY_PORT}&secret=dd${secret}${NC}"
    echo -e "${BOLD}${GREEN}══════════════════════════════════════════════${NC}\n"
}

# ─── Главный цикл Guardian ───────────────────────────────────────
run_guardian() {
    local restart_count=0
    local crash_times=()

    while true; do
        # Запуск
        start_proxy
        local pid; pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
        print_connection_info

        # Мониторинг процесса
        while kill -0 "$pid" 2>/dev/null; do
            sleep "$HEALTH_CHECK_INTERVAL"

            # Дополнительная проверка: процесс жив, но порт не слушает?
            if ! port_in_use; then
                log WARN "Порт $PROXY_PORT не слушается — похоже прокси завис!"
                kill "$pid" 2>/dev/null || true
                break
            fi
        done

        local exit_code=$?
        local now; now=$(date +%s)
        crash_times+=("$now")

        # Очистка старых краш-меток за пределами окна
        crash_times=( $(for t in "${crash_times[@]}"; do
            [[ $((now - t)) -le $MAX_CRASH_WINDOW ]] && echo "$t"
        done) )

        # Краш-петля?
        if [[ ${#crash_times[@]} -ge $CRASH_LOOP_THRESHOLD ]]; then
            log ERROR "Обнаружена краш-петля (${#crash_times[@]} сбоев за ${MAX_CRASH_WINDOW}s)!"
            log WARN "Полная переустановка и длинная пауза (120s)..."
            rm -rf "$INSTALL_DIR" 2>/dev/null || true
            sleep 120
            install_dependencies
            install_mtproto
            setup_config
            crash_times=()
        fi

        restart_count=$((restart_count + 1))
        log WARN "Прокси упал (попытка #${restart_count}). Диагностика..."
        diagnose_and_fix "$exit_code"

        log INFO "Перезапуск через ${RESTART_DELAY}s..."
        sleep "$RESTART_DELAY"
    done
}

# ─── Обработка сигналов ───────────────────────────────────────────
cleanup() {
    log INFO "Получен сигнал завершения — останавливаю прокси..."
    local pid; pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"
    log OK "Остановлено."
    exit 0
}
trap cleanup SIGINT SIGTERM

# ─── Точка входа ──────────────────────────────────────────────────
main() {
    banner
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"

    if ! is_root; then
        log ERROR "Скрипт нужно запускать от root! (sudo $0)"
        exit 1
    fi

    log HEAD "=== MTProto Guardian запускается ==="
    log INFO "Порт: $PROXY_PORT | Лог: $LOG_FILE"

    # Первичная установка если нужно
    if [[ ! -f "$INSTALL_DIR/.backend" ]]; then
        log INFO "Первый запуск — устанавливаю MTProto..."
        install_dependencies
        install_mtproto || { log ERROR "Установка не удалась!"; exit 1; }
    fi

    setup_config
    run_guardian
}

main "$@"
