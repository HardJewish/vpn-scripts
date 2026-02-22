#!/bin/bash

# ========================================
# Автоматическая установка 3X-UI с VLESS + Reality
# Версия: 2.0
# ========================================

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}"
echo "=========================================="
echo "  Автоустановка 3X-UI (VLESS + Reality)"
echo "=========================================="
echo -e "${NC}"

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Этот скрипт должен запускаться с правами root!${NC}"
   echo "Запустите: sudo bash $0"
   exit 1
fi

# Получить внешний IP
PUBLIC_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || curl -s ipinfo.io/ip)
if [ -z "$PUBLIC_IP" ]; then
    echo -e "${RED}Не удалось определить внешний IP. Введите вручную:${NC}"
    read -p "IP сервера: " PUBLIC_IP
fi

echo -e "${GREEN}Внешний IP: $PUBLIC_IP${NC}"

# Параметры (можно изменить)
PANEL_PORT=54321
PANEL_USER="admin"
PANEL_PASS=$(openssl rand -base64 12)  # Генерация случайного пароля
VLESS_PORT=443
SNI_DOMAIN="www.microsoft.com"  # Можно изменить на www.apple.com, login.live.com и т.д.

echo ""
echo -e "${YELLOW}=== Параметры установки ===${NC}"
echo "Порт панели: $PANEL_PORT"
echo "Логин панели: $PANEL_USER"
echo "Пароль панели: $PANEL_PASS"
echo "Порт VLESS: $VLESS_PORT"
echo "SNI домен: $SNI_DOMAIN"
echo ""
read -p "Продолжить? (y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
fi

# ========================================
# 1. Обновление системы
# ========================================
echo -e "${GREEN}[1/6] Обновление системы...${NC}"
apt update -qq && apt upgrade -y -qq
apt install -y curl wget jq qrencode socat ufw -qq

# ========================================
# 2. Настройка firewall
# ========================================
echo -e "${GREEN}[2/6] Настройка firewall...${NC}"
ufw --force enable
ufw allow $PANEL_PORT/tcp comment "3X-UI Panel"
ufw allow $VLESS_PORT/tcp comment "VLESS Reality"
ufw allow 22/tcp comment "SSH"
ufw reload

# ========================================
# 3. Установка 3X-UI
# ========================================
echo -e "${GREEN}[3/6] Установка 3X-UI...${NC}"
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) <<EOF
y
$PANEL_USER
$PANEL_PASS
$PANEL_PORT
EOF

# Подождать запуска
sleep 5

# ========================================
# 4. Генерация ключей для Reality
# ========================================
echo -e "${GREEN}[4/6] Генерация ключей Reality...${NC}"

# Определяем путь к xray (используем xray из 3X-UI, не ставим отдельный)
XRAY_BIN=""
for p in /usr/local/x-ui/bin/xray-linux-* /usr/local/bin/xray; do
    if [ -x "$p" ] 2>/dev/null; then
        XRAY_BIN="$p"
        break
    fi
done

if [ -z "$XRAY_BIN" ]; then
    echo -e "${RED}xray не найден! Устанавливаем...${NC}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    XRAY_BIN="/usr/local/bin/xray"
fi

echo "Используем xray: $XRAY_BIN"

# Генерация ключей Reality (совместимо с xray 24.x / 25.x / 26.x)
KEYS=$($XRAY_BIN x25519)

# xray 24.x: "Private key: xxx" / "Public key: yyy"
# xray 25+:  "PrivateKey: xxx"  / "Password: yyy"
PRIVATE_KEY=$(echo "$KEYS" | grep -i "private" | awk '{print $NF}')
PUBLIC_KEY=$(echo "$KEYS" | grep -iE "^(Public key|Password):" | awk '{print $NF}')

if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo -e "${RED}Ошибка генерации ключей!${NC}"
    echo "Вывод xray x25519:"
    echo "$KEYS"
    exit 1
fi

SHORT_ID=$(openssl rand -hex 8)
UUID=$($XRAY_BIN uuid)

echo "Private Key: $PRIVATE_KEY"
echo "Public Key: $PUBLIC_KEY"
echo "Short ID: $SHORT_ID"
echo "UUID: $UUID"

# ========================================
# 5. Добавление VLESS inbound через API 3X-UI
# ========================================
echo -e "${GREEN}[5/6] Настройка VLESS + Reality...${NC}"

# Отключаем standalone xray чтобы не конфликтовал с 3X-UI
if systemctl is-active --quiet xray 2>/dev/null; then
    echo "Останавливаем standalone xray (конфликт портов с 3X-UI)..."
    systemctl stop xray
    systemctl disable xray
fi

# Ждём запуска панели
echo "Ждём запуска 3X-UI..."
for i in $(seq 1 30); do
    if curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PANEL_PORT/login" | grep -q "200"; then
        break
    fi
    sleep 2
done

# Определяем реальный порт панели (3X-UI может использовать другой порт)
ACTUAL_PORT=$PANEL_PORT
if ! curl -s -o /dev/null "http://localhost:$PANEL_PORT/login" 2>/dev/null; then
    # Ищем порт в конфиге x-ui
    for try_port in $PANEL_PORT 2053 2054 2055; do
        if curl -s -o /dev/null "http://localhost:$try_port/login" 2>/dev/null; then
            ACTUAL_PORT=$try_port
            break
        fi
    done
fi

echo "Порт API: $ACTUAL_PORT"

