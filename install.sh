#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/RedBoy-011/NordX-Pro.git"
BASE_DIR="/opt/NordX-Pro"

if [[ "${EUID}" -ne 0 ]]; then
  echo 'لطفاً اسکریپت را با دسترسی root (sudo) اجرا کنید.'
  exit 1
fi

echo "در حال نصب و بروزرسانی پیش‌نیازها..."
apt-get update -y
apt-get install -y git ca-certificates curl jq awk

if [[ -d "$BASE_DIR/.git" ]]; then
  cd "$BASE_DIR"
  git stash push -m "Auto backup before install" >/dev/null 2>&1 || true
  git pull --ff-only origin main
else
  mkdir -p "$(dirname "$BASE_DIR")"
  git clone "$REPO_URL" "$BASE_DIR"
  cd "$BASE_DIR"
fi

# سیستم خودترمیم: رفع خطای فاصله‌های غیرمجاز در فایل کانفیگ نسخه‌های قبل
if [[ -f "$BASE_DIR/.env" ]]; then
  awk 'BEGIN {FS="="; OFS="="} /^NODE_/ {gsub(/ /, "_", $1); print} !/^NODE_/ {print}' "$BASE_DIR/.env" > "$BASE_DIR/.env.tmp" && mv "$BASE_DIR/.env.tmp" "$BASE_DIR/.env"
fi

chmod +x "$BASE_DIR/nordx-manager.sh"

cat << 'EOF' > /usr/bin/nordx
#!/usr/bin/env bash
exec /opt/NordX-Pro/nordx-manager.sh "$@"
EOF
chmod +x /usr/bin/nordx

echo -e "\n✅ نصب با موفقیت انجام شد."
echo "شما می‌توانید با تایپ کلمه زیر در ترمینال، پنل را باز کنید:"
echo "nordx"
sleep 2

if [[ -r /dev/tty ]]; then
  exec /usr/bin/nordx </dev/tty
else
  exec /usr/bin/nordx
fi
