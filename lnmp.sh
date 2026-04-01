#!/bin/bash

# ==========================================
# Debian 12 原生 LNMP 生产级管理中枢 v5.0 (解耦重构版)
# ==========================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

COMMAND=$1
ACTION=$2
SUB_ACTION=$3
BAK_DIR="/var/webak"

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误：请使用 root 用户或 sudo 运行此脚本！${NC}"
    exit 1
fi

LOG_FILE="/var/log/lnmp-manager.log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "===== $(date "+%Y-%m-%d %H:%M:%S") ===== 执行指令: $0 $*" >> "$LOG_FILE"

LOCK_FILE="/tmp/lnmp-manager.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || {
    echo -e "${RED}错误：另一个 lnmp 进程正在运行 (flock 排他锁已生效)！${NC}"
    exit 1
}

get_php_sock() {
    local PHP_VER
    if command -v php-fpm >/dev/null 2>&1; then
        PHP_VER=$(php-fpm -v 2>/dev/null | grep -oP '\d+\.\d+' | head -n1)
    fi
    [ -z "$PHP_VER" ] && PHP_VER=$(ls /etc/php 2>/dev/null | sort -V | tail -n1)
    
    if [ -n "$PHP_VER" ]; then
        echo "/run/php/php${PHP_VER}-fpm.sock"
    else
        echo ""
    fi
}

get_clean_dbname() {
    local DOMAIN=$1
    # 剥离 www. 前缀，剥离顶级域名后缀，替换 - 和 . 为下划线
    echo "${DOMAIN#www.}" | sed -E 's/\.[a-zA-Z0-9]+$//; s/\./_/g; s/-/_/g'
}

# ==========================================
# 模块：基础环境安装 (install)
# ==========================================
install_lnmp() {
    echo -e "${GREEN}正在拉取当前系统源最新稳定版本信息...${NC}"
    apt update -y >/dev/null 2>&1
    
    NGINX_VER=$(apt-cache show nginx 2>/dev/null | grep Version | head -n1 | awk '{print $2}' | cut -d: -f2 | cut -d- -f1)
    MARIADB_VER=$(apt-cache show mariadb-server 2>/dev/null | grep Version | head -n1 | awk '{print $2}' | cut -d: -f2 | cut -d+ -f1)
    PHP_VER_APT=$(apt-cache show php-fpm 2>/dev/null | grep Version | head -n1 | awk '{print $2}' | cut -d: -f2 | cut -d+ -f1)

    echo -e "\n${YELLOW}=== 基础安装版本预检 ===${NC}"
    echo -e "Web 服务器 : Nginx ${GREEN}${NGINX_VER:-(获取失败，将默认安装)}${NC}"
    echo -e "数据库引擎 : MariaDB ${GREEN}${MARIADB_VER:-(获取失败，将默认安装)}${NC}"
    echo -e "PHP 解析器 : PHP-FPM ${GREEN}${PHP_VER_APT:-(获取失败，将默认安装)}${NC}"
    echo -e "附加组件   : Redis, Certbot, UFW, Fail2ban"
    echo -e "------------------------------------"
    read -p "确认执行基础环境构建吗？(y/n) [y]: " CONFIRM_INSTALL
    CONFIRM_INSTALL=${CONFIRM_INSTALL:-y}
    if [[ "$CONFIRM_INSTALL" != "y" ]]; then
        echo "已取消安装。"
        exit 0
    fi

    echo -e "${GREEN}开始安装 LNMP 基础包...${NC}"
    apt install nginx mariadb-server php-fpm php-mysql php-xml php-curl php-gd php-mbstring php-imagick php-redis php-bcmath php-intl php-zip redis-server curl wget unzip certbot python3-certbot-nginx ufw htop logrotate fail2ban -y

    # 日志轮转配置
    cat > /etc/logrotate.d/lnmp-manager <<EOF
/var/log/lnmp-manager.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
EOF

    # MariaDB 基础安全初始化
    echo -e "${YELLOW}执行数据库基础安全加固...${NC}"
    systemctl start mariadb
    mysql -e "DELETE FROM mysql.user WHERE User='';"
    mysql -e "DROP DATABASE IF EXISTS test;"
    mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
    mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password;"
    mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host!='localhost';"
    mysql -e "FLUSH PRIVILEGES;"
    
    # Nginx 消除默认 gzip 冲突
    sed -i 's/^\s*gzip on;/# gzip on;/' /etc/nginx/nginx.conf

    # UFW 与 Fail2ban 基础安防
    SSH_PORT=$(ss -tlnp | grep sshd | awk '{print $4}' | grep -oP '\d+$' | head -1)
    SSH_PORT=${SSH_PORT:-22}
    
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port    = ${SSH_PORT}
EOF
    systemctl restart fail2ban
    systemctl enable fail2ban --now

    ufw allow "${SSH_PORT}/tcp" comment 'SSH Auto-Detect'
    ufw allow 'Nginx Full'
    ufw --force enable
    systemctl enable certbot.timer --now

    # 守护服务
    PHP_VER_RUN=$(php -v 2>/dev/null | grep -oP '^PHP \K[0-9]+\.[0-9]+' || ls /etc/php | sort -V | tail -n1)
    for svc in nginx mariadb redis-server "php${PHP_VER_RUN}-fpm"; do
        mkdir -p "/etc/systemd/system/${svc}.service.d"
        cat > "/etc/systemd/system/${svc}.service.d/restart.conf" <<EOF
[Service]
Restart=always
RestartSec=3
EOF
    done
    systemctl daemon-reload
    systemctl restart nginx "php${PHP_VER_RUN}-fpm" mariadb redis-server

    echo -e "\n${GREEN}🎉 基础环境构建完成！${NC}"
    echo -e "提示: 当前环境为保守配置配置。请运行 ${YELLOW}lnmp optimize${NC} 执行生产级性能压榨。"
}

