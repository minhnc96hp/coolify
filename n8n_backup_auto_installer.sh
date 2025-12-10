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
