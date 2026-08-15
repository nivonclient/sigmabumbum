#!/bin/bash
# start.sh

cd "$(dirname "$0")" || exit 1

echo "============================================"
echo "  Dang khoi dong NeoForge Server..."
echo "  Log se hien ra o day va luu vao console_log.txt"
echo "  Nhan Ctrl+C de dung server"
echo "============================================"
echo

# ==== CHINH LAI CHO DUNG VOI SERVER CUA BAN NEU CAN ====
JAR_NAME="${JAR_NAME:-server.jar}"
USER_JVM_ARGS_FILE="user_jvm_args.txt"
RAM_MIN_DEFAULT="4G"
RAM_MAX_DEFAULT="6G"
BACKUP_INTERVAL="${BACKUP_INTERVAL:-300}"
BACKUP_TIMEOUT="${BACKUP_TIMEOUT:-180}"
STOP_TIMEOUT="${STOP_TIMEOUT:-60}"   # so giay cho server tu tat truoc khi force-kill
LOCK_FILE="/tmp/$(basename "$PWD")_backup.lock"
FIFO="server_input.fifo"
LOG_FIFO="watch_log.fifo"
MAX_LOG_SIZE=$((5*1024*1024))
# =========================================================

if [ ! -f "$USER_JVM_ARGS_FILE" ]; then
    cat > "$USER_JVM_ARGS_FILE" <<EOF
# Cac tham so JVM, moi dong mot tham so
-Xms${RAM_MIN_DEFAULT}
-Xmx${RAM_MAX_DEFAULT}
EOF
    echo "[INFO] Da tao file $USER_JVM_ARGS_FILE voi RAM mac dinh (Xms=${RAM_MIN_DEFAULT}, Xmx=${RAM_MAX_DEFAULT})."
    echo "[INFO] Muon doi RAM, sua truc tiep file nay roi chay lai script."
    echo
fi

[ -p "$FIFO" ] || mkfifo -m 600 "$FIFO"
exec 3<>"$FIFO"

[ -p "$LOG_FIFO" ] || mkfifo -m 600 "$LOG_FIFO"
exec 4<>"$LOG_FIFO"

send_cmd() {
    kill -0 "$SERVER_PID" 2>/dev/null && echo "$1" >&3
}

rotate_log_if_needed() {
    if [ -f backup_log.txt ] && [ "$(stat -c%s backup_log.txt 2>/dev/null || echo 0)" -gt "$MAX_LOG_SIZE" ]; then
        mv backup_log.txt "backup_log.txt.old"
    fi
}

do_backup() {
    rotate_log_if_needed
    {
        echo "[BACKUP] Bat dau luc $(date '+%Y-%m-%d %H:%M:%S')"
        send_cmd "save-off"
        send_cmd "save-all flush"
        sleep 3
        if timeout "$BACKUP_TIMEOUT" ./git.sh; then
            echo "[BACKUP] Thanh cong"
        else
            echo "[BACKUP] LOI hoac qua thoi gian cho phep (timeout ${BACKUP_TIMEOUT}s)"
        fi
        send_cmd "save-on"
        echo "[BACKUP] Ket thuc luc $(date '+%H:%M:%S')"
        echo "----------------------------------------"
    } >> backup_log.txt 2>&1
}

backup_loop() {
    while [ ! -f "$SERVER_READY_FLAG" ]; do
        kill -0 "$SERVER_PID" 2>/dev/null || return
        sleep 2
    done
    while kill -0 "$SERVER_PID" 2>/dev/null; do
        sleep "$BACKUP_INTERVAL"
        kill -0 "$SERVER_PID" 2>/dev/null || break
        (
            flock -n 200 || { echo "[BACKUP] Bo qua, lan truoc chua xong ($(date '+%H:%M:%S'))" >> backup_log.txt; exit 0; }
            do_backup
        ) 200>"$LOCK_FILE"
    done
}

# ==== Theo doi console_log.txt qua FIFO rieng (tail -f va vong read la 2 tien trinh
# tach biet, moi tien trinh co PID that de kill trong cleanup, tranh bi mo cong) ====
watch_log() {
    while IFS= read -r line <&4; do
        echo "$line"
        if [[ "$line" == *"Domain assigned:"* ]]; then
            domain=$(echo "$line" | sed -E 's/.*Domain assigned: *([^ ]+).*/\1/')
            echo ""
            echo "=================================================="
            echo "   DIA CHI SERVER:  $domain"
            echo "=================================================="
            echo ""
        fi
        if [[ "$line" == *"Done ("* ]]; then
            touch "$SERVER_READY_FLAG"
        fi
    done
}