# ==========================================
# 模块：极限压榨与优化 (optimize)
# ==========================================
opt_kernel() {
    echo -e "${GREEN}正在注入内核级 TCP 并发与 Ulimit 破壁规则...${NC}"
    cat > /etc/security/limits.d/99-lnmp.conf <<EOF
www-data soft nofile 65535
www-data hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF
    cat > /etc/sysctl.d/99-lnmp-tcp.conf <<EOF
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_tw_buckets = 200000
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fastopen = 3
EOF
    sysctl -p /etc/sysctl.d/99-lnmp-tcp.conf >/dev/null 2>&1
    
    MEM=$(free -m | awk '/Mem:/ {print $2}')
    if [ "$(swapon --show | wc -l)" -eq 0 ]; then
        SWAPSIZE=$([ "$MEM" -le 2048 ] && echo "2G" || echo "1G")
        fallocate -l "$SWAPSIZE" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$((${SWAPSIZE%G} * 1024)) status=none
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1
        swapon /swapfile
        grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    echo -e "-> ${YELLOW}完成${NC}"
}

opt_nginx() {
    echo -e "${GREEN}正在重构 Nginx 高并发引擎与全局缓存 Map...${NC}"
    sed -i 's/^worker_processes.*/worker_processes auto;/' /etc/nginx/nginx.conf
    grep -q "worker_connections" /etc/nginx/nginx.conf && sed -i 's/.*worker_connections.*/\tworker_connections 65535;/' /etc/nginx/nginx.conf || sed -i '/events {/a \    worker_connections 65535;' /etc/nginx/nginx.conf
    grep -q "worker_rlimit_nofile" /etc/nginx/nginx.conf || sed -i '/worker_processes/a worker_rlimit_nofile 65535;' /etc/nginx/nginx.conf
    grep -q "multi_accept on;" /etc/nginx/nginx.conf || sed -i '/worker_connections/a \\tmulti_accept on;' /etc/nginx/nginx.conf
    grep -q "use epoll;" /etc/nginx/nginx.conf || sed -i '/worker_connections/a \\tuse epoll;' /etc/nginx/nginx.conf
    grep -q "tcp_nopush on;" /etc/nginx/nginx.conf || sed -i '/sendfile on;/a \\ttcp_nopush on;\n\ttcp_nodelay on;' /etc/nginx/nginx.conf
    grep -q "keepalive_requests" /etc/nginx/nginx.conf || sed -i '/keepalive_timeout/a \\tkeepalive_requests 1000;' /etc/nginx/nginx.conf
    sed -i 's/.*keepalive_timeout.*/\tkeepalive_timeout 65;/' /etc/nginx/nginx.conf
    sed -i 's/# server_tokens off;/server_tokens off;/' /etc/nginx/nginx.conf

    cat > /etc/nginx/conf.d/fastcgi_cache_map.conf <<EOF
map \$http_cookie \$skip_cache {
    default 0;
    ~*wordpress_logged_in 1;
    ~*comment_author 1;
    ~*woocommerce_items_in_cart 1;
    ~*wp-postpass 1;
}
EOF
    cat > /etc/nginx/conf.d/rate_limit.conf <<EOF
limit_req_zone \$binary_remote_addr zone=general:10m rate=10r/s;
limit_req_zone \$binary_remote_addr zone=login:10m rate=1r/s;
EOF
    systemctl reload nginx
    echo -e "-> ${YELLOW}完成${NC}"
}

