#!/bin/bash
# git.sh

cd "$(dirname "$0")" || exit 1

# --- Dam bao cac file tam cua qua trinh ghi-atomic (Minecraft/NeoForge va
#     cac mod nhu Lootr, Sable... ghi ra .neoforge-tmp roi rename thanh .dat)
#     KHONG bao gio bi git dong theo doi. Day la nguyen nhan chinh gay loi
#     "fatal: unable to stat ... No such file or directory": git add -A quet
#     thay ten file tam luc liet ke thu muc, nhung ngay sau do file da bi
#     rename/xoa (vi cac mod van ghi du server da nhan save-off) -> git
#     "hut" theo mot muc tieu dang di chuyen va fail. Ignore han cac file
#     nay thi git khong bao gio dung vao chung nua, het rang buoc thoi gian.
GITIGNORE=".gitignore"
ensure_ignored() {
    local pattern="$1"
    if [ -f "$GITIGNORE" ] && grep -qxF "$pattern" "$GITIGNORE"; then
        return 0
    fi
    echo "$pattern" >> "$GITIGNORE"
}
ensure_ignored "*.neoforge-tmp"
ensure_ignored "*.tmp"
ensure_ignored "session.lock"

# Neu cac file tam nay tung duoc add/track truoc khi co .gitignore, go chung
# khoi index (khong dong den file that tren dia) de gitignore co hieu luc.
git rm -r --cached --ignore-unmatch -q -- '*.neoforge-tmp' '*.tmp' 'session.lock' >/dev/null 2>&1

# --- git add voi retry + backoff tang dan, phong khi con race khac (vd file
#     .dat that su dang duoc rename dung luc git quet, hiem nhung van co the) ---
ADD_OK=0
for i in 1 2 3 4 5; do
    if git add -A 2>/tmp/git_add_err; then
        ADD_OK=1
        break
    fi
    echo "[GIT] add loi (lan $i), thu lai sau $((i*2))s..."
    cat /tmp/git_add_err
    sleep "$((i*2))"
done
rm -f /tmp/git_add_err

if [ "$ADD_OK" -ne 1 ]; then
    echo "[GIT] LOI: git add khong thanh cong sau nhieu lan thu. Bo qua chu ky backup nay (KHONG commit gia)."
    exit 1
fi

if git diff --cached --quiet; then
    echo "[GIT] Khong co thay doi de commit."
    exit 0
fi

message="Auto backup $(date '+%Y-%m-%d %H:%M:%S')"
git commit -m "$message"
git push