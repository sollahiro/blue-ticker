#!/bin/sh
# blt-server（+ cloudflared サイドカー）のエントリポイント。
# CLOUDFLARE_TUNNEL_TOKEN 未設定時は cloudflared を起動しない（self-host 互換）。
#
# 認証は Cloudflare Access のエッジ信頼（方式A）で、origin は JWT を検証しない。
# その前提が成立するのは「到達経路が Tunnel のみ」のときだけなので、
# cloudflared が死んだまま blt-server だけが残る状態を作らない
# （片方が終了したらもう片方も止め、非ゼロ終了で Fly に再起動させる）。
set -e

if [ -z "$CLOUDFLARE_TUNNEL_TOKEN" ]; then
  exec ./blt-server
fi

cloudflared tunnel --no-autoupdate run --token "$CLOUDFLARE_TUNNEL_TOKEN" &
CLOUDFLARED_PID=$!
./blt-server &
SERVER_PID=$!

# /proc が無い環境（macOS 等。本スクリプトはコンテナ専用だが、誤ってローカル実行した場合に
# サーバーが即 kill されるのを防ぐ）では監視を諦め、サーバーの終了だけを待つ従来動作に落とす。
if [ ! -d /proc ]; then
  echo "warning: /proc が見つかりません。cloudflared の監視なしで起動します（コンテナ外実行？）" >&2
  wait "$SERVER_PID"
  status=$?
  kill -TERM "$CLOUDFLARED_PID" 2>/dev/null || true
  exit "$status"
fi

# 片方の終了を監視する。終了検出は /proc/<pid>/stat の state フィールドで行う
# （終了した子は親シェルが wait するまで zombie として残り、kill -0 では
# 生存と区別がつかないため。親はこのシェルなので state=Z で確実に検出できる）。
while :; do
  server_state=$(cut -d' ' -f3 "/proc/$SERVER_PID/stat" 2>/dev/null) || server_state=""
  cf_state=$(cut -d' ' -f3 "/proc/$CLOUDFLARED_PID/stat" 2>/dev/null) || cf_state=""
  if [ -z "$server_state" ] || [ "$server_state" = "Z" ]; then
    echo "blt-server exited; stopping cloudflared" >&2
    break
  fi
  if [ -z "$cf_state" ] || [ "$cf_state" = "Z" ]; then
    echo "cloudflared exited; stopping blt-server (origin must not run without the tunnel)" >&2
    break
  fi
  sleep 5
done

kill -TERM "$SERVER_PID" "$CLOUDFLARED_PID" 2>/dev/null || true
wait 2>/dev/null || true
exit 1