SERVER_READY_FLAG="$(mktemp)"
rm -f "$SERVER_READY_FLAG"

CLEANED_UP=0
INT_COUNT=0   # dem so lan bam Ctrl+C, dung de escalate sang force-kill ngay

cleanup() {
    # Chong chay cleanup hai lan (vd: vua nhan Ctrl+C vua trigger EXIT trap)
    [ "$CLEANED_UP" -eq 1 ] && return
    CLEANED_UP=1

    # Neu server con song, yeu cau no tu tat dung cach (luu world) thay vi giet thang
    if kill -0 "$SERVER_PID" 2>/dev/null; then
        echo
        echo "Dang gui lenh 'stop' cho server (cho toi ${STOP_TIMEOUT}s de luu world)..."
        echo "Bam Ctrl+C lan nua neu muon force-kill ngay lap tuc."
        send_cmd "stop"

        local waited=0
        while kill -0 "$SERVER_PID" 2>/dev/null; do
            # Ctrl+C lan 2 tro len trong luc dang cho -> force-kill ngay, khong doi het STOP_TIMEOUT
            if [ "$INT_COUNT" -ge 2 ]; then
                echo "[WARN] Force-kill theo yeu cau (Ctrl+C lan 2, PID $SERVER_PID)..."
                kill -TERM "$SERVER_PID" 2>/dev/null
                sleep 2
                kill -0 "$SERVER_PID" 2>/dev/null && kill -KILL "$SERVER_PID" 2>/dev/null
                break
            fi
            sleep 1
            waited=$((waited + 1))
            if [ "$waited" -ge "$STOP_TIMEOUT" ]; then
                echo "[WARN] Server khong tu tat sau ${STOP_TIMEOUT}s, dang force-kill (PID $SERVER_PID)..."
                kill -TERM "$SERVER_PID" 2>/dev/null
                sleep 5
                kill -0 "$SERVER_PID" 2>/dev/null && kill -KILL "$SERVER_PID" 2>/dev/null
                break
            fi
        done
        echo "Server da dung."
    fi

    echo "Dang dung tien trinh backup/theo doi log va don dep..."
    kill "$BACKUP_PID" 2>/dev/null
    kill "$TAIL_PID" 2>/dev/null
    kill "$WATCH_PID" 2>/dev/null
    wait "$BACKUP_PID" 2>/dev/null
    wait "$TAIL_PID" 2>/dev/null
    wait "$WATCH_PID" 2>/dev/null
    exec 3>&- 2>/dev/null
    exec 4>&- 2>/dev/null
    rm -f "$FIFO" "$LOG_FIFO" "$LOCK_FILE" "$SERVER_READY_FLAG"
}

# Ctrl+C / kill: chi lan bam DAU TIEN moi goi cleanup(); cac lan sau CHI tang
# INT_COUNT (rat nhanh, khong bi chan) de vong cho trong cleanup() thay doi
# huong sang force-kill ngay, thay vi bi nuot mat va thoat ngam nhu truoc.
on_interrupt() {
    INT_COUNT=$((INT_COUNT + 1))
    if [ "$INT_COUNT" -eq 1 ]; then
        cleanup
        exit 0
    fi
}
trap on_interrupt INT TERM
# Truong hop script ket thuc binh thuong (server tu crash/tu stop qua console)
trap cleanup EXIT

# ==== Khoi dong server, ghi truc tiep ra file, LAY DUNG PID CUA JAVA ====
: > console_log.txt   # xoa log cu
if [ -f "./run.sh" ]; then
    bash run.sh nogui <&3 >> console_log.txt 2>&1 &
else
    java "@${USER_JVM_ARGS_FILE}" -jar "$JAR_NAME" nogui <&3 >> console_log.txt 2>&1 &
fi
SERVER_PID=$!    # PID THAT CUA JAVA, khong bi lech qua pipe nua

tail -n +1 -f console_log.txt >&4 2>/dev/null &
TAIL_PID=$!

watch_log &
WATCH_PID=$!

backup_loop &
BACKUP_PID=$!

wait "$SERVER_PID"
SERVER_EXIT_CODE=$?

echo
echo "============================================"
echo "  Server da dung (exit code: $SERVER_EXIT_CODE)."
echo "  Dang tim dia chi e4mc trong log..."
echo "============================================"
grep -i "e4mc" console_log.txt
echo
read -p "Nhan Enter de thoat..."