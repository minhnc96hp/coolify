#!/bin/bash

#############################################
# N8N BACKUP AUTO INSTALLER
# Tự động cài đặt và cấu hình backup service
#############################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

print_header() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${BOLD}N8N BACKUP SERVICE - AUTO INSTALLER${NC}                   ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

log_step() {
    echo -e "${BLUE}➤${NC} ${BOLD}$1${NC}"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        log_error "Script này cần chạy với quyền root (sudo)"
        exit 1
    fi
    log_success "Đang chạy với quyền root"
}

# Check if Docker is installed
check_docker() {
    log_step "Kiểm tra Docker..."
    if ! command -v docker &> /dev/null; then
        log_error "Docker chưa được cài đặt!"
        exit 1
    fi
    log_success "Docker đã được cài đặt"
}

# Check if n8n container exists
check_n8n_container() {
    log_step "Tìm kiếm n8n container..."
    CONTAINER=$(docker ps --filter "name=n8n" --format "{{.Names}}" | head -n 1)
    
    if [ -z "$CONTAINER" ]; then
        log_error "Không tìm thấy n8n container đang chạy!"
        echo ""
        echo "Danh sách containers đang chạy:"
        docker ps --format "table {{.Names}}\t{{.Status}}"
        exit 1
    fi
    log_success "Tìm thấy n8n container: $CONTAINER"
}

# Create main backup script
create_backup_script() {
    log_step "Tạo script backup chính..."
    
    cat > /usr/local/bin/n8n-backup.sh << 'EOF'
#!/usr/bin/env bash

# ==========================
# CẤU HÌNH
# ==========================
BACKUP_BASE_DIR="/home/minhnc/Desktop/n8n-backup"
BACKUP_INTERVAL_MINUTES=60    # Mỗi 60 phút backup 1 lần
RETENTION_DAYS=30             # Giữ backup 30 ngày
LOG_FILE="$BACKUP_BASE_DIR/backup.log"

# Không dùng set -e để tránh service chết vì lỗi lặt vặt
# set -euo pipefail

log() {
    local level="$1"
    shift
    local message="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"

    mkdir -p "$BACKUP_BASE_DIR"
    echo "[$ts] [$level] $message" | tee -a "$LOG_FILE"
}

find_n8n_container() {
    # Ưu tiên container có tên chứa "n8n"
    local cid
    cid="$(docker ps --format '{{.ID}} {{.Image}} {{.Names}}' | awk '/n8n/ {print $1; exit}')"
    echo "$cid"
}

perform_backup() {
    local ts container tmp_dir tar_file
    ts="$(date '+%Y%m%d-%H%M%S')"

    container="$(find_n8n_container)"
    if [ -z "$container" ]; then
        log "ERROR" "Không tìm thấy container n8n đang chạy – bỏ qua lần backup này"
        return 1
    fi

    tmp_dir="$BACKUP_BASE_DIR/$ts"
    tar_file="$BACKUP_BASE_DIR/n8n-backup-$ts.tar.gz"

    mkdir -p "$tmp_dir"

    log "INFO" "Bắt đầu backup n8n (container: $container, folder tạm: $tmp_dir)"

    # 1. Backup database.sqlite từ container
    if docker cp "$container":/home/node/.n8n/database.sqlite "$tmp_dir/database.sqlite" >/dev/null 2>&1; then
        log "INFO" "Đã copy database.sqlite"
    else
        log "ERROR" "Không copy được database.sqlite từ container"
    fi

    # 2. Backup file config (chứa encryptionKey, settings, ...)
    if docker cp "$container":/home/node/.n8n/config "$tmp_dir/config" >/dev/null 2>&1; then
        log "INFO" "Đã copy file config (/home/node/.n8n/config)"
    else
        log "WARN" "Không copy được file config (/home/node/.n8n/config)"
    fi

    # 3. Export workflows
    if docker exec "$container" n8n export:workflow --all --output=/tmp/workflows.json >/dev/null 2>&1; then
        if docker cp "$container":/tmp/workflows.json "$tmp_dir/workflows.json" >/dev/null 2>&1; then
            log "INFO" "Đã export workflows -> workflows.json"
        else
            log "ERROR" "Không copy được workflows.json ra ngoài"
        fi
        docker exec "$container" rm /tmp/workflows.json >/dev/null 2>&1 || true
    else
        log "WARN" "Không export được workflows (có thể chưa có workflow nào)"
    fi

    # 4. Export credentials
    if docker exec "$container" n8n export:credentials --all --output=/tmp/credentials.json >/dev/null 2>&1; then
        if docker cp "$container":/tmp/credentials.json "$tmp_dir/credentials.json" >/dev/null 2>&1; then
            log "INFO" "Đã export credentials -> credentials.json"
        else
            log "ERROR" "Không copy được credentials.json ra ngoài"
        fi
        docker exec "$container" rm /tmp/credentials.json >/dev/null 2>&1 || true
    else
        log "WARN" "Không export được credentials (có thể chưa có credential nào)"
    fi

    # 5. Lưu thêm info
    {
        echo "N8N BACKUP"
        echo "Generated: $(date)"
        echo "Container: $container"
        echo "Files:"
        echo "  - database.sqlite"
        echo "  - config (chứa encryptionKey & settings)"
        echo "  - workflows.json (export workflows)"
        echo "  - credentials.json (export credentials)"
    } > "$tmp_dir/README.txt"

    # 6. Nén lại
    if tar -czf "$tar_file" -C "$BACKUP_BASE_DIR" "$ts" >/dev/null 2>&1; then
        log "INFO" "Đã nén backup -> $tar_file"
        rm -rf "$tmp_dir"
    else
        log "ERROR" "Nén backup thất bại"
    fi

    # 7. Xoá backup cũ quá RETENTION_DAYS
    find "$BACKUP_BASE_DIR" -maxdepth 1 -type f -name 'n8n-backup-*.tar.gz' -mtime +"$RETENTION_DAYS" -print0 2>/dev/null \
        | while IFS= read -r -d '' f; do
            log "INFO" "Xoá backup cũ: $f"
            rm -f "$f"
        done

    log "SUCCESS" "Hoàn tất backup lúc $ts"
    return 0
}

main() {
    mkdir -p "$BACKUP_BASE_DIR"
    log "INFO" "N8N Backup Service khởi động. Interval: ${BACKUP_INTERVAL_MINUTES} phút, Retention: ${RETENTION_DAYS} ngày"

    while true; do
        perform_backup
        log "INFO" "Ngủ ${BACKUP_INTERVAL_MINUTES} phút rồi chạy backup tiếp..."
        sleep "${BACKUP_INTERVAL_MINUTES}m"
    done
}

main
EOF

    chmod +x /usr/local/bin/n8n-backup.sh
    log_success "Đã tạo script backup tại /usr/local/bin/n8n-backup.sh"
}

