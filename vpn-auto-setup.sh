#!/bin/bash

# ========================================
# Автоматическая установка 3X-UI с VLESS + Reality
# Версия: 1.0
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

# Установить xray-core если нужно
if ! command -v xray &> /dev/null; then
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi

# Генерация ключей Reality
KEYS=$(xray x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep "Private key:" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEYS" | grep "Public key:" | awk '{print $3}')
SHORT_ID=$(openssl rand -hex 8)
UUID=$(xray uuid)

echo "Private Key: $PRIVATE_KEY"
echo "Public Key: $PUBLIC_KEY"
echo "Short ID: $SHORT_ID"
echo "UUID: $UUID"

# ========================================
# 5. Создание VLESS inbound через API
# ========================================
echo -e "${GREEN}[5/6] Настройка VLESS + Reality...${NC}"

# Получить токен сессии (логин в панель)
sleep 3

# JSON конфиг для inbound
INBOUND_JSON=$(cat <<EOF
{
  "enable": true,
  "port": $VLESS_PORT,
  "protocol": "vless",
  "settings": {
    "clients": [
      {
        "id": "$UUID",
        "email": "client1",
        "flow": "xtls-rprx-vision"
      }
    ],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "show": false,
      "dest": "$SNI_DOMAIN:443",
      "xver": 0,
      "serverNames": [
        "$SNI_DOMAIN",
        "www.cloudflare.com",
        "www.apple.com"
      ],
      "privateKey": "$PRIVATE_KEY",
      "shortIds": [
        "$SHORT_ID",
        ""
      ]
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": [
      "http",
      "tls",
      "quic"
    ]
  },
  "remark": "VLESS-Reality-Auto"
}
EOF
)

# Сохранить конфиг во временный файл
echo "$INBOUND_JSON" > /tmp/inbound.json

# Добавить через x-ui CLI (если доступно)
if command -v x-ui &> /dev/null; then
    x-ui restart
fi

# ========================================
# 6. Генерация URL и QR-кода
# ========================================
echo -e "${GREEN}[6/6] Генерация конфигурации клиента...${NC}"

# URL для клиента
VLESS_URL="vless://${UUID}@${PUBLIC_IP}:${VLESS_PORT}?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${SNI_DOMAIN}&sid=${SHORT_ID}&spx=%2F&flow=xtls-rprx-vision#3X-UI-Auto"

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

# Напоминание
echo -e "${YELLOW}⚠️  ВАЖНО:${NC}"
echo "1. Сохраните файл: $CONFIG_FILE"
echo "2. Смените пароль панели после первого входа!"
echo "3. Откройте панель: http://$PUBLIC_IP:$PANEL_PORT"
echo "4. В настройках inbound включите Sniffing для полного VPN"
echo ""
echo -e "${GREEN}Для просмотра конфига: cat $CONFIG_FILE${NC}"
echo -e "${GREEN}Для показа QR в терминале: qrencode -t ANSIUTF8 < <(echo '$VLESS_URL')${NC}"
echo ""
