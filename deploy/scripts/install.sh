#!/usr/bin/env bash
set -e

# --- Переменные и начальные проверки ---
APP_DIR=/opt/metalgpt
# Получаем абсолютный путь к директории, где находится скрипт
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
# Переходим в корневую директорию проекта (предполагая, что install.sh находится в deploy/scripts)
PROJECT_ROOT="$SCRIPT_DIR/../.."

# Проверяем, что скрипт запущен от имени root
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите этот скрипт от имени root или с использованием sudo"
  exit 1
fi

# --- Управление пользователями и установка зависимостей ---
if ! id -u metalgpt &>/dev/null; then
    echo "Создание системного пользователя 'metalgpt'..."
    useradd -r -m -d "$APP_DIR" -s /usr/sbin/nologin metalgpt
fi

echo "Обновление списка пакетов и установка зависимостей..."
apt update
apt install -y nginx python3-venv docker.io docker-compose-plugin

# --- Настройка приложения ---
echo "Настройка директории приложения и виртуального окружения Python..."
mkdir -p "$APP_DIR"
python3 -m venv "$APP_DIR/venv"
chown -R metalgpt:metalgpt "$APP_DIR"
"$APP_DIR/venv/bin/pip" install -U pip
"$APP_DIR/venv/bin/pip" install -r "$PROJECT_ROOT/backend/requirements.txt"

echo "Запуск Redis через Docker Compose..."
docker compose -f "$PROJECT_ROOT/deploy/docker-compose.redis.yml" up -d

# --- Настройка системных служб и Nginx ---
echo "Настройка и запуск системных служб..."
cp "$PROJECT_ROOT/deploy/systemd/"*.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now metalgpt-vllm metalgpt-web

echo "Настройка Nginx..."
cp "$PROJECT_ROOT/deploy/nginx/metalgpt.conf" /etc/nginx/sites-available/metalgpt.conf
ln -sf /etc/nginx/sites-available/metalgpt.conf /etc/nginx/sites-enabled/

echo "Проверка конфигурации Nginx..."
nginx -t

echo "Перезагрузка Nginx..."
systemctl reload nginx

echo "Установка успешно завершена!"
