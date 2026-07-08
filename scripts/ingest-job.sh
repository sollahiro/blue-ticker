#!/bin/sh
# blt-server 定期同期ジョブ（Fly スケジュールマシン用）。
#
# Fly の独立スケジュールマシン（serve マシンとは別）でスケジュール起動され、
# sync → ingest を実行して終了する（実行後はマシンごと停止する）。
# 重い ingest が OOM しても serve（API 配信）を巻き込まないための分離。
# このスクリプトからは cloudflared も serve（blt-server 単体起動）も呼ばない。
#
# 機密（DATABASE_URL / BLT_EDINET_API_KEY）は Fly secrets から env に注入される
# 前提（このスクリプト内では読み込まない）。
#
# Linux glibc のアリーナ断片化抑制（issue #35）。IndividualAnalyzer の並列度制限
# （Api.xbrlProcessConcurrency=2）と併用する。
export MALLOC_ARENA_MAX=2
#
# 1 回の ingest 件数は env BLT_INGEST_LIMIT で上書きできる（既定 75）。
# 導入手順は docs/deploy.md「定期同期」を参照。

set -u

BIN=/app/blt-server
INGEST_LIMIT="${BLT_INGEST_LIMIT:-75}"

# 不正値（非数値・0 以下）で blt-server が limit 無制限扱い→OOM しないよう、既定値へフォールバックする。
case "$INGEST_LIMIT" in
  ''|*[!0-9]*) INGEST_LIMIT=75 ;;
esac
if [ "$INGEST_LIMIT" -le 0 ] 2>/dev/null; then
  INGEST_LIMIT=75
fi

echo "===== $(date '+%Y-%m-%d %H:%M:%S') sync 開始 ====="
"$BIN" sync
SYNC_STATUS=$?
if [ "$SYNC_STATUS" -ne 0 ]; then
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') sync 失敗（終了コード $SYNC_STATUS）。ingest は既存の pending 行に対して独立に有効なため続行する ====="
fi

echo "===== $(date '+%Y-%m-%d %H:%M:%S') ingest --limit $INGEST_LIMIT 開始 ====="
"$BIN" ingest --limit "$INGEST_LIMIT"
INGEST_STATUS=$?

echo "===== $(date '+%Y-%m-%d %H:%M:%S') 完了（sync=$SYNC_STATUS ingest=$INGEST_STATUS） ====="

# 終了コードは ingest の結果を伝播する（sync 失敗は許容＝ingest 成功なら 0）。
# ingest 失敗は非0で終了し、fly machine status / 終了コード監視に surface させる。
exit "$INGEST_STATUS"
