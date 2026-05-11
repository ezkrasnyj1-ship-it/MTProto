#!/bin/bash
# =====================================================
# MTProto Proxy — Авто-восстановление, порт 1443
# Запуск: sudo bash setup.sh
# Требует: root, Ubuntu/Debian
# =====================================================

PORT=1443
CONTAINER_NAME="mtproto-proxy"
SECRET_FILE="/etc/mtproto-secret"
WATCHDOG_SCRIPT="/usr/local/bin/mtproto-watchdog.sh"

# Список образов в порядке приоритета (если один не качается — берёт следующий)
IMAGES=(
    "ghcr.io/alexbers/mtprotoproxy:latest"
    "alexbers/mtprotoproxy:latest"
    "telegrammessenger/proxy:latest"
)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✅ $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠️  $*${NC}"; }
err()  { echo -e "${RED}[$(date '+%H:%M:%S')] ❌ $*${NC}"; }

[ "$(id -u)" -ne 0 ] && { err "Запустите от root: sudo bash setup.sh"; exit 1; }

# ── Установка Docker ──────────────────────────────────
install_docker() {
    warn "Docker не найден, устанавливаем..."
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin
    systemctl enable --now docker
    log "Docker установлен"
}

# ── Скачать образ с ретраями (сброс битого кеша перед каждой попыткой) ──
pull_image() {
    local img=$1
    for i in 1 2 3 4 5; do
        warn "Скачиваю $img (попытка $i/5)..."
        docker rmi "$img" 2>/dev/null || true   # сбрасываем битый кеш
        if docker pull --quiet "$img" 2>&1; then
            log "Образ $img скачан"; echo "$img"; return 0
        fi
        warn "Неудача, жду 15 сек..."; sleep 15
    done
    return 1
}

# ── Перебираем образы, берём первый рабочий ───────────
find_working_image() {
    for img in "${IMAGES[@]}"; do
        if WORKING_IMAGE=$(pull_image "$img"); then return 0; fi
        warn "Образ $img недоступен, пробую следующий..."
    done
    err "Не удалось скачать ни один образ MTProto"; exit 1
}

# ── Секрет ───────────────────────────────────────────
setup_secret() {
    if [ ! -f "$SECRET_FILE" ]; then
        SECRET=$(head -c 16 /dev/urandom | xxd -p)
        echo "$SECRET" > "$SECRET_FILE"; chmod 600 "$SECRET_FILE"
        log "Создан новый секрет"
    else
        SECRET=$(cat "$SECRET_FILE"); log "Загружен существующий секрет"
    fi
}

# ── Запуск контейнера ─────────────────────────────────
start_container() {
    local image=$1
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    log "Запускаю прокси на порте $PORT..."
    docker run -d \
        --name "$CONTAINER_NAME" \
        --restart=unless-stopped \
        --ulimit nofile=65536:65536 \
        -p "$PORT:443" \
        -e SECRET="$SECRET" \
        -e WORKERS=16 \
        -v mtproto-data:/data \
        "$image"
    sleep 4
    if docker ps --filter "name=$CONTAINER_NAME" --filter "status=running" | grep -q "$CONTAINER_NAME"; then
        SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
                    curl -s --max-time 5 https://ifconfig.me  2>/dev/null || echo "YOUR_IP")
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log "Прокси запущен!"
        echo -e "  ${GREEN}🌐 IP:${NC}     $SERVER_IP"
        echo -e "  ${GREEN}🔌 Порт:${NC}   $PORT"
        echo -e "  ${GREEN}🔑 Секрет:${NC} $SECRET"
        echo -e "  ${GREEN}🔗 Ссылка:${NC} tg://proxy?server=${SERVER_IP}&port=${PORT}&secret=${SECRET}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
        err "Контейнер упал сразу после запуска. Логи:"
        docker logs "$CONTAINER_NAME" 2>&1 | tail -30; exit 1
    fi
}

# ── Watchdog — следит и перезапускает автоматически ───
install_watchdog() {
    cat > "$WATCHDOG_SCRIPT" <<'WATCHDOG'
#!/bin/bash
CONTAINER_NAME="mtproto-proxy"
SECRET_FILE="/etc/mtproto-secret"
PORT=1443
IMAGES=("ghcr.io/alexbers/mtprotoproxy:latest" "alexbers/mtprotoproxy:latest" "telegrammessenger/proxy:latest")

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WATCHDOG] $*" | tee -a /var/log/mtproto-watchdog.log; }

pull_any_image() {
    for img in "${IMAGES[@]}"; do
        for i in 1 2 3 4 5; do
            docker rmi "$img" 2>/dev/null || true
            docker pull --quiet "$img" 2>&1 && echo "$img" && return 0
            sleep 15
        done
        log "Образ $img недоступен, пробую следующий"
    done
    return 1
}

get_current_image() {
    docker inspect --format='{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || echo "${IMAGES[0]}"
}

restart_proxy() {
    local SECRET; SECRET=$(cat "$SECRET_FILE" 2>/dev/null || head -c 16 /dev/urandom | xxd -p)
    local IMAGE; IMAGE=$(get_current_image)

    if ! docker image inspect "$IMAGE" &>/dev/null; then
        log "Образ $IMAGE отсутствует локально, скачиваю..."
        IMAGE=$(pull_any_image) || { log "КРИТИЧНО: Не удалось скачать образ"; return 1; }
    fi

    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    docker run -d \
        --name "$CONTAINER_NAME" \
        --restart=unless-stopped \
        --ulimit nofile=65536:65536 \
        -p "$PORT:443" \
        -e SECRET="$SECRET" \
        -e WORKERS=16 \
        -v mtproto-data:/data \
        "$IMAGE" \
        && log "Прокси перезапущен (образ: $IMAGE)" \
        || log "Перезапуск не удался"
}

log "Watchdog запущен, проверка каждые 30 сек"
while true; do
    sleep 30
    if ! docker ps --filter "name=$CONTAINER_NAME" --filter "status=running" | grep -q "$CONTAINER_NAME"; then
        log "Контейнер не работает! Перезапускаю..."
        restart_proxy
    fi
done
WATCHDOG

    chmod +x "$WATCHDOG_SCRIPT"
    cat > /etc/systemd/system/mtproto-watchdog.service <<EOF
[Unit]
Description=MTProto Proxy Watchdog
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
ExecStart=$WATCHDOG_SCRIPT
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now mtproto-watchdog
    log "Watchdog установлен и запущен"
}

# ── Лимиты системы для большого числа соединений ─────
tune_system() {
    grep -q "nofile 65536" /etc/security/limits.conf 2>/dev/null || \
        printf "* soft nofile 65536\n* hard nofile 65536\n" >> /etc/security/limits.conf
    sysctl -w net.core.somaxconn=65535       >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_max_syn_backlog=65535 >/dev/null 2>&1 || true
    log "Системные лимиты настроены (безлимит соединений)"
}

# ══════════════════════ MAIN ══════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   MTProto Proxy — Авто-установка v2"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

command -v docker &>/dev/null || install_docker
command -v xxd    &>/dev/null || apt-get install -y -qq xxd

tune_system
setup_secret
find_working_image
start_container "$WORKING_IMAGE"
install_watchdog

echo ""
log "Полезные команды:"
echo "  Логи прокси:   docker logs -f $CONTAINER_NAME"
echo "  Логи watchdog: journalctl -u mtproto-watchdog -f"
echo "  Статус:        docker ps | grep mtproto"
echo "  Секрет:        cat $SECRET_FILE"
