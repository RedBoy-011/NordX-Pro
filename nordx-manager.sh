#!/usr/bin/env bash
# Name: nordx-manager.sh
set -euo pipefail

PROJECT_DIR="/opt/NordX-Pro"
ENV_FILE="$PROJECT_DIR/.env"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"

cd "$PROJECT_DIR" || exit 1

# ==========================================
# دریافت اطلاعات اولیه (فقط بار اول)
# ==========================================
if [[ ! -f $ENV_FILE ]]; then
    clear
    echo "=== پیکربندی اولیه NordX-Pro ==="
    read -rp 'NordVPN Service Username: ' nv_user
    read -rsp 'NordVPN Service Password: ' nv_pass; echo
    
    echo -e "\nآیا SOCKS5 نیاز به نام کاربری و رمز عبور دارد؟ (y/n) [n]: " 
    read -r req_auth_input
    
    req_auth="false"
    sx_user=""
    sx_pass=""
    
    if [[ "$req_auth_input" == "y" || "$req_auth_input" == "Y" ]]; then
        req_auth="true"
        read -rp 'SOCKS5 Username: ' sx_user
        read -rsp 'SOCKS5 Password: ' sx_pass; echo
    fi
    
    cat <<EOF > $ENV_FILE
NORDVPN_USERNAME=$nv_user
NORDVPN_PASSWORD=$nv_pass
REQUIRE_AUTH=$req_auth
PROXY_USER=$sx_user
PROXY_PASSWORD=$sx_pass
EOF
    echo "تنظیمات ذخیره شد. این اطلاعات در آپدیت‌های بعدی پاک نخواهد شد."
    sleep 2
fi

source $ENV_FILE

# ==========================================
# تولید خودکار فایل داکر
# ==========================================
generate_compose() {
    cat <<EOF > $COMPOSE_FILE
services:
EOF
    
    grep "^NODE_" $ENV_FILE | while read -r line; do
        local node_id=$(echo "$line" | cut -d= -f1 | sed 's/NODE_//')
        local val=$(echo "$line" | cut -d= -f2)
        local country=$(echo "$val" | cut -d: -f1)
        local port=$(echo "$val" | cut -d: -f2)

        cat <<EOF >> $COMPOSE_FILE
  vpn-${node_id,,}:
    image: qmcgaw/gluetun:v3.40.0
    container_name: nord-socks-${node_id,,}
    cap_add: [NET_ADMIN]
    devices: [/dev/net/tun:/dev/net/tun]
    environment:
      - VPN_SERVICE_PROVIDER=nordvpn
      - VPN_TYPE=openvpn
      - OPENVPN_USER=\${NORDVPN_USERNAME}
      - OPENVPN_PASSWORD=\${NORDVPN_PASSWORD}
      - SERVER_COUNTRIES=${country}
      - TZ=Europe/Istanbul
    ports: ["127.0.0.1:${port}:1080"]
    restart: unless-stopped

  socks-${node_id,,}:
    image: serjs/go-socks5-proxy:latest
    network_mode: service:vpn-${node_id,,}
    environment:
      - REQUIRE_AUTH=\${REQUIRE_AUTH}
      - PROXY_USER=\${PROXY_USER}
      - PROXY_PASSWORD=\${PROXY_PASSWORD}
    depends_on: {vpn-${node_id,,}: {condition: service_healthy}}
    restart: unless-stopped

EOF
    done
}

# ==========================================
# مدیریت نودها
# ==========================================
list_nodes() {
    echo -e "\n--- لیست نودهای فعال ---"
    if ! grep -q "^NODE_" $ENV_FILE; then
        echo "هیچ نودی ثبت نشده است."
        return
    fi
    
    grep "^NODE_" $ENV_FILE | while read -r line; do
        local node_id=$(echo "$line" | cut -d= -f1 | sed 's/NODE_//')
        local val=$(echo "$line" | cut -d= -f2)
        local country=$(echo "$val" | cut -d: -f1)
        local port=$(echo "$val" | cut -d: -f2)
        local status=$(docker inspect -f '{{.State.Status}}' "nord-socks-${node_id,,}" 2>/dev/null || echo "توقف/ناموجود")
        
        printf "نود: %-4s | کشور: %-15s | پورت داخلی: %-6s | وضعیت: %s\n" "$node_id" "$country" "$port" "$status"
    done
}

