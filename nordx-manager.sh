#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="/opt/NordX-Pro"
ENV_FILE="$PROJECT_DIR/.env"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"

cd "$PROJECT_DIR" || exit 1

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
    
    cat <<EOF > "$ENV_FILE"
NORDVPN_USERNAME=$nv_user
NORDVPN_PASSWORD=$nv_pass
REQUIRE_AUTH=$req_auth
PROXY_USER=$sx_user
PROXY_PASSWORD=$sx_pass
EOF
    echo "تنظیمات ذخیره شد. این اطلاعات در آپدیت‌های بعدی پاک نخواهد شد."
    sleep 2
fi

if [[ -f "$ENV_FILE" ]]; then
    awk 'BEGIN {FS="="; OFS="="} /^NODE_/ {gsub(/ /, "_", $1); gsub(/ /, "_", $2); gsub(/"/, "", $2); print $1, $2} !/^NODE_/ {print}' "$ENV_FILE" > "${ENV_FILE}.tmp" && mv "${ENV_FILE}.tmp" "$ENV_FILE"
    grep -E '^(NORDVPN_USERNAME|NORDVPN_PASSWORD|REQUIRE_AUTH|PROXY_USER|PROXY_PASSWORD|NODE_[A-Z0-9_]+)=' "$ENV_FILE" > "${ENV_FILE}.tmp" || true
    mv "${ENV_FILE}.tmp" "$ENV_FILE"
fi

source "$ENV_FILE"

generate_compose() {
    cat <<EOF > "$COMPOSE_FILE"
services:
EOF
    
    if grep -q "^NODE_" "$ENV_FILE"; then
        grep "^NODE_" "$ENV_FILE" | while read -r line; do
            local node_id=$(echo "$line" | cut -d= -f1 | sed 's/NODE_//')
            local val=$(echo "$line" | cut -d= -f2)
            local country=$(echo "$val" | cut -d: -f1)
            local port=$(echo "$val" | cut -d: -f2)
            
            local country_spaced="${country//_/ }"

            cat <<EOF >> "$COMPOSE_FILE"
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
      - SERVER_COUNTRIES=${country_spaced}
      - TZ=Europe/Istanbul
      - BLOCK_MALICIOUS=off
      - BLOCK_SURVEILLANCE=off
      - BLOCK_ADS=off
      - DOT=off
      - IPV6=off
      - UPDATER_PERIOD=0
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
    fi
}

pause_menu() {
    echo -e "\nبرای بازگشت به منو دکمه Enter را فشار دهید..."
    read -r
}

list_nodes() {
    echo -e "\n--- لیست نودهای فعال ---"
    if ! grep -q "^NODE_" "$ENV_FILE"; then
        echo "هیچ نودی ثبت نشده است."
        return
    fi
    
    grep "^NODE_" "$ENV_FILE" | while read -r line; do
        local node_id=$(echo "$line" | cut -d= -f1 | sed 's/NODE_//')
        local val=$(echo "$line" | cut -d= -f2)
        local country=$(echo "$val" | cut -d: -f1)
        local port=$(echo "$val" | cut -d: -f2)
        local status=$(docker inspect -f '{{.State.Status}}' "nord-socks-${node_id,,}" 2>/dev/null || echo "توقف/ناموجود")
        
        local country_spaced="${country//_/ }"
        printf "نود: %-18s | کشور: %-18s | پورت: %-6s | وضعیت: %s\n" "$node_id" "$country_spaced" "$port" "$status"
    done
}

