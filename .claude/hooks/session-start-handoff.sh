#!/bin/sh
# SessionStart hook: 起動/再開/compact 後に引き継ぎ文を文脈へ注入し、再開コストを下げる。
# 鮮度ゲート（既定 24h）を満たすファイルのみ stdout に出す。stdout は SessionStart の追加文脈になる。
# ファイル不在・古い場合は何も出さず exit 0（無関係セッションを汚さない）。

dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"
max_age="${HANDOFF_MAX_AGE_SEC:-86400}"

mtime() {
  # Linux (GNU stat -c) を先に試し、失敗したら macOS (BSD stat -f) にフォールバック。
  # 逆順だと GNU の `stat -f %m` が FS 状態表示と解釈され多行出力＋非0で値が壊れる。
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

emit() {
  f="$1"; label="$2"
  [ -f "$f" ] || return 0
  m=$(mtime "$f"); [ -n "$m" ] || return 0
  age=$(( $(date +%s) - m ))
  [ "$age" -lt "$max_age" ] || return 0
  printf -- '----- %s（更新 %dh 前 / 無関係なら無視してよい）-----\n' "$label" "$(( age / 3600 ))"
  cat "$f"
  printf '\n'
}

emit "$dir/.claude/handoff.local.md" "前回セッションからの引き継ぎ"
emit "$dir/.claude/handoff-snapshot.local.md" "PreCompact 自動スナップショット"
exit 0
