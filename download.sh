#!/usr/bin/env bash
#
# download_mrpack.sh — Đọc file .mrpack (Modrinth Modpack) và tự động tải
# toàn bộ mod bên trong về thư mục instance, kèm copy các file override.
#
# File .mrpack thực chất là 1 file .zip chứa:
#   - modrinth.index.json  : danh sách mod (tên file, link tải, hash)
#   - overrides/            : các file cấu hình/resource đi kèm (config, resourcepacks...)
#   - client-overrides/     : file override chỉ dùng cho client (nếu có)
#
# Cách dùng:
#   ./download_mrpack.sh -p ModPack-1.2.0.mrpack
#   ./download_mrpack.sh -p ModPack.mrpack -o ~/minecraft/instances/MyPack
#   ./download_mrpack.sh -p ModPack.mrpack -o ./instance --skip-hash-check
#
# Yêu cầu: unzip, jq, và curl hoặc wget
#   Ubuntu/Debian: sudo apt install unzip jq curl
#   Fedora:        sudo dnf install unzip jq curl

set -uo pipefail
# Lưu ý: KHÔNG dùng "set -e" ở đây — kết hợp với vòng lặp while/read đọc từ
# process substitution có thể khiến script thoát âm thầm không báo lỗi khi
# gặp một số tình huống biên (ví dụ EOF của read), rất khó debug.

MRPACK_FILE=""
OUTPUT_DIR="."
MAX_RETRIES=3
SKIP_HASH_CHECK=false
PARALLEL_JOBS=8
FORCE_REPLACE=false

usage() {
    echo "Sử dụng: $0 -p FILE.mrpack [-o THU_MUC_OUTPUT] [-r SO_LAN_THU_LAI] [-j SO_LUONG_TAI_SONG_SONG] [--skip-hash-check] [--force]"
    echo
    echo "  -p FILE     Đường dẫn tới file .mrpack (bắt buộc)"
    echo "  -o DIR      Thư mục cài đặt modpack (mặc định: . — tức thư mục hiện tại)"
    echo "  -r N        Số lần thử lại nếu tải lỗi (mặc định: 3)"
    echo "  -j N        Số file tải song song cùng lúc (mặc định: 8, tăng lên để nhanh hơn)"
    echo "  --skip-hash-check   Bỏ qua bước kiểm tra checksum sau khi tải"
    echo "  --force, -f         Tải lại và ghi đè TẤT CẢ file, kể cả file đã có sẵn đúng checksum"
    echo "  -h          Hiển thị trợ giúp này"
    exit 1
}

# --- parse tham số dòng lệnh (hỗ trợ cả cờ dài --skip-hash-check) ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p) MRPACK_FILE="$2"; shift 2 ;;
        -o) OUTPUT_DIR="$2"; shift 2 ;;
        -r) MAX_RETRIES="$2"; shift 2 ;;
        -j) PARALLEL_JOBS="$2"; shift 2 ;;
        --skip-hash-check) SKIP_HASH_CHECK=true; shift ;;
        --force|-f) FORCE_REPLACE=true; shift ;;
        -h|--help) usage ;;
        *) echo "Tham số không hợp lệ: $1"; usage ;;
    esac
done

if [[ -z "$MRPACK_FILE" ]]; then
    echo "Lỗi: bạn phải chỉ định file .mrpack bằng -p"
    usage
fi

if [[ ! -f "$MRPACK_FILE" ]]; then
    echo "Lỗi: không tìm thấy file '$MRPACK_FILE'"
    exit 1
fi

# --- kiểm tra công cụ cần thiết ---
for tool in unzip jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Lỗi: thiếu công cụ '$tool'."
        echo "  Ubuntu/Debian: sudo apt install $tool"
        echo "  Fedora:        sudo dnf install $tool"
        exit 1
    fi
done

DOWNLOAD_TOOL=""
if command -v curl >/dev/null 2>&1; then
    DOWNLOAD_TOOL="curl"
elif command -v wget >/dev/null 2>&1; then
    DOWNLOAD_TOOL="wget"
else
    echo "Lỗi: cần cài curl hoặc wget để tải file."
    exit 1
fi

# --- thư mục tạm để giải nén .mrpack ---
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

echo "==> Giải nén '$MRPACK_FILE'..."
unzip -q -o "$MRPACK_FILE" -d "$TMP_DIR"

INDEX_FILE="$TMP_DIR/modrinth.index.json"
if [[ ! -f "$INDEX_FILE" ]]; then
    echo "Lỗi: file này không phải modpack Modrinth hợp lệ (thiếu modrinth.index.json)"
    exit 1
fi

PACK_NAME=$(jq -r '.name // "Unknown"' "$INDEX_FILE")
PACK_VERSION=$(jq -r '.versionId // "N/A"' "$INDEX_FILE")
MC_VERSION=$(jq -r '.dependencies.minecraft // "N/A"' "$INDEX_FILE")
FILE_COUNT=$(jq '.files | length' "$INDEX_FILE")

echo "==> Modpack: $PACK_NAME (v$PACK_VERSION) — Minecraft $MC_VERSION"
echo "==> Số mod cần tải: $FILE_COUNT"
echo "==> Cài vào: $OUTPUT_DIR"
if [[ "$FORCE_REPLACE" == true ]]; then
    echo "==> Che do FORCE: se tai lai va ghi de TAT CA file"
fi
echo

mkdir -p "$OUTPUT_DIR"