opt_php() {
    echo -e "${GREEN}正在调校 PHP-FPM 防 OOM 进程池与 Realpath 缓存...${NC}"
    PHP_VER=$(php -v 2>/dev/null | grep -oP '^PHP \K[0-9]+\.[0-9]+' || ls /etc/php | sort -V | tail -n1)
    MEM=$(free -m | awk '/Mem:/ {print $2}')
    AVAIL_MEM=$((MEM - 512)); [ "$AVAIL_MEM" -lt 256 ] && AVAIL_MEM=256
    MAX_C=$((AVAIL_MEM / 80)); [ "$MAX_C" -gt 150 ] && MAX_C=150; [ "$MAX_C" -lt 10 ] && MAX_C=10
    START_C=$((MAX_C / 4)); [ "$START_C" -lt 4 ] && START_C=4
    MIN_C=$((MAX_C / 4)); [ "$MIN_C" -lt 4 ] && MIN_C=4
    MAX_SPARE=$((MAX_C / 2)); [ "$MAX_SPARE" -lt 10 ] && MAX_SPARE=10

    FPM_CONF="/etc/php/${PHP_VER}/fpm/pool.d/www.conf"
    sed -i "s/^;*\s*pm\s*=.*/pm = dynamic/" "$FPM_CONF"
    sed -i "s/^;*\s*pm.max_children\s*=.*/pm.max_children = $MAX_C/" "$FPM_CONF"
    sed -i "s/^;*\s*pm.start_servers\s*=.*/pm.start_servers = $START_C/" "$FPM_CONF"
    sed -i "s/^;*\s*pm.min_spare_servers\s*=.*/pm.min_spare_servers = $MIN_C/" "$FPM_CONF"
    sed -i "s/^;*\s*pm.max_spare_servers\s*=.*/pm.max_spare_servers = $MAX_SPARE/" "$FPM_CONF"
    sed -i "s/^;*\s*pm.max_requests\s*=.*/pm.max_requests = 500/" "$FPM_CONF"
    
    PHP_INI="/etc/php/${PHP_VER}/fpm/php.ini"
    sed -i 's/^;*\s*opcache\.enable\s*=.*/opcache.enable=1/' "$PHP_INI"
    sed -i 's/^;*\s*opcache\.memory_consumption\s*=.*/opcache.memory_consumption=256/' "$PHP_INI"
    sed -i 's/^;*\s*opcache\.revalidate_freq\s*=.*/opcache.revalidate_freq=60/' "$PHP_INI"
    sed -i 's/^;*\s*post_max_size\s*=.*/post_max_size = 100M/' "$PHP_INI"
    sed -i 's/^;*\s*upload_max_filesize\s*=.*/upload_max_filesize = 100M/' "$PHP_INI"
    sed -i 's/^;*\s*realpath_cache_size\s*=.*/realpath_cache_size = 4096k/' "$PHP_INI"
    
    systemctl restart "php${PHP_VER}-fpm"
    echo -e "-> ${YELLOW}完成 (Max Workers: $MAX_C)${NC}"
}

opt_mariadb() {
    echo -e "${GREEN}正在配置 MariaDB 动态缓冲与 IO 刷盘策略...${NC}"
    MEM=$(free -m | awk '/Mem:/ {print $2}')
    if [ "$MEM" -le 4096 ]; then BUFFER_M=$((MEM * 40 / 100)); LOG_SIZE="128M"; MAX_CONN=200
    elif [ "$MEM" -le 16384 ]; then BUFFER_M=$((MEM * 50 / 100)); LOG_SIZE="256M"; MAX_CONN=300
    else BUFFER_M=8192; LOG_SIZE="512M"; MAX_CONN=500
    fi
    [ "$BUFFER_M" -lt 128 ] && BUFFER_M=128

    cat > /etc/mysql/mariadb.conf.d/60-lnmp.cnf <<EOF
[mysqld]
innodb_buffer_pool_size=${BUFFER_M}M
innodb_log_file_size=${LOG_SIZE}
innodb_flush_log_at_trx_commit=2
innodb_file_per_table=1
max_connections=${MAX_CONN}
table_open_cache=4000
skip-name-resolve
EOF
    systemctl restart mariadb
    echo -e "-> ${YELLOW}完成 (Buffer: ${BUFFER_M}MB, MaxConn: ${MAX_CONN})${NC}"
}

