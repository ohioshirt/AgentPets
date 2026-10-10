#!/bin/sh
# agentpets-hook を release ビルドして ~/.local/bin に置き、hook 設定例を表示する。
# 設定ファイルは書き換えない。spec §3.2。
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$root/Packages/AgentPetsCore" -c release --product agentpets-hook
bin="$(swift build --package-path "$root/Packages/AgentPetsCore" -c release --show-bin-path)/agentpets-hook"
mkdir -p "$HOME/.local/bin"
dest="$HOME/.local/bin/agentpets-hook"
# 実行中・署名済みの既存バイナリを書き換えないよう、同じディレクトリの一時ファイルに複製して mv で置き換える（新しい inode）。
tmp="$(mktemp "$dest.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
cp "$bin" "$tmp"
chmod 755 "$tmp"
mv -f "$tmp" "$dest"
echo "installed: $dest"
cat <<EOF

Claude Code (~/.claude/settings.json の hooks): 次の各イベントに追加する。
  SessionStart UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure
  PermissionRequest Notification Stop StopFailure
    {"type": "command", "command": "$dest --source claude", "async": true}
  SessionEnd（async にしない）
    {"type": "command", "command": "$dest --source claude", "timeout": 2}

Codex (~/.codex/hooks.json の hooks): 次の各イベントに追加し、/hooks で trust する。
  SessionStart SessionEnd UserPromptSubmit PreToolUse PostToolUse
  PermissionRequest Stop Interrupt
    {"type": "command", "command": "$dest --source codex", "async": true}
  （SessionEnd は Codex 側で常に同期実行される。async の指定は無視されるが害は無い）
EOF
