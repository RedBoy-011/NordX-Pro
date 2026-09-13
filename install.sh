#!/usr/bin/env bash
# Name: install.sh
set -euo pipefail

REPO_URL="https://github.com/RedBoy-011/NordX-Pro.git"
BASE_DIR="/opt/NordX-Pro"

if [[ "${EUID}" -ne 0 ]]; then
  echo 'لطفاً اسکریپت را با دسترسی root (sudo) اجرا کنید.'
  exit 1
fi

echo "در حال نصب پیش‌نیازها..."
apt-get update -y
apt-get install -y git ca-certificates curl jq

if [[ -d "$BASE_DIR/.git" ]]; then
  cd "$BASE_DIR"
  git stash push -m "Auto backup before install" >/dev/null 2>&1 || true
  git pull --ff-only origin main
else
  mkdir -p "$(dirname "$BASE_DIR")"
  git clone "$REPO_URL" "$BASE_DIR"
  cd "$BASE_DIR"
fi

chmod +x nordx-manager.sh

# ساخت میان‌بر سراسری برای ترمینال
ln -sf "$BASE_DIR/nordx-manager.sh" /usr/local/bin/nordx

echo -e "\nنصب با موفقیت انجام شد."
echo "شما می‌توانید با تایپ کلمه زیر در ترمینال، پنل را باز کنید:"
echo "nordx"
sleep 2

exec nordx
