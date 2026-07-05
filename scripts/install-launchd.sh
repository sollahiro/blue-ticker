#!/usr/bin/env zsh
# blt-sync launchd ジョブのインストール／再登録。
#
# scripts/launchd/com.sollahiro.blt-sync.plist.template のプレースホルダー
# __REPO_PATH__ をこのリポジトリの絶対パスへ置換し、
# ~/Library/LaunchAgents へ配置してから bootout + bootstrap する。
# 手順の背景は docs/deploy.md「定期同期（ローカル launchd）」を参照。

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$REPO/scripts/launchd/com.sollahiro.blt-sync.plist.template"
LABEL="com.sollahiro.blt-sync"
DEST="$HOME/Library/LaunchAgents/$LABEL.plist"

sed "s#__REPO_PATH__#$REPO#g" "$TEMPLATE" > "$DEST"

launchctl bootout "gui/$(id -u)" "$DEST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$DEST"

echo "installed: $DEST"
echo "手動実行して検証する場合: launchctl kickstart gui/$(id -u)/$LABEL"