# Логин в 3X-UI API
LOGIN_RESPONSE=$(curl -s -c /tmp/xui-cookies.txt \
    -X POST "http://localhost:$ACTUAL_PORT/login" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=${PANEL_USER}&password=${PANEL_PASS}")

LOGIN_OK=$(echo "$LOGIN_RESPONSE" | jq -r '.success // false')
if [ "$LOGIN_OK" != "true" ]; then
    echo -e "${RED}Не удалось авторизоваться в 3X-UI API!${NC}"
    echo "Ответ: $LOGIN_RESPONSE"
    echo -e "${YELLOW}Добавьте inbound вручную через панель: http://$PUBLIC_IP:$PANEL_PORT${NC}"
else
    echo "Авторизация в API успешна"

    # Формируем JSON для API (settings и streamSettings как экранированные строки)
    SETTINGS=$(jq -n -c \
        --arg uuid "$UUID" \
        '{clients: [{id: $uuid, flow: "xtls-rprx-vision", email: "client1", limitIp: 0, totalGB: 0, expiryTime: 0, enable: true}], decryption: "none", fallbacks: []}')

    STREAM_SETTINGS=$(jq -n -c \
        --arg sni "$SNI_DOMAIN" \
        --arg privkey "$PRIVATE_KEY" \
        --arg sid "$SHORT_ID" \
        '{network: "tcp", security: "reality", externalProxy: [], realitySettings: {show: false, xver: 0, dest: ($sni + ":443"), serverNames: [$sni], privateKey: $privkey, minClient: "", maxClient: "", maxTimediff: 0, shortIds: [$sid]}, tcpSettings: {acceptProxyProtocol: false, header: {type: "none"}}}')

    SNIFFING='{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false,"routeOnly":false}'

    API_RESPONSE=$(curl -s -b /tmp/xui-cookies.txt \
        -X POST "http://localhost:$ACTUAL_PORT/panel/api/inbounds/add" \
        -H "Content-Type: application/json" \
        -d "$(jq -n -c \
            --arg settings "$SETTINGS" \
            --arg stream "$STREAM_SETTINGS" \
            --arg sniff "$SNIFFING" \
            --argjson port "$VLESS_PORT" \
            '{up: 0, down: 0, total: 0, remark: "VLESS-Reality", enable: true, expiryTime: 0, listen: "", port: $port, protocol: "vless", settings: $settings, streamSettings: $stream, sniffing: $sniff}')")

    API_OK=$(echo "$API_RESPONSE" | jq -r '.success // false')
    if [ "$API_OK" = "true" ]; then
        echo -e "${GREEN}Inbound VLESS Reality успешно добавлен в 3X-UI!${NC}"
    else
        echo -e "${RED}Ошибка добавления inbound: $API_RESPONSE${NC}"
        echo -e "${YELLOW}Добавьте inbound вручную через панель${NC}"
    fi

    # Перезапустить xray через 3X-UI
    x-ui restart 2>/dev/null || true
    sleep 3
fi

# Очистка cookies
rm -f /tmp/xui-cookies.txt

# ========================================
# 6. Генерация URL и QR-кода
# ========================================
echo -e "${GREEN}[6/6] Генерация конфигурации клиента...${NC}"

# URL для клиента
VLESS_URL="vless://${UUID}@${PUBLIC_IP}:${VLESS_PORT}?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${SNI_DOMAIN}&sid=${SHORT_ID}&spx=%2F&flow=xtls-rprx-vision#VLESS-Reality"

# Сохранить конфиг
CONFIG_FILE="/root/vless-config.txt"
cat > $CONFIG_FILE <<EOF
========================================
  3X-UI + VLESS Reality - Конфигурация
========================================

📊 ПАНЕЛЬ УПРАВЛЕНИЯ:
   URL: http://$PUBLIC_IP:$PANEL_PORT
   Логин: $PANEL_USER
   Пароль: $PANEL_PASS

🔐 VLESS КОНФИГУРАЦИЯ:
   Протокол: VLESS + Reality
   IP: $PUBLIC_IP
   Порт: $VLESS_PORT
   UUID: $UUID
   Flow: xtls-rprx-vision
   SNI: $SNI_DOMAIN
   Public Key: $PUBLIC_KEY
   Short ID: $SHORT_ID

📱 URL ДЛЯ КЛИЕНТА:
$VLESS_URL

📋 КЛИЕНТЫ:
   - Android: v2rayNG, NekoBox
   - iOS: Shadowrocket, Streisand
   - Windows: Nekoray, v2rayN
   - macOS: V2RayXS

🔧 ПОЛЕЗНЫЕ КОМАНДЫ:
   Статус: x-ui status
   Рестарт: x-ui restart
   Логи: x-ui log
   Обновить: x-ui update

========================================
EOF

echo ""
echo -e "${GREEN}✅ Установка завершена!${NC}"
echo ""
cat $CONFIG_FILE
echo ""

# QR-код в терминале
echo -e "${YELLOW}QR-код для подключения:${NC}"
qrencode -t ANSIUTF8 "$VLESS_URL"

# Сохранить QR в PNG
qrencode -o /root/vless-qr.png "$VLESS_URL"
echo -e "${GREEN}QR-код сохранён: /root/vless-qr.png${NC}"
echo ""

# Проверка что всё работает
echo -e "${YELLOW}=== Проверка ===${NC}"
if ss -tlnp | grep -q ":$VLESS_PORT "; then
    echo -e "${GREEN}✅ Порт $VLESS_PORT слушается${NC}"
else
    echo -e "${RED}❌ Порт $VLESS_PORT не слушается! Проверьте: x-ui log${NC}"
fi

echo ""
echo -e "${YELLOW}⚠️  ВАЖНО:${NC}"
echo "1. Сохраните файл: $CONFIG_FILE"
echo "2. Смените пароль панели после первого входа!"
echo "3. Панель: http://$PUBLIC_IP:$PANEL_PORT"
echo ""
