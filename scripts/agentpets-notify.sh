#!/bin/sh
#
# AgentPets へ状態を通知する。
#
#   agentpets-notify.sh <status> [message]
#
#   status : idle | working | waiting | success | error
#   message: 吹き出しに出す短い文字列（省略可）
#
# 例:
#   agentpets-notify.sh working "テスト実行中"
#   agentpets-notify.sh error   "テスト2件が失敗"
#
# DistributedNotificationCenter へ投げるだけなので、AgentPets が
# 起動していなければ黙って捨てられる（送信側はブロックしない）。

set -eu

if [ $# -lt 1 ]; then
    echo "usage: $(basename "$0") <idle|working|waiting|success|error> [message]" >&2
    exit 2
fi

status="$1"
message="${2:-}"

STATUS="$status" MESSAGE="$message" osascript -l JavaScript <<'JXA' >/dev/null
ObjC.import("Foundation");

const env = $.NSProcessInfo.processInfo.environment;
const read = (key) => {
    const value = env.objectForKey(key);
    return value.isNil() ? "" : ObjC.unwrap(value);
};

const payload = JSON.stringify({
    status: read("STATUS"),
    message: read("MESSAGE"),
});

$.NSDistributedNotificationCenter.defaultCenter
    .postNotificationNameObjectUserInfoDeliverImmediately(
        $("com.agentpets.status"),
        $(payload),
        $(),
        true
    );
JXA
