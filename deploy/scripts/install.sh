#!/usr/bin/env bash
set -e

# --- Переменные и начальные проверки ---
APP_DIR=/opt/metalgpt
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
PROJECT_ROOT="$SCRIPT_DIR/../.."

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Функция для вывода ошибок
error_exit() {
    echo -e "${RED}[ОШИБКА]${NC} $1" >&2
    exit 1
}

# Функция для вывода успешных сообщений
success_msg() {
    echo -e "${GREEN}[OK]${NC} $1"
}

# Функция для вывода предупреждений
warning_msg() {
    echo -e "${YELLOW}[ВНИМАНИЕ]${NC} $1"
}

# Проверяем, что скрипт запущен от имени root
if [ "$EUID" -ne 0 ]; then
    error_exit "Пожалуйста, запустите этот скрипт от имени root или с использованием sudo"
fi

# Проверяем существование необходимых файлов
echo "Проверка наличия необходимых файлов..."
[ -f "$PROJECT_ROOT/backend/requirements.txt" ] || error_exit "Файл requirements.txt не найден в $PROJECT_ROOT/backend/"
[ -f "$PROJECT_ROOT/deploy/docker-compose.redis.yml" ] || error_exit "Файл docker-compose.redis.yml не найден"
[ -f "$PROJECT_ROOT/deploy/nginx/metalgpt.conf" ] || error_exit "Файл nginx/metalgpt.conf не найден"
[ -d "$PROJECT_ROOT/deploy/systemd" ] || error_exit "Директория deploy/systemd не найдена"
success_msg "Все необходимые файлы найдены"

# --- Управление пользователями и установка зависимостей ---
if ! id -u metalgpt &>/dev/null; then
    echo "Создание системного пользователя 'metalgpt'..."
    useradd -r -m -d "$APP_DIR" -s /usr/sbin/nologin metalgpt
    success_msg "Пользователь metalgpt создан"
else
    warning_msg "Пользователь metalgpt уже существует"
fi

echo "Обновление списка пакетов и установка зависимостей..."
apt update || error_exit "Не удалось обновить список пакетов"
apt install -y nginx python3-venv docker.io docker-compose-plugin || error_exit "Не удалось установить зависимости"
success_msg "Зависимости установлены"

# Добавляем пользователя metalgpt в группу docker
echo "Добавление пользователя metalgpt в группу docker..."
usermod -aG docker metalgpt
success_msg "Пользователь metalgpt добавлен в группу docker"

# --- Настройка приложения ---
echo "Настройка директории приложения..."
mkdir -p "$APP_DIR"/{logs,static,media,data}

# Копируем код приложения
echo "Копирование кода приложения..."
rsync -av --exclude='__pycache__' --exclude='*.pyc' --exclude='.git' \
    "$PROJECT_ROOT/backend/" "$APP_DIR/backend/" || error_exit "Не удалось скопировать код приложения"
success_msg "Код приложения скопирован"

echo "Настройка виртуального окружения Python..."
python3 -m venv "$APP_DIR/venv" || error_exit "Не удалось создать виртуальное окружение"
success_msg "Виртуальное окружение создано"

echo "Установка Python зависимостей..."
"$APP_DIR/venv/bin/pip" install -U pip || error_exit "Не удалось обновить pip"
"$APP_DIR/venv/bin/pip" install -r "$PROJECT_ROOT/backend/requirements.txt" || error_exit "Не удалось установить зависимости Python"
success_msg "Python зависимости установлены"

# Настройка переменных окружения (если есть пример)
if [ -f "$PROJECT_ROOT/.env.example" ]; then
    if [ ! -f "$APP_DIR/.env" ]; then
        echo "Копирование примера конфигурации .env..."
        cp "$PROJECT_ROOT/.env.example" "$APP_DIR/.env"
        warning_msg "Файл .env создан из примера. Не забудьте настроить его!"
    else
        warning_msg "Файл .env уже существует, пропускаем копирование"
    fi
