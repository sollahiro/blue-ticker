#!/bin/sh
# PreCompact hook: compact 直前に git 状態を機械的に書き出す保険。
# 賢い引き継ぎ文（handoff.local.md）が古くても、branch・未コミット差分の breadcrumb は残る。
# 失敗しても compact を妨げないよう常に exit 0。

dir="${CLAUDE_PROJECT_DIR:-$(pwd)}"
out="$dir/.claude/handoff-snapshot.local.md"
cd "$dir" 2>/dev/null || exit 0

{
  printf '# PreCompact 自動スナップショット\n'
  printf '生成(UTC): %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'branch: %s\n\n' "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  printf '## 直近コミット\n'
  git log --oneline -5 2>/dev/null
  printf '\n## 未コミットの変更 (git status --porcelain)\n'
  git status --porcelain 2>/dev/null
  printf '\n## 差分統計 (git diff --stat)\n'
  git diff --stat 2>/dev/null
} > "$out" 2>/dev/null

exit 0