opt_redis() {
    echo -e "${GREEN}正在激活 Redis IPC(Unix Socket) 与内存淘汰策略...${NC}"
    MEM=$(free -m | awk '/Mem:/ {print $2}')
    REDIS_MEM=$((MEM * 20 / 100)); [ "$REDIS_MEM" -lt 64 ] && REDIS_MEM=64
    usermod -aG redis www-data
    
    grep -q "^maxmemory " /etc/redis/redis.conf || echo -e "\nmaxmemory ${REDIS_MEM}mb\nmaxmemory-policy allkeys-lru\nunixsocket /run/redis/redis-server.sock\nunixsocketperm 770" >> /etc/redis/redis.conf
    sed -i "s/^maxmemory .*/maxmemory ${REDIS_MEM}mb/" /etc/redis/redis.conf
    sed -i 's/^maxmemory-policy.*/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf
    sed -i 's/^#*\s*unixsocket \/.*/unixsocket \/run\/redis\/redis-server.sock/' /etc/redis/redis.conf
    sed -i 's/^#*\s*unixsocketperm.*/unixsocketperm 770/' /etc/redis/redis.conf
    
    systemctl restart redis-server
    echo -e "-> ${YELLOW}完成 (限额: ${REDIS_MEM}MB)${NC}"
}

optimize_lnmp() {
    echo -e "${GREEN}=========================================${NC}"
    echo -e "        LNMP 生产环境极客压榨中心"
    echo -e "${GREEN}=========================================${NC}"
    echo -e " 1) 优化内核 TCP 协议栈与连接数上限"
    echo -e " 2) 重构 Nginx 高并发模式与抗爆破映射"
    echo -e " 3) 调校 PHP-FPM 防 OOM 进程池"
    echo -e " 4) 优化 MariaDB 动态内存缓冲与极速 IO"
    echo -e " 5) 激活 Redis 内存直连 (Unix Socket)"
    echo -e " 6) ${YELLOW}一键执行全部极限优化 (推荐)${NC}"
    echo -e " 0) 退出"
    echo -e "========================================="
    read -p "请选择优化项 [0-6]: " OPT_CHOICE
    
    case "$OPT_CHOICE" in
        1) opt_kernel ;;
        2) opt_nginx ;;
        3) opt_php ;;
        4) opt_mariadb ;;
        5) opt_redis ;;
        6) opt_kernel; opt_nginx; opt_php; opt_mariadb; opt_redis ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项！${NC}" ;;
    esac
    echo -e "${GREEN}🎉 优化任务执行完毕！${NC}"
}

# ==========================================
# 模块：服务管理 (start/stop/restart/update)
# ==========================================
manage_services() {
    local cmd=$1
    PHP_SOCK=$(get_php_sock)
    PHP_VER=$(echo "$PHP_SOCK" | grep -oP 'php\K[0-9.]+(?=-fpm)')
    echo -e "${GREEN}正在执行 $cmd 操作...${NC}"
    
    for svc in nginx "php${PHP_VER}-fpm" mariadb redis-server; do
        if [ "$cmd" == "status" ]; then
            if systemctl is-active --quiet "$svc"; then
                echo -e "$svc:\t${GREEN}运行中${NC}"
            else
                echo -e "$svc:\t${RED}已停止 / 异常${NC}"
            fi
        else
            if systemctl "$cmd" "$svc"; then
                echo -e "$svc $cmd\t[${GREEN} OK ${NC}]"
            else
                echo -e "$svc $cmd\t[${RED} FAIL ${NC}]"
            fi
        fi
    done
}

