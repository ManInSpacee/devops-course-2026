#!/usr/bin/env bash
# Доставка статического ресурса на devops-vm
# Использование: scripts/deploy.sh [--dry-run]
set -euo pipefail

REMOTE="devops"                       # псевдоним из ~/.ssh/config
REMOTE_DIR="/var/www/devops-site"
SITE_URL="https://devops.local"
CA_CERT="${HOME}/devops.crt"
REPO_ROOT="$(git rev-parse --show-toplevel)"
LOCAL_DIR="${REPO_ROOT}/site/"

# 1. Разбор аргумента --dry-run
DRY_RUN=""
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN="--dry-run"
elif [[ -n "${1:-}" ]]; then
    echo "Неизвестный аргумент: $1" >&2
    echo "Использование: scripts/deploy.sh [--dry-run]" >&2
    exit 1
fi

# 2. Проверки перед доставкой
if [[ ! -f "${LOCAL_DIR}index.html" ]]; then
    echo "Ошибка: нет файла site/index.html, доставка отменена" >&2
    exit 1
fi

if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
    echo "Ошибка: есть незафиксированные изменения, доставка отменена" >&2
    git -C "$REPO_ROOT" status --short >&2
    exit 1
fi

# 3. Синхронизация: одно SSH-соединение, без интерактивного пароля
rsync -avz --delete --chmod=D755,F644 $DRY_RUN \
    -e "ssh -o BatchMode=yes -o ConnectTimeout=5" \
    "$LOCAL_DIR" "${REMOTE}:${REMOTE_DIR}/"

# 4. При --dry-run проверка доступности не нужна
if [[ -n "$DRY_RUN" ]]; then
    echo "Пробный запуск: сервер не изменён"
    exit 0
fi

# 5. Проверка доступности ресурса с проверкой сертификата
if ! curl -fsS --cacert "$CA_CERT" -o /dev/null "$SITE_URL"; then
    echo "Ошибка: ресурс ${SITE_URL} недоступен после доставки" >&2
    exit 1
fi

echo "Доставлен коммит $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