view_logs() {
    echo -e "\n--- مشاهده لاگ نودها ---"
    if ! grep -q "^NODE_" "$ENV_FILE"; then
        echo "هیچ نودی برای مشاهده لاگ وجود ندارد."
        return
    fi

    local -a node_ids=()
    local i=1
    
    echo "  0) 🌐 مشاهده لاگ تمامی نودها (ALL)"
    while read -r line; do
        local nid=$(echo "$line" | cut -d= -f1 | sed 's/NODE_//')
        local val=$(echo "$line" | cut -d= -f2)
        local country=$(echo "$val" | cut -d: -f1)
        node_ids+=("$nid")
        local country_spaced="${country//_/ }"
        echo "  $i) نود: $nid | کشور: $country_spaced"
        ((i++))
    done < <(grep "^NODE_" "$ENV_FILE" || true)

    local count=${#node_ids[@]}
    echo ""
    read -rp "شماره نود جهت مشاهده لاگ را وارد کنید (0-$count): " log_sel
    
    if [[ -z "$log_sel" ]]; then
        echo "عملیات لغو شد."
        return
    fi

    if ! [[ "$log_sel" =~ ^[0-9]+$ ]] || [[ "$log_sel" -lt 0 ]] || [[ "$log_sel" -gt "$count" ]]; then
        echo "❌ انتخاب نامعتبر است."
        return
    fi

    if [[ "$log_sel" -eq 0 ]]; then
        echo "--- نمایش ۵۰ خط آخر لاگ برای تمامی نودها ---"
        docker compose logs --tail=50 || true
    else
        local sel_idx=$((log_sel-1))
        local target_id="${node_ids[$sel_idx]}"
        echo "--- نمایش ۵۰ خط آخر لاگ برای نود $target_id ---"
        docker compose logs --tail=50 "vpn-${target_id,,}" "socks-${target_id,,}" || true
    fi
}

do_ping_test() {
    local target_port=$1
    local auth_args=""
    if [[ "$REQUIRE_AUTH" == "true" ]]; then
        auth_args="-U $PROXY_USER:$PROXY_PASSWORD"
    fi

    local response
    response=$(curl $auth_args --silent --show-error --max-time 15 -w "\nTIME_TOTAL:%{time_total}" --socks5-hostname "127.0.0.1:$target_port" http://ip-api.com/json || echo "FAILED")
    
    if [[ "$response" == *"FAILED"* || -z "$response" ]]; then
         echo -e "❌ تست ناموفق بود. اتصال برقرار نشد."
         return 1
    fi
    
    local body=$(echo "$response" | sed -e 's/TIME_TOTAL:.*//')
    local time_val=$(echo "$response" | grep -o 'TIME_TOTAL:.*' | cut -d: -f2 || true)
    local ping_ms=$(awk "BEGIN {print int($time_val * 1000)}")
    local check_status=$(echo "$body" | jq -r '.status' 2>/dev/null || echo "fail")
    
    if [[ "$check_status" == "success" ]]; then
        echo -e "✅ اتصال برقرار شد:"
        echo "   - کشور واقعی: $(echo "$body" | jq -r '.country')"
        echo "   - آی‌پی: $(echo "$body" | jq -r '.query')"
        echo "   - آی‌اس‌پی: $(echo "$body" | jq -r '.isp')"
        echo "   - زمان پاسخ: ${ping_ms}ms"
        return 0
    else
        echo "❌ مشکل در دریافت اطلاعات از سرور تست."
        return 1
    fi
}

add_node() {
    echo -e "\n--- افزودن نود جدید ---"
    echo "در حال دریافت لیست زنده کشورهای فعال از NordVPN..."
    
    local api_req
    api_req=$(curl --silent --max-time 10 https://api.nordvpn.com/v1/servers/countries | jq -r '.[].name' 2>/dev/null | sed 's/ /_/g' | sort || true)
    
    local -a country_list
    if [[ -n "$api_req" ]]; then
        country_list=($api_req)
    else
        echo "⚠️ ارتباط با API کند بود. بارگذاری لیست پشتیبان..."
        country_list=(Australia Austria Belgium Brazil Bulgaria Canada Croatia Czech_Republic Denmark Finland France Germany Greece Hong_Kong Hungary Iceland Ireland Israel Italy Japan Latvia Luxembourg Mexico Netherlands Norway Poland Portugal Romania Serbia Singapore Slovakia Slovenia South_Africa Spain Sweden Switzerland Turkey Ukraine United_Arab_Emirates United_Kingdom United_States)
    fi

    local count=${#country_list[@]}
    local cols=3
    local rows=$(( (count + cols - 1) / cols ))

    echo -e "\nکشورهای در دسترس (انتخاب با شماره):\n"
    for (( i=0; i<rows; i++ )); do
        local line=""
        for (( j=0; j<cols; j++ )); do
            local idx=$(( j * rows + i ))
            if [[ $idx -lt $count ]]; then
                local c_name="${country_list[$idx]}"
                line+=$(printf "%2d) %-22s" $((idx+1)) "${c_name//_/ }")
            fi
        done
        echo "$line"
    done

    echo ""
    read -rp "شماره کشور مورد نظر را وارد کنید (1-$count): " c_sel
    
    if ! [[ "$c_sel" =~ ^[0-9]+$ ]] || [[ "$c_sel" -lt 1 ]] || [[ "$c_sel" -gt "$count" ]]; then
        echo "❌ انتخاب نامعتبر. عملیات لغو شد."
        return
    fi
    
    local new_country="${country_list[$((c_sel-1))]}"
    new_country="${new_country//_/ }"
    
    local base_id="${new_country// /_}"
    base_id="${base_id^^}"
    base_id=$(echo "$base_id" | tr -cd 'A-Z0-9_')
    
    local node_id="$base_id"
    local counter=2
    
    while grep -q "^NODE_${node_id}=" "$ENV_FILE"; do
        node_id="${base_id}_${counter}"
        ((counter++))
    done
    
    echo -e "✅ کشور انتخاب شده: $new_country"
    echo -e "📌 شناسه نود به صورت خودکار تعیین شد: $node_id\n"
    
    local suggested_port=1082
    if grep -q "^NODE_" "$ENV_FILE"; then
        local max_p
        max_p=$(grep "^NODE_" "$ENV_FILE" | cut -d: -f2 | sort -n | tail -1 || true)
        if [[ -n "$max_p" ]] && [[ "$max_p" -ge 1082 ]]; then
            suggested_port=$((max_p + 1))
        fi
    fi
    
    read -rp "پورت SOCKS5 اختصاصی [$suggested_port]: " new_port
    new_port=${new_port:-$suggested_port}
    
    local safe_country="${new_country// /_}"
    echo "NODE_${node_id}=${safe_country}:${new_port}" >> "$ENV_FILE"
    generate_compose
    
    echo "در حال ساخت کانتینر $node_id..."
    if ! docker compose up -d --remove-orphans; then
        echo -e "\n❌ خطا در راه‌اندازی کانتینر داکر پیش آمد!"
        echo "--- لاگ خطا ---"
        docker compose logs --tail=15 "vpn-${node_id,,}" | grep -i -E "error|warn|fatal|failed" || true
        echo "---------------"
        echo "⚠️ در حال پاک‌سازی نود نصب نشده..."
        sed -i "/^NODE_${node_id}=/d" "$ENV_FILE" || true
        generate_compose
        return
    fi
    
    echo "⏳ در حال برقراری تونل امن (لطفاً ۲۰ ثانیه شکیبا باشید)..."
    sleep 20
    
    echo "در حال تست کیفیت شبکه..."
    if do_ping_test "$new_port"; then
        echo -e "\n✅ نود با موفقیت تایید و به لیست نهایی اضافه شد."
    else
        echo -e "\n❌ ارتباط با سرور $new_country برقرار نشد!"
        echo -e "--- خلاصه لاگ خطا ---"
        docker compose logs --tail=15 "vpn-${node_id,,}" | grep -i -E "error|warn|fatal" || docker compose logs --tail=10 "vpn-${node_id,,}" || true
        echo -e "----------------------"
        echo "⚠️ در حال حذف نود معیوب و بازگردانی تنظیمات..."
        
        docker compose rm -sf "vpn-${node_id,,}" "socks-${node_id,,}" >/dev/null 2>&1 || true
        sed -i "/^NODE_${node_id}=/d" "$ENV_FILE" || true
        generate_compose
        docker compose up -d --remove-orphans >/dev/null 2>&1 || true
        
        echo "نود اضافه نشد. لطفاً وضعیت شبکه سرور خود را بررسی نمایید."
    fi
}

edit_node_port() {
    echo -e "\n--- تغییر پورت SOCKS5 یک نود ---"
    if ! grep -q "^NODE_" "$ENV_FILE"; then
        echo "هیچ نودی برای ویرایش وجود ندارد."
        return
    fi

    local -a node_ids=()
    local -a node_countries=()
    local -a node_ports=()
    local i=1
    
    echo "لیست نودهای فعال:"
    while read -r line; do
        local nid=$(echo "$line" | cut -d= -f1 | sed 's/NODE_//')
        local val=$(echo "$line" | cut -d= -f2)
        local country=$(echo "$val" | cut -d: -f1)
        local port=$(echo "$val" | cut -d: -f2)
        node_ids+=("$nid")
        node_countries+=("$country")
        node_ports+=("$port")
        local country_spaced="${country//_/ }"
        echo "  $i) نود: $nid | کشور: $country_spaced | پورت فعلی: $port"
        ((i++))
    done < <(grep "^NODE_" "$ENV_FILE" || true)

    local count=${#node_ids[@]}
    echo ""
    read -rp "شماره نود جهت تغییر پورت را وارد کنید (1-$count) [یا 0 برای انصراف]: " edit_sel
    
    if [[ "$edit_sel" == "0" || -z "$edit_sel" ]]; then
        echo "عملیات لغو شد."
        return
    fi

    if ! [[ "$edit_sel" =~ ^[0-9]+$ ]] || [[ "$edit_sel" -lt 1 ]] || [[ "$edit_sel" -gt "$count" ]]; then
        echo "❌ انتخاب نامعتبر است."
        return
    fi

    local sel_idx=$((edit_sel-1))
    local target_id="${node_ids[$sel_idx]}"
    local target_country="${node_countries[$sel_idx]}"
    local old_port="${node_ports[$sel_idx]}"
    
    local suggested_port=1082
    if grep -q "^NODE_" "$ENV_FILE"; then
        local max_p
        max_p=$(grep "^NODE_" "$ENV_FILE" | cut -d: -f2 | sort -n | tail -1 || true)
        if [[ -n "$max_p" ]] && [[ "$max_p" -ge 1082 ]]; then
            suggested_port=$((max_p + 1))
        fi
    fi
    
    read -rp "پورت SOCKS5 جدید را وارد کنید [$suggested_port]: " new_port
    new_port=${new_port:-$suggested_port}
    
    if [[ "$new_port" == "$old_port" ]]; then
        echo "⚠️ پورت وارد شده با پورت فعلی یکسان است. تغییری اعمال نشد."
        return
    fi

    echo "در حال بروزرسانی پورت نود $target_id به $new_port..."
    sed -i "s/^NODE_${target_id}=.*/NODE_${target_id}=${target_country}:${new_port}/" "$ENV_FILE" || true
    generate_compose
    
    if ! docker compose up -d --remove-orphans "vpn-${target_id,,}" "socks-${target_id,,}" >/dev/null 2>&1; then
        echo "❌ خطایی در راه‌اندازی کانتینر پیش آمد."
        return
    fi
    
    echo "✅ پورت SOCKS5 نود $target_id با موفقیت به $new_port تغییر یافت."
    
    echo "⏳ در حال برقراری مجدد تونل امن..."
    sleep 5
    do_ping_test "$new_port" || true
}

remove_node() {
    echo -e "\n--- حذف نود ---"
    if ! grep -q "^NODE_" "$ENV_FILE"; then
        echo "هیچ نودی برای حذف وجود ندارد."
        return
    fi

    local -a node_ids=()
    local i=1
    
    echo "لیست نودهای فعال:"
    while read -r line; do
        local nid=$(echo "$line" | cut -d= -f1 | sed 's/NODE_//')
        local val=$(echo "$line" | cut -d= -f2)
        local country=$(echo "$val" | cut -d: -f1)
        node_ids+=("$nid")
        local country_spaced="${country//_/ }"
        echo "  $i) نود: $nid | کشور: $country_spaced"
        ((i++))
    done < <(grep "^NODE_" "$ENV_FILE" || true)

    local count=${#node_ids[@]}
    echo ""
    read -rp "شماره نود جهت حذف را وارد کنید (1-$count) [یا 0 برای انصراف]: " rm_sel
    
    if [[ "$rm_sel" == "0" || -z "$rm_sel" ]]; then
        echo "عملیات لغو شد."
        return
    fi

    if ! [[ "$rm_sel" =~ ^[0-9]+$ ]] || [[ "$rm_sel" -lt 1 ]] || [[ "$rm_sel" -gt "$count" ]]; then
        echo "❌ انتخاب نامعتبر است."
        return
    fi

    local rm_id="${node_ids[$((rm_sel-1))]}"
    
    echo "در حال متوقف کردن و حذف کانتینر $rm_id..."
    docker compose rm -sf "vpn-${rm_id,,}" "socks-${rm_id,,}" 2>/dev/null || true
    sed -i "/^NODE_${rm_id}=/d" "$ENV_FILE" || true
    generate_compose
    
    if ! docker compose up -d --remove-orphans >/dev/null 2>&1; then
        echo "⚠️ مشکلی در بروزرسانی کانتینرها به وجود آمد، اما نود از فایل حذف شد."
    else
        echo "✅ نود $rm_id با موفقیت حذف شد."
    fi
}

test_node_menu() {
    echo -e "\n--- تست کیفیت شبکه نودها ---"
    if ! grep -q "^NODE_" "$ENV_FILE"; then
        echo "هیچ نودی برای تست وجود ندارد."
        return
    fi

    local -a node_ports=()
    local -a node_names=()
    local i=1
    
    echo "  0) 🌐 تست تمامی نودها (آزمایش همه پشت سر هم)"
    while read -r line; do
        local nid=$(echo "$line" | cut -d= -f1 | sed 's/NODE_//')
        local val=$(echo "$line" | cut -d= -f2)
        local country=$(echo "$val" | cut -d: -f1)
        local port=$(echo "$val" | cut -d: -f2)
        node_ports+=("$port")
        node_names+=("$nid")
        local country_spaced="${country//_/ }"
        echo "  $i) نود: $nid | کشور: $country_spaced | پورت: $port"
        ((i++))
    done < <(grep "^NODE_" "$ENV_FILE" || true)

    local count=${#node_ports[@]}
    echo ""
    read -rp "شماره نود جهت تست را وارد کنید (0-$count): " t_sel
    
    if [[ -z "$t_sel" ]]; then
        echo "عملیات لغو شد."
        return
    fi

    if ! [[ "$t_sel" =~ ^[0-9]+$ ]] || [[ "$t_sel" -lt 0 ]] || [[ "$t_sel" -gt "$count" ]]; then
        echo "❌ انتخاب نامعتبر است."
        return
    fi

    if [[ "$t_sel" -eq 0 ]]; then
        for (( j=0; j<count; j++ )); do
            echo -e "\n--- در حال تست نود ${node_names[$j]} (پورت ${node_ports[$j]}) ---"
            do_ping_test "${node_ports[$j]}" || true
        done
    else
        local sel_idx=$((t_sel-1))
        echo -e "\n--- در حال تست نود ${node_names[$sel_idx]} (پورت ${node_ports[$sel_idx]}) ---"
        do_ping_test "${node_ports[$sel_idx]}" || true
    fi
}

restart_all_nodes() {
    echo -e "\n--- راه‌اندازی مجدد و اعمال بهینه‌سازی روی تمامی نودها ---"
    docker compose down || true
    
    echo "در حال اجرای مجدد سرویس‌ها با کانفیگ سبک..."
    generate_compose
    if ! docker compose up -d --remove-orphans; then
        echo -e "\n❌ خطا در راه‌اندازی یک یا چند نود!"
    else
        echo "✅ تمامی نودها با موفقیت از نو ساخته و بهینه‌سازی شدند."
    fi
}

update_project() {
    echo "در حال آپدیت از مخزن گیت‌هاب..."
    git stash push -m "Backup configs" >/dev/null 2>&1 || true
    git pull origin main || true
    chmod +x "$PROJECT_DIR/nordx-manager.sh" || true
    echo "✅ آپدیت انجام شد."
    
    echo "در حال بارگذاری مجدد منو..."
    sleep 1
    exec /usr/bin/nordx
}

uninstall_project() {
    read -rp 'آیا از حذف کامل کانتینرها، اطلاعات و پاک شدن اسکریپت اطمینان دارید؟ (y/n): ' confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        docker compose down -v || true
        rm -f /usr/bin/nordx || true
        cd /
        rm -rf "$PROJECT_DIR" || true
        echo "🗑️ پروژه NordX-Pro به طور کامل حذف شد."
        exit 0
    fi
}

while true; do
    clear
    echo -e "=============================================="
    echo "             NordX-Pro SOCKS Manager"
    echo "=============================================="
    echo "  1) 👁️  لیست نودهای فعال"
    echo "  2) ➕ افزودن نود جدید"
    echo "  3) ✏️  تغییر پورت یک نود"
    echo "  4) ➖ حذف یک نود"
    echo "  5) ⚡ تست اتصال و پینگ نود"
    echo "  6) 📜 مشاهده لاگ کانتینرها"
    echo "  7) 🔄 ریستارت تمامی نودها"
    echo "  8) ⬇️  آپدیت اسکریپت از گیت‌هاب"
    echo "  9) 🗑️  حذف کامل پروژه"
    echo " 10) 🚪 خروج"
    echo "=============================================="
    read -rp 'انتخاب شما [1-10]: ' choice

    case $choice in
        1) list_nodes; pause_menu ;;
        2) add_node; pause_menu ;;
        3) edit_node_port; pause_menu ;;
        4) remove_node; pause_menu ;;
        5) test_node_menu; pause_menu ;;
        6) view_logs; pause_menu ;;
        7) restart_all_nodes; pause_menu ;;
        8) update_project ;;
        9) uninstall_project ;;
        10) clear; exit 0 ;;
        *) echo "❌ انتخاب نامعتبر."; pause_menu ;;
    esac
done
