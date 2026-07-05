#!/bin/zsh
# blt-server 定期同期ジョブ（ローカル launchd 用）。
#
# Stage 1 (sync: 書類一覧 → Neon) → Stage 4/4-half (ingest: 計算済み財務サマリ
# → Neon) をローカルで実行する。重い ingest を Fly(1GB) で走らせると OOM するため、
# 計算はローカル・Fly は company_financials を読むだけ。
# Stage 3（XBRL 数値 fact）は停止中（issue #22。Neon 512MB 対策で消費者ができるまで
# 蓄積を止める）。再開する場合は下の ingest に --with-facts を付ける。
#
# 機密（DATABASE_URL / BLT_EDINET_API_KEY）はリポジトリ直下 .env から読む。
# バイナリはリリースビルドを使う。コード変更後は手動で再ビルドすること:
#   swift build -c release --product blt-server
#
# 1 回の ingest 件数は BLT_INGEST_LIMIT で上書きできる（既定 200）。
# インストール手順は docs/deploy.md「定期同期（ローカル launchd）」を参照。

set -uo pipefail

# スクリプト位置からリポジトリルートを導出（移植可能にする）
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$REPO/.build/release/blt-server"
LOG="$REPO/.build/blt-scheduled.log"

cd "$REPO" || exit 1

if [ ! -x "$BIN" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: $BIN がありません。先に 'swift build -c release --product blt-server' を実行してください。" >> "$LOG"
  exit 1
fi

if [ ! -f "$REPO/.env" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: $REPO/.env がありません（DATABASE_URL / BLT_EDINET_API_KEY が必要）。" >> "$LOG"
  exit 1
fi

# .env から環境変数を読み込む（裸書きのキー値を想定。クォートで囲まない）。
# BLT_INGEST_LIMIT の一時的な上書きも .env に書けば反映される（plist はテンプレートから
# 生成する共有ファイルのため、マシン固有のチューニング値は .env 側に置く）。
set -a
. "$REPO/.env"
set +a

INGEST_LIMIT="${BLT_INGEST_LIMIT:-200}"

{
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') sync 開始 ====="
  "$BIN" sync
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') ingest --limit $INGEST_LIMIT 開始 ====="
  "$BIN" ingest --limit "$INGEST_LIMIT"
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') 完了 ====="
} >> "$LOG" 2>&1