# ==========================================
# 模块：虚拟主机管理 (vhost add/del/list/database)
# ==========================================
vhost_add() {
    PHP_SOCK=$(get_php_sock)
    if [ -z "$PHP_SOCK" ]; then echo -e "${RED}未检测到 PHP，请先运行 lnmp install${NC}"; exit 1; fi

    read -p "请输入主域名 (例如: hho.icu): " DOMAIN
    if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+$ ]]; then
        echo -e "${RED}错误：域名格式不合法！${NC}"
        exit 1
    fi

    WEB_ROOT="/var/www/$DOMAIN"
    NGINX_CONF="/etc/nginx/sites-available/$DOMAIN.conf"

    read -p "是否同时绑定 www.$DOMAIN ? (y/n) [y]: " ADD_WWW
    ADD_WWW=${ADD_WWW:-y}
    SERVER_NAMES=$([ "$ADD_WWW" == "y" ] && echo "$DOMAIN www.$DOMAIN" || echo "$DOMAIN")
    CERTBOT_DOMAINS=$([ "$ADD_WWW" == "y" ] && echo "-d $DOMAIN -d www.$DOMAIN" || echo "-d $DOMAIN")

    read -p "是否创建 MySQL 数据库? (y/n) [y]: " CREATE_DB
    CREATE_DB=${CREATE_DB:-y}
    if [ "$CREATE_DB" == "y" ]; then
        SUGGESTED_DB=$(get_clean_dbname "$DOMAIN")
        read -p "请输入数据库名 (默认: $SUGGESTED_DB): " INPUT_DB
        DB_NAME=${INPUT_DB:-$SUGGESTED_DB}
        read -s -p "请输入数据库密码: " DB_PASS
        echo ""
        if [ -z "$DB_PASS" ]; then CREATE_DB="n"; fi
    fi

    read -p "是否使用 Certbot 申请 SSL ? (y/n) [y]: " ENABLE_SSL
    ENABLE_SSL=${ENABLE_SSL:-y}

    echo -e "\n${YELLOW}正在生成 Nginx Vhost 配置...${NC}"
    mkdir -p "$WEB_ROOT"
    chown -R www-data:www-data "$WEB_ROOT"
    find "$WEB_ROOT" -type d -exec chmod 755 {} \;
    find "$WEB_ROOT" -type f -exec chmod 644 {} \;

    cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name $SERVER_NAMES;
    root $WEB_ROOT;
    index index.php index.html index.htm;
    
    client_max_body_size 100M;
    
    set \$bypass_cache \$skip_cache;
    if (\$request_method = POST) { set \$bypass_cache 1; }
    if (\$query_string != "") { set \$bypass_cache 1; }
    if (\$request_uri ~* "/wp-admin/|/xmlrpc.php|wp-.*.php|^/feed/*|/tag/.*/feed/*|index.php|/.*sitemap.*\.(xml|xsl)") { set \$bypass_cache 1; }

    location / {
        limit_req zone=general burst=20 nodelay;
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location = /wp-login.php {
        limit_req zone=login burst=3 nodelay;
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_SOCK;
    }

    location = /xmlrpc.php { deny all; access_log off; }
    location ~* wp-config.php { deny all; access_log off; }
    location ~* /wp-content/uploads/.*\.php$ { deny all; access_log off; }
    location ~ /\. { deny all; access_log off; }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_SOCK;
        
        fastcgi_cache_bypass \$bypass_cache;
        fastcgi_no_cache \$bypass_cache;
        fastcgi_cache WORDPRESS;
        fastcgi_cache_methods GET HEAD;
        fastcgi_cache_valid 200 301 302 60m;
        add_header X-FastCGI-Cache \$upstream_cache_status;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|webp)$ {
        expires max;
        log_not_found off;
    }
}
EOF

    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
    nginx -t && systemctl reload nginx

    if [ "$CREATE_DB" == "y" ]; then
        mysql -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
        mysql -e "CREATE USER IF NOT EXISTS '$DB_NAME'@'localhost' IDENTIFIED BY '$DB_PASS';"
        mysql -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_NAME'@'localhost';"
        mysql -e "FLUSH PRIVILEGES;"
    fi

    if [ "$ENABLE_SSL" == "y" ]; then
        certbot --nginx $CERTBOT_DOMAINS --non-interactive --agree-tos --register-unsafely-without-email --redirect
    fi

    echo -e "\n${GREEN}🎉 $DOMAIN 部署完毕！${NC}"
}