# Create systemd service
create_systemd_service() {
    log_step "Tạo systemd service..."
    
    cat > /etc/systemd/system/n8n-backup.service << 'EOF'
[Unit]
Description=N8N Automatic Backup Service
After=docker.service
Requires=docker.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/n8n-backup.sh
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    log_success "Đã tạo systemd service"
}

# Enable and start service
enable_service() {
    log_step "Kích hoạt service..."
    
    systemctl daemon-reload
    log_success "Đã reload systemd daemon"
    
    systemctl enable n8n-backup.service
    log_success "Đã enable service (tự động chạy khi boot)"
    
    systemctl start n8n-backup.service
    log_success "Đã khởi động service"
}

# Show status
show_final_status() {
    echo ""
    echo -e "${GREEN}${BOLD}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║${NC}  ${BOLD}CÀI ĐẶT HOÀN TẤT!${NC}                                        ${GREEN}${BOLD}║${NC}"
    echo -e "${GREEN}${BOLD}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BOLD}📋 Thông tin service:${NC}"
    echo -e "   Service name:    ${CYAN}n8n-backup.service${NC}"
    echo -e "   Backup location: ${CYAN}/home/minhnc/Desktop/n8n-backup${NC}"
    echo -e "   Interval:        ${CYAN}Mỗi 60 phút${NC}"
    echo ""
    echo -e "${BOLD}🔧 Các lệnh hữu ích:${NC}"
    echo -e "   ${CYAN}sudo systemctl status n8n-backup${NC}     - Xem trạng thái"
    echo -e "   ${CYAN}sudo journalctl -u n8n-backup -f${NC}     - Xem log real-time"
    echo -e "   ${CYAN}sudo systemctl restart n8n-backup${NC}    - Khởi động lại"
    echo -e "   ${CYAN}sudo systemctl stop n8n-backup${NC}       - Dừng service"
    echo -e "   ${CYAN}sudo nano /usr/local/bin/n8n-backup.sh${NC} - Chỉnh sửa cấu hình"
    echo ""
    echo -e "${BOLD}📊 Trạng thái hiện tại:${NC}"
    systemctl status n8n-backup.service --no-pager | head -n 10
    echo ""
    echo -e "${GREEN}✓ Service đang chạy và sẽ tự động backup mỗi giờ!${NC}"
    echo ""
}

# Main installation flow
main() {
    print_header
    
    echo -e "${BOLD}Bắt đầu cài đặt N8N Backup Service...${NC}"
    echo ""
    
    check_root
    check_docker
    check_n8n_container
    
    echo ""
    log_step "Tiến hành cài đặt..."
    echo ""
    
    create_backup_script
    create_systemd_service
    enable_service
    
    sleep 2  # Wait for service to start
    
    show_final_status
}

# Run main
main