add_node() {
    echo -e "\n--- افزودن نود جدید ---"
    read -rp 'نام کشور (مثلا Germany, Turkey, UAE): ' new_country
    read -rp 'شناسه نود (مثلا DE): ' node_id
    read -rp 'پورت SOCKS5 اختصاصی (مثلا 1081): ' new_port
    
    node_id=${node_id^^}
    
    echo "NODE_${node_id}=${new_country}:${new_port}" >> $ENV_FILE
    generate_compose
    
    echo "در حال اجرای نود ${new_country}..."
    docker compose up -d --remove-orphans
    
    echo "نود جدید مستقر شد. در حال انجام تست..."
    sleep 3
    test_node "$new_port"
}

remove_node() {
    list_nodes
    echo -e "\n--- حذف نود ---"
    read -rp 'شناسه نود برای حذف (مثلا DE): ' rm_id
    rm_id=${rm_id^^}
    
    if grep -q "^NODE_${rm_id}=" $ENV_FILE; then
        docker compose rm -sf "vpn-${rm_id,,}" "socks-${rm_id,,}" 2>/dev/null || true
        sed -i "/^NODE_${rm_id}=/d" $ENV_FILE
        generate_compose
        docker compose up -d --remove-orphans
        echo "نود $rm_id حذف شد و فایل داکر بروزرسانی گردید."
    else
        echo "شناسه نامعتبر است."
    fi
}

test_node() {
    local target_port=${1:-}
    if [[ -z "$target_port" ]]; then
        read -rp 'پورت SOCKS5 جهت تست (مثلا 1081): ' target_port
    fi
    
    echo "در حال تست ارتباط، لوکیشن و پینگ..."
    
    local auth_args=""
    if [[ "$REQUIRE_AUTH" == "true" ]]; then
        auth_args="-U $PROXY_USER:$PROXY_PASSWORD"
    fi

    local response
    response=$(curl $auth_args --silent --show-error --max-time 15 -w "\nTIME_TOTAL:%{time_total}" --socks5-hostname "127.0.0.1:$target_port" http://ip-api.com/json || echo "FAILED")
    
    if [[ "$response" == *"FAILED"* || -z "$response" ]]; then
         echo -e "❌ تست ناموفق بود. کانتینر در حال راه‌اندازی است یا اتصال مسدود شده است."
         return
    fi
    
    local body=$(echo "$response" | sed -e 's/TIME_TOTAL:.*//')
    local time_val=$(echo "$response" | grep -o 'TIME_TOTAL:.*' | cut -d: -f2)
    local ping_ms=$(awk "BEGIN {print int($time_val * 1000)}")
    local check_status=$(echo "$body" | jq -r '.status' 2>/dev/null || echo "fail")
    
    if [[ "$check_status" == "success" ]]; then
        echo -e "✅ اتصال برقرار شد:"
        echo "   - کشور: $(echo "$body" | jq -r '.country')"
        echo "   - آی‌پی: $(echo "$body" | jq -r '.query')"
        echo "   - آی‌اس‌پی: $(echo "$body" | jq -r '.isp')"
        echo "   - پینگ: ${ping_ms}ms"
    else
        echo "مشکل در دریافت اطلاعات از سرور تست."
    fi
}

update_project() {
    echo "در حال آپدیت از مخزن گیت‌هاب..."
    git stash push -m "Backup configs" >/dev/null 2>&1 || true
    git pull origin main
    chmod +x nordx-manager.sh
    echo "آپدیت انجام شد (اطلاعات اتصال شما حفظ شده است)."
}

uninstall_project() {
    read -rp 'آیا از حذف کامل کانتینرها، اطلاعات و پاک شدن اسکریپت اطمینان دارید؟ (y/n): ' confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        docker compose down -v || true
        rm -f /usr/local/bin/nordx
        cd /
        rm -rf "$PROJECT_DIR"
        echo "پروژه NordX-Pro به طور کامل حذف شد."
        exit 0
    fi
}

# ==========================================
# رابط کاربری منو
# ==========================================
while true; do
    echo -e "\n=============================================="
    echo "             NordX-Pro SOCKS Manager"
    echo "=============================================="
    echo "  1) لیست نودهای فعال"
    echo "  2) افزودن نود جدید"
    echo "  3) حذف یک نود"
    echo "  4) تست اتصال و پینگ نود"
    echo "  5) آپدیت اسکریپت از گیت‌هاب"
    echo "  6) حذف کامل پروژه"
    echo "  7) خروج"
    echo "=============================================="
    read -rp 'انتخاب شما [1-7]: ' choice

    case $choice in
        1) list_nodes ;;
        2) add_node ;;
        3) remove_node ;;
        4) test_node ;;
        5) update_project ;;
        6) uninstall_project ;;
        7) clear; exit 0 ;;
        *) echo "انتخاب نامعتبر." ;;
    esac
done
