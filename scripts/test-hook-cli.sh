#!/bin/sh
# agentpets-hook の約束を検査する。spec §3.1、§4。
#   scripts/test-hook-cli.sh <agentpets-hook のパス>
set -u
bin="$1"
fixtures="$(cd "$(dirname "$0")/.." && pwd)/Packages/AgentPetsCore/Tests/AgentPetsCoreTests/Fixtures"
fail=0

check() { # name, stdin-file, args...
    name="$1"; input="$2"; shift 2
    out="$("$bin" "$@" < "$input")"
    code=$?
    if [ "$code" -ne 0 ] || [ -n "$out" ]; then
        echo "FAIL $name exit=$code stdout=[$out]"; fail=1
    else
        echo "ok   $name"
    fi
}

tmp="$(mktemp -d)"
: > "$tmp/empty"
printf '{' > "$tmp/broken"
printf '{"hook_event_name":"PreCompact","session_id":"s"}' > "$tmp/unknown"
printf '{"hook_event_name":"Stop"}' > "$tmp/nosession"
# 5MB の tool_response（Review Focus 2）
perl -e 'print q({"hook_event_name":"PostToolUse","session_id":"s","tool_name":"Bash","tool_response":"), "x" x 5000000, q("})' > "$tmp/huge"

check empty      "$tmp/empty"     --source claude
check broken     "$tmp/broken"    --source claude
check unknown    "$tmp/unknown"   --source claude
check nosession  "$tmp/nosession" --source claude
check huge       "$tmp/huge"      --source claude
check no-source  "$fixtures/claude/Stop.json"
check bad-source "$fixtures/claude/Stop.json" --source evil
check manual-src "$fixtures/claude/Stop.json" --source manual
check claude     "$fixtures/claude/Stop.json" --source claude
check codex      "$fixtures/codex/SessionEnd.json" --source codex

# 所要時間（spec §5: Codex SessionEnd の既定 1 秒に収まるか）
for f in "$fixtures/codex/SessionEnd.json" "$tmp/huge"; do
    perl -MTime::HiRes=time -e '$t=time; system(@ARGV); printf "time %s %.3fs\n", $ARGV[-1], time-$t' \
        sh -c "\"$bin\" --source codex < \"$f\"" "$(basename "$f")"
done

# 起動の揺れ（2 本同時起動時の ts 差）
for i in 1 2 3 4 5; do
    AGENTPETS_HOOK_DEBUG=1 "$bin" --source claude < "$fixtures/claude/PreToolUse.json" 2> "$tmp/a$i" &
    AGENTPETS_HOOK_DEBUG=1 "$bin" --source claude < "$fixtures/claude/PermissionRequest.json" 2> "$tmp/b$i" &
    wait
    perl -e 'for (@ARGV) { open F, $_; local $/; $s=<F>; push @t, $1 if $s =~ /"ts":([0-9.]+)/ } printf "jitter %.1fms\n", abs($t[0]-$t[1])*1000 if @t==2' "$tmp/a$i" "$tmp/b$i" | tee -a "$tmp/jitter"
done
# grep -c は 0 件でも "0" を出して exit 1 する。|| echo 0 を付けると "0\n0" になり比較が壊れる。
jitters="$(grep -c '^jitter' "$tmp/jitter" 2>/dev/null)"
jitters="${jitters:-0}"
if [ "$jitters" -ne 5 ]; then echo "FAIL jitter lines=$jitters (expected 5)"; fail=1; fi

rm -r "$tmp"
[ "$fail" -eq 0 ] && echo "ALL OK" || { echo "FAILED"; exit 1; }
