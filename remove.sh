#!/usr/bin/env bash
#
# remove_list.sh — Tự động xóa các file theo một danh sách (list-in) cho trước.
#
# Cách dùng:
#   1) Xóa theo danh sách (mỗi dòng 1 tên file hoặc đường dẫn):
#        ./remove_list.sh -f remove_list.txt
#
#   2) Chỉ định thư mục gốc để tìm file (mặc định: thư mục hiện tại):
#        ./remove_list.sh -f remove_list.txt -d ./mods
#
#   3) Xem trước sẽ xóa gì mà CHƯA xóa thật (an toàn để kiểm tra trước):
#        ./remove_list.sh -f remove_list.txt --dry-run
#
#   4) Bỏ qua bước xác nhận, xóa luôn không hỏi lại:
#        ./remove_list.sh -f remove_list.txt --yes
#
#   5) Sao lưu file trước khi xóa (chuyển vào thư mục backup thay vì xóa hẳn):
#        ./remove_list.sh -f remove_list.txt --backup ./removed_backup
#
# File danh sách (list-in): mỗi dòng là 1 tên file hoặc đường dẫn cần xóa.
# Dòng trống và dòng bắt đầu bằng # sẽ được bỏ qua. Ví dụ nội dung:
#   # Các mod không dùng nữa
#   old-mod-1.jar
#   mods/old-mod-2.jar
#   resourcepacks/unused-pack.zip

set -uo pipefail

LIST_FILE=""
TARGET_DIR="."
DRY_RUN=false
ASSUME_YES=false
BACKUP_DIR=""
RECURSIVE_SEARCH=false

usage() {
    echo "Sử dụng: $0 -f LIST_FILE [-d THU_MUC] [--dry-run] [--yes] [--backup DIR] [--recursive]"
    echo
    echo "  -f LIST_FILE   File danh sách chứa tên/đường dẫn file cần xóa (bắt buộc)"
    echo "  -d DIR         Thư mục gốc để tìm file (mặc định: thư mục hiện tại)"
    echo "  --dry-run      Chỉ liệt kê file sẽ bị xóa, KHÔNG xóa thật"
    echo "  --yes          Bỏ qua bước xác nhận, xóa ngay"
    echo "  --backup DIR   Thay vì xóa hẳn, di chuyển file vào thư mục backup này"
    echo "  --recursive    Nếu không tìm thấy theo đường dẫn chính xác, tìm đệ quy trong -d theo tên file"
    echo "  -h             Hiển thị trợ giúp này"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f) LIST_FILE="$2"; shift 2 ;;
        -d) TARGET_DIR="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --yes) ASSUME_YES=true; shift ;;
        --backup) BACKUP_DIR="$2"; shift 2 ;;
        --recursive) RECURSIVE_SEARCH=true; shift ;;
        -h|--help) usage ;;
        *) echo "Tham số không hợp lệ: $1"; usage ;;
    esac
done

if [[ -z "$LIST_FILE" ]]; then
    echo "Lỗi: bạn phải chỉ định file danh sách bằng -f"
    usage
fi

if [[ ! -f "$LIST_FILE" ]]; then
    echo "Lỗi: không tìm thấy file danh sách '$LIST_FILE'"
    exit 1
fi

if [[ ! -d "$TARGET_DIR" ]]; then
    echo "Lỗi: không tìm thấy thư mục '$TARGET_DIR'"
    exit 1
fi

if [[ -n "$BACKUP_DIR" ]]; then
    mkdir -p "$BACKUP_DIR"
fi

# --- đọc danh sách, bỏ dòng trống / comment, và tìm ra file thật sự tồn tại ---
declare -a FOUND_PATHS=()
declare -a MISSING_NAMES=()

while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(echo "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -z "$line" || "$line" =~ ^# ]] && continue

    candidate="$TARGET_DIR/$line"

    if [[ -e "$candidate" ]]; then
        FOUND_PATHS+=("$candidate")
    elif [[ "$RECURSIVE_SEARCH" == true ]]; then
        # tìm đệ quy theo tên file (basename) trong toàn bộ TARGET_DIR
        match=$(find "$TARGET_DIR" -type f -iname "$(basename "$line")" -print -quit 2>/dev/null || true)
        if [[ -n "$match" ]]; then
            FOUND_PATHS+=("$match")
        else
            MISSING_NAMES+=("$line")
        fi
    else
        MISSING_NAMES+=("$line")
    fi
done < "$LIST_FILE"

TOTAL_FOUND=${#FOUND_PATHS[@]}
TOTAL_MISSING=${#MISSING_NAMES[@]}

echo "==> Danh sách: $LIST_FILE"
echo "==> Thư mục gốc: $TARGET_DIR"
echo "==> Tìm thấy: $TOTAL_FOUND file để xóa"
if (( TOTAL_MISSING > 0 )); then
    echo "==> Không tìm thấy: $TOTAL_MISSING mục (sẽ bỏ qua)"
fi
echo

if (( TOTAL_FOUND == 0 )); then
    echo "Không có file nào để xóa. Kết thúc."
    exit 0
fi

echo "Các file sẽ bị xóa:"
for p in "${FOUND_PATHS[@]}"; do
    echo "  - $p"
done
echo

if (( TOTAL_MISSING > 0 )); then
    echo "Các mục KHÔNG tìm thấy (bỏ qua):"
    for n in "${MISSING_NAMES[@]}"; do
        echo "  ? $n"
    done
    echo
fi

if [[ "$DRY_RUN" == true ]]; then
    echo "(--dry-run) Chưa xóa gì cả, đây chỉ là bản xem trước."
    exit 0
fi

if [[ "$ASSUME_YES" == false ]]; then
    read -r -p "Xác nhận xóa $TOTAL_FOUND file ở trên? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Đã hủy, không xóa gì cả."
        exit 0
    fi
fi

REMOVED=0
FAILED=0

for p in "${FOUND_PATHS[@]}"; do
    if [[ -n "$BACKUP_DIR" ]]; then
        if mv -f "$p" "$BACKUP_DIR/"; then
            echo "  Đã chuyển vào backup: $p"
            ((REMOVED++)) || true
        else
            echo "  LỖI khi di chuyển: $p"
            ((FAILED++)) || true
        fi
    else
        if rm -rf "$p"; then
            echo "  Đã xóa: $p"
            ((REMOVED++)) || true
        else
            echo "  LỖI khi xóa: $p"
            ((FAILED++)) || true
        fi
    fi
done

echo
if (( FAILED > 0 )); then
    echo "Hoàn tất với $FAILED lỗi. Đã xử lý thành công $REMOVED/$TOTAL_FOUND file."
    exit 1
else
    echo "Hoàn tất! Đã xử lý $REMOVED/$TOTAL_FOUND file."
fi