fi

# Устанавливаем владельца директории
echo "Установка прав доступа..."
chown -R metalgpt:metalgpt "$APP_DIR"
success_msg "Права доступа установлены"

# --- Запуск Docker контейнеров ---
echo "Запуск Redis через Docker Compose..."
docker compose -f "$PROJECT_ROOT/deploy/docker-compose.redis.yml" up -d || error_exit "Не удалось запустить Redis"

# Проверяем, что Redis запустился
sleep 3
if docker compose -f "$PROJECT_ROOT/deploy/docker-compose.redis.yml" ps | grep -q "Up"; then
    success_msg "Redis успешно запущен"
else
    error_exit "Redis не запустился, проверьте логи: docker compose -f $PROJECT_ROOT/deploy/docker-compose.redis.yml logs"
fi

# --- Настройка системных служб и Nginx ---
echo "Настройка системных служб..."
cp "$PROJECT_ROOT/deploy/systemd/"*.service /etc/systemd/system/ || error_exit "Не удалось скопировать файлы служб"
systemctl daemon-reload || error_exit "Не удалось перезагрузить systemd"
success_msg "Файлы служб скопированы"

echo "Включение и запуск служб metalgpt-vllm и metalgpt-web..."
systemctl enable metalgpt-vllm metalgpt-web || warning_msg "Не удалось включить некоторые службы"
systemctl start metalgpt-vllm || warning_msg "Не удалось запустить metalgpt-vllm"
systemctl start metalgpt-web || warning_msg "Не удалось запустить metalgpt-web"

# Проверяем статус служб
sleep 3
echo "Проверка статуса служб..."
if systemctl is-active --quiet metalgpt-vllm; then
    success_msg "Служба metalgpt-vllm запущена"
else
    warning_msg "Служба metalgpt-vllm не активна, проверьте: systemctl status metalgpt-vllm"
fi

if systemctl is-active --quiet metalgpt-web; then
    success_msg "Служба metalgpt-web запущена"
else
    warning_msg "Служба metalgpt-web не активна, проверьте: systemctl status metalgpt-web"
fi

echo "Настройка Nginx..."
cp "$PROJECT_ROOT/deploy/nginx/metalgpt.conf" /etc/nginx/sites-available/metalgpt.conf || error_exit "Не удалось скопировать конфигурацию Nginx"

# Удаляем старую ссылку если существует и создаем новую
rm -f /etc/nginx/sites-enabled/metalgpt.conf
ln -s /etc/nginx/sites-available/metalgpt.conf /etc/nginx/sites-enabled/metalgpt.conf || error_exit "Не удалось создать симлинк"
success_msg "Конфигурация Nginx настроена"

echo "Проверка конфигурации Nginx..."
if nginx -t; then
    success_msg "Конфигурация Nginx корректна"
else
    error_exit "Конфигурация Nginx содержит ошибки"
fi

echo "Перезагрузка Nginx..."
systemctl reload nginx || error_exit "Не удалось перезагрузить Nginx"
success_msg "Nginx перезагружен"

# --- Итоговая информация ---
echo ""
echo "=========================================="
echo -e "${GREEN}Установка успешно завершена!${NC}"
echo "=========================================="
echo ""
echo "Полезные команды:"
echo "  Проверка статуса служб:"
echo "    systemctl status metalgpt-vllm"
echo "    systemctl status metalgpt-web"
echo "  Просмотр логов:"
echo "    journalctl -u metalgpt-vllm -f"
echo "    journalctl -u metalgpt-web -f"
echo "  Проверка Redis:"
echo "    docker compose -f $PROJECT_ROOT/deploy/docker-compose.redis.yml ps"
echo ""
if [ -f "$APP_DIR/.env" ]; then
    warning_msg "Не забудьте настроить файл $APP_DIR/.env перед использованием!"
fi
echo ""
