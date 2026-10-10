#!/bin/sh
# 開発中だけ hook に登録し、stdin をそのまま保存する。
#   capture-hook.sh <source>
# 保存先は $AGENTPETS_CAPTURE_DIR（既定 ~/agentpets-capture）。
# 受け取った時刻（ナノ秒）も別ファイルに残し、起動の揺れの見積もりに使う。
set -u
dir="${AGENTPETS_CAPTURE_DIR:-$HOME/agentpets-capture}"
mkdir -p "$dir" 2>/dev/null || exit 0
stamp="$(perl -MTime::HiRes=time -e 'printf "%.6f", time')"
cat > "$dir/$1-$stamp-$$.json" 2>/dev/null
exit 0
