#!/usr/bin/env python3
"""採取した hook stdin から個人情報を伏せる。

  python3 -I scripts/redact-fixture.py <in.json> <out.json>

キーの構造と hook_event_name・tool_name・session_id の形は残し、
プロンプト本文・パス・ツールの入出力・メッセージ本文を置き換える。
"""
import json
import sys

KEEP = {"hook_event_name", "tool_name", "notification_type", "matcher",
        "source", "reason", "trigger", "permission_mode", "stop_hook_active",
        "agent_type", "model"}
PATH_KEYS = {"cwd", "transcript_path", "agent_transcript_path", "scratchpad_dir"}


def redact(value, key=None):
    if isinstance(value, dict):
        return {k: redact(v, k) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(v, key) for v in value]
    if key in KEEP or not isinstance(value, str):
        return value
    if key in PATH_KEYS:
        return "/Users/user/projects/demo-project"
    if key in {"session_id", "turn_id", "agent_id", "tool_use_id", "prompt_id"}:
        return value  # 識別子は個人情報ではなく、同一性の検証に要る
    return "<redacted>"


def main():
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, encoding="utf-8") as f:
        data = json.load(f)
    with open(dst, "w", encoding="utf-8") as f:
        json.dump(redact(data), f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")


if __name__ == "__main__":
    main()