# --- hàm tải 1 file kèm thử lại (có timeout để tránh treo vô thời hạn) ---
CONNECT_TIMEOUT=15   # giây chờ kết nối
MAX_TIME=180          # giây tối đa cho mỗi lần tải 1 file

download_with_retry() {
    local url="$1"
    local dest="$2"
    local attempt=1

    while (( attempt <= MAX_RETRIES )); do
        if [[ "$DOWNLOAD_TOOL" == "curl" ]]; then
            if curl -L --fail -sS \
                 --connect-timeout "$CONNECT_TIMEOUT" \
                 --max-time "$MAX_TIME" \
                 -o "$dest" "$url"; then
                return 0
            fi
        else
            if wget -q \
                 --connect-timeout="$CONNECT_TIMEOUT" \
                 --timeout="$MAX_TIME" \
                 -O "$dest" "$url"; then
                return 0
            fi
        fi
        ((attempt++))
        sleep 1
    done
    return 1
}

# --- hàm kiểm tra sha1 checksum ---
verify_sha1() {
    local dest="$1"
    local expected="$2"
    if [[ -z "$expected" || "$expected" == "null" ]]; then
        return 0
    fi
    if ! command -v sha1sum >/dev/null 2>&1; then
        return 0
    fi
    local actual
    actual=$(sha1sum "$dest" | awk '{print $1}')
    [[ "$actual" == "$expected" ]]
}

# --- xử lý 1 dòng (1 mod): tải + kiểm tra checksum, in kết quả ra 1 dòng ---
# Hàm này sẽ được chạy song song bởi xargs, mỗi lần chạy trong 1 tiến trình con,
# nên không dùng biến đếm dùng chung (COUNT/FAILED) ở đây — thay vào đó ghi
# trạng thái OK/FAIL/SKIP ra stdout để tổng hợp lại sau.
process_line() {
    local line="$1"
    local rel_path url sha1
    IFS=$'\t' read -r rel_path url sha1 <<< "$line"

    local dest="$OUTPUT_DIR/$rel_path"
    mkdir -p "$(dirname "$dest")"

    if [[ "$FORCE_REPLACE" == false ]] && [[ -f "$dest" ]] && [[ "$SKIP_HASH_CHECK" == false ]] && verify_sha1 "$dest" "$sha1"; then
        echo "SKIP  $rel_path (đã có, đúng checksum)"
        return 0
    fi

    if download_with_retry "$url" "$dest"; then
        if [[ "$SKIP_HASH_CHECK" == false ]] && ! verify_sha1 "$dest" "$sha1"; then
            echo "WARN  $rel_path (checksum không khớp)"
            return 1
        else
            if [[ "$FORCE_REPLACE" == true ]]; then
                echo "FORCE $rel_path (ghi de)"
            else
                echo "OK    $rel_path"
            fi
            return 0
        fi
    else
        rm -f "$dest"
        echo "FAIL  $rel_path"
        return 1
    fi
}

export -f download_with_retry verify_sha1 process_line
export DOWNLOAD_TOOL CONNECT_TIMEOUT MAX_TIME MAX_RETRIES OUTPUT_DIR SKIP_HASH_CHECK FORCE_REPLACE

# --- trích danh sách file cần tải ra 1 file tạm (dễ debug hơn process substitution) ---
TSV_FILE="$TMP_DIR/files.tsv"
jq -r '.files[] | [.path, (.downloads[0]), (.hashes.sha1 // "null")] | @tsv' "$INDEX_FILE" > "$TSV_FILE"

LINES_READ=$(wc -l < "$TSV_FILE" | tr -d ' ')
echo "==> Đọc được $LINES_READ dòng từ modrinth.index.json (kỳ vọng: $FILE_COUNT)"

if [[ "$LINES_READ" -eq 0 ]]; then
    echo "Lỗi: jq không trích xuất được danh sách mod nào. Kiểm tra thủ công bằng lệnh:"
    echo "  unzip -p '$MRPACK_FILE' modrinth.index.json | jq '.files[0]'"
    exit 1
fi
echo "==> Tải song song $PARALLEL_JOBS file cùng lúc..."
echo

# --- tải song song bằng xargs -P, ghi toàn bộ kết quả ra 1 file log ---
RESULTS_FILE="$TMP_DIR/results.log"
: > "$RESULTS_FILE"

xargs -d '\n' -P "$PARALLEL_JOBS" -I{} bash -c 'process_line "$@"' _ {} \
    < "$TSV_FILE" | tee -a "$RESULTS_FILE"

FAILED=$(grep -c -E '^(FAIL|WARN)' "$RESULTS_FILE" || true)
COUNT="$LINES_READ"

# --- copy các file override (config, resourcepacks, shaderpacks...) ---
for override_dir in "overrides" "client-overrides"; do
    src="$TMP_DIR/$override_dir"
    if [[ -d "$src" ]]; then
        echo
        echo "==> Copy $override_dir/ vào $OUTPUT_DIR ..."
        cp -rf "$src"/. "$OUTPUT_DIR"/
    fi
done

echo
if (( FAILED > 0 )); then
    echo "Hoàn tất với $FAILED lỗi. Kiểm tra lại các dòng cảnh báo/thất bại ở trên."
    exit 1
else
    echo "Hoàn tất! Modpack '$PACK_NAME' đã được cài đặt đầy đủ vào: $OUTPUT_DIR"
fi