#!/bin/bash

# Стили и цвета
BOLD='\033[1m'
B_CYAN='\033[1;36m'
B_GREEN='\033[1;32m'
B_YELLOW='\033[1;33m'
B_RED='\033[1;31m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${B_RED}Ошибка: Запустите от имени root.${NC}"
    exit 1
fi

echo -e "${B_CYAN}Конфигурация автоматического обновления геофайлов для X-UI${NC}"

# --- Запрос времени обновления ---
echo -e "${B_YELLOW}Введите время для ежедневного обновления геофайлов (например, 03:30):${NC}"
read -p "Время [ЧЧ:ММ]: " USER_TIME

# Проверка ввода на соответствие формату ЧЧ:ММ
if [[ ! "$USER_TIME" =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    echo -e "${B_RED}Ошибка: Неверный формат времени. Используйте ЧЧ:ММ (например, 04:15). Выход.${NC}"
    exit 1
fi

# Разбиваем введенное время на часы и минуты для cron
CRON_MIN=$(echo "$USER_TIME" | cut -d: -f2)
CRON_HOUR=$(echo "$USER_TIME" | cut -d: -f1)

# Убираем ведущие нули, чтобы cron не воспринял их как восьмеричную систему (например, 08 -> 8)
CRON_MIN=$((10#$CRON_MIN))
CRON_HOUR=$((10#$CRON_HOUR))

# --- Создание скрипта-обёртки с откатом ---
WRAPPER="/usr/local/bin/xui-geofiles-update.sh"

cat > "$WRAPPER" <<'EOF'
#!/bin/bash
# Обновление геофайлов X-UI с автоматическим откатом, если Xray не запустился

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

XUI_DIR="/usr/local/x-ui"
BIN_DIR="$XUI_DIR/bin"
WAIT_SEC=30   # сколько секунд ждать запуска Xray после обновления

log() { logger -t xui-geofiles "$*"; }

# Защита от параллельного запуска
exec 9>/var/lock/xui-geofiles.lock
flock -n 9 || exit 0

if [ ! -d "$BIN_DIR" ]; then
    log "Каталог $BIN_DIR не найден, выход"
    exit 1
fi

# Проверка: Xray запущен и сервис x-ui активен
xray_ok() {
    local i
    for ((i = 0; i < WAIT_SEC; i += 2)); do
        if systemctl is-active --quiet x-ui && pgrep -f 'xray-linux' > /dev/null; then
            # Xray должен продержаться несколько секунд (не падать сразу)
            sleep 5
            systemctl is-active --quiet x-ui && pgrep -f 'xray-linux' > /dev/null && return 0
        fi
        sleep 2
    done
    return 1
}

# 1. Резервная копия текущих геофайлов
BACKUP_DIR=$(mktemp -d /tmp/xui-geo-backup.XXXXXX) || exit 1
trap 'rm -rf "$BACKUP_DIR"' EXIT

shopt -s nullglob
GEO_FILES=("$BIN_DIR"/geoip*.dat "$BIN_DIR"/geosite*.dat)
shopt -u nullglob

if [ ${#GEO_FILES[@]} -eq 0 ]; then
    log "Геофайлы в $BIN_DIR не найдены, выход"
    exit 1
fi
cp -a "${GEO_FILES[@]}" "$BACKUP_DIR"/

# 2. Обновление
x-ui update-all-geofiles > /dev/null 2>&1
UPDATE_RC=$?

# На случай, если x-ui сам не перезапустил сервис
systemctl restart x-ui > /dev/null 2>&1

# 3. Проверка
if [ $UPDATE_RC -eq 0 ] && xray_ok; then
    log "Геофайлы обновлены, Xray работает"
    exit 0
fi

# 4. Откат
log "Ошибка после обновления (код $UPDATE_RC) или Xray не запустился — откат геофайлов"
cp -af "$BACKUP_DIR"/*.dat "$BIN_DIR"/
systemctl restart x-ui > /dev/null 2>&1

if xray_ok; then
    log "Откат выполнен, Xray работает"
else
    log "ВНИМАНИЕ: после отката Xray всё равно не запустился, проверьте вручную"
fi
exit 1
EOF

chmod +x "$WRAPPER"

# Формируем строку для cron без логирования (вывод перенаправлен в /dev/null, результат пишется в syslog через logger)
C_JOB="$CRON_MIN $CRON_HOUR * * * $WRAPPER > /dev/null 2>&1"

# Удаляем старые задачи (прямой вызов x-ui и прошлую версию обёртки) и добавляем новую
(crontab -l 2>/dev/null | grep -v -e "x-ui update-all-geofiles" -e "$WRAPPER" ; echo "$C_JOB") | crontab -

echo -e "${B_GREEN}Задача cron успешно создана!${NC}"
echo -e "Геофайлы будут обновляться ежедневно в ${B_CYAN}${USER_TIME}${NC}."
echo -e "Если Xray не запустится после обновления, геофайлы будут восстановлены автоматически."
echo -e "Результат смотрите так: ${B_CYAN}journalctl -t xui-geofiles${NC}"