vhost_list() {
    echo -e "${GREEN}当前运行中的虚拟主机：${NC}"
    ls /etc/nginx/sites-enabled/ 2>/dev/null | sed 's/\.conf$//' | grep -v "^default$" || echo "暂无网站"
}

vhost_db_list() {
    echo -e "${GREEN}=== 业务数据库列表 ===${NC}"
    mysql -e "SHOW DATABASES;" | grep -Ev "^(Database|information_schema|performance_schema|mysql|sys)$" || echo "暂无业务数据库"
}

vhost_del() {
    vhost_list
    read -p "请输入要彻底删除的域名: " DOMAIN
    if [ -z "$DOMAIN" ]; then exit 1; fi
    
    SUGGESTED_DB=$(get_clean_dbname "$DOMAIN")
    read -p "警告：是否同时删除对应的数据库 (默认名: $SUGGESTED_DB)? (y/n) [n]: " DEL_DB
    
    rm -f "/etc/nginx/sites-available/$DOMAIN.conf"
    rm -f "/etc/nginx/sites-enabled/$DOMAIN.conf"
    rm -rf "/var/www/$DOMAIN"
    
    certbot delete --cert-name "$DOMAIN" --non-interactive 2>/dev/null
    systemctl reload nginx
    
    if [ "$DEL_DB" == "y" ]; then
        read -p "确认要删除的数据库名 (默认: $SUGGESTED_DB): " INPUT_DB
        DB_NAME=${INPUT_DB:-$SUGGESTED_DB}
        mysql -e "DROP DATABASE IF EXISTS \`$DB_NAME\`;"
        mysql -e "DROP USER IF EXISTS '$DB_NAME'@'localhost';"
        mysql -e "FLUSH PRIVILEGES;"
    fi
    echo -e "${GREEN}域名 $DOMAIN 及其伴随资产已彻底清理完毕！${NC}"
}

# ==========================================
# 模块：看板 (bench/top/php/info)
# ==========================================
show_bench() {
    echo -e "${GREEN}=== LNMP 生产环境综合体检诊断 ===${NC}"
    nginx -v
    php -v | head -n 1
    mysqladmin status
    redis-cli info memory | grep -E 'used_memory_human|maxmemory_human'
    systemctl is-active certbot.timer
}

show_top() {
    echo -e "${GREEN}=== LNMP 性能监控看板 ===${NC}"
    uptime
    free -h
    ss -s | grep TCP
}

# ==========================================
# 主路由逻辑
# ==========================================
case "$COMMAND" in
    install) install_lnmp ;;
    optimize) optimize_lnmp ;;
    start|stop|restart|reload|status) manage_services "$COMMAND" ;;
    update) apt update && apt --only-upgrade install nginx mariadb-server php-fpm php-mysql redis-server -y && manage_services "reload" ;;
    bench) show_bench ;;
    top) manage_services "status"; show_top ;;
    vhost)
        case "$ACTION" in
            add) vhost_add ;;
            del) vhost_del ;;
            list) vhost_list ;;
            database)
                if [ "$SUB_ACTION" == "list" ]; then
                    vhost_db_list
                else
                    echo -e "${YELLOW}用法: lnmp vhost database list${NC}"
                fi
                ;;
            *) echo -e "${YELLOW}用法: lnmp vhost {add|del|list|database list}${NC}" ;;
        esac
        ;;
    *)
        echo -e "${GREEN}=========================================${NC}"
        echo -e "  Debian 12 LNMP 管理中枢 v5.0 (解耦重构版)"
        echo -e "${GREEN}=========================================${NC}"
        echo -e "系统运维:"
        echo -e "  lnmp install       - 基础构建 (拉取稳定源/安全加固)"
        echo -e "  lnmp optimize      - 极限压榨 (动态调优内核与连接池)"
        echo -e "  lnmp update        - 核心环境组件平滑升级"
        echo -e "  lnmp status/top    - 服务运行状态巡检与看板"
        echo -e "\n虚拟主机:"
        echo -e "  lnmp vhost add     - 智能虚拟主机 (自动提取干净 DB 名)"
        echo -e "  lnmp vhost del     - 静默回收主机及关联数据库/证书"
        echo -e "  lnmp vhost list    - 运行节点列表清单"
        echo -e "  lnmp vhost database list - 查看所有业务数据库"
        echo -e "========================================="
        ;;
esac
