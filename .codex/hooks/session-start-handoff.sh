#!/bin/sh
# SessionStart hook: 起動/再開/compact 後に引き継ぎ文を文脈へ注入し、再開コストを下げる。
# 鮮度は「記録した HEAD から現在の HEAD までのコミット距離」で判定する（mtime は使わない）。
# mtime は cp/エディタ保存/クラウド同期等、内容更新を伴わない操作でも更新されうるため、
# 「ファイルが新しく見えるのに中身が何日も前」という誤検知を招く実例があった。
# HEAD 行が無い旧形式ファイル・squash/rebase で HEAD が辿れない場合のみ mtime にフォールバックする。
# ファイル不在・古すぎる場合は何も出さず exit 0（無関係セッションを汚さない）。

dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"
max_age="${HANDOFF_MAX_AGE_SEC:-86400}"
max_behind="${HANDOFF_MAX_COMMITS_BEHIND:-30}"

mtime() {
  # Linux (GNU stat -c) を先に試し、失敗したら macOS (BSD stat -f) にフォールバック。
  # 逆順だと GNU の `stat -f %m` が FS 状態表示と解釈され多行出力＋非0で値が壊れる。
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

commits_behind() {
  # ファイル内の "HEAD: <sha>" 行から記録済みコミットを取り出し、現在の HEAD までの距離を数える。
  # sha が無い/現在の履歴から辿れない場合は空文字を返す（呼び出し元で mtime にフォールバック）。
  f="$1"
  sha=$(grep -m1 -o 'HEAD: [0-9a-f]\{7,40\}' "$f" 2>/dev/null | awk '{print $2}')
  [ -n "$sha" ] || return 0
  git -C "$dir" cat-file -e "${sha}^{commit}" 2>/dev/null || return 0
  git -C "$dir" rev-list --count "${sha}..HEAD" 2>/dev/null
}

emit() {
  f="$1"; label="$2"
  [ -f "$f" ] || return 0

  behind=$(commits_behind "$f")
  if [ -n "$behind" ]; then
    [ "$behind" -lt "$max_behind" ] || return 0
    printf -- '----- %s（記録済み HEAD から %s コミット遅れ / 無関係なら無視してよい）-----\n' "$label" "$behind"
  else
    m=$(mtime "$f"); [ -n "$m" ] || return 0
    age=$(( $(date +%s) - m ))
    [ "$age" -lt "$max_age" ] || return 0
    printf -- '----- %s（更新 %dh 前・HEAD 未記録のため経過時間で判定 / 無関係なら無視してよい）-----\n' "$label" "$(( age / 3600 ))"
  fi
  cat "$f"
  printf '\n'
}

emit "$dir/.claude/handoff.local.md" "前回セッションからの引き継ぎ"
emit "$dir/.claude/handoff-snapshot.local.md" "PreCompact 自動スナップショット"
exit 0
