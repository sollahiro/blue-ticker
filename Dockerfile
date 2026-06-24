# blt-server の 2 段ビルド。Fly.io（クラウド）・self-host で同一イメージを使う。
# 詳細・デプロイ手順は docs/deploy.md / docs/blt-server-roadmap.md「クラウド構成」を参照。

# ===== ビルドステージ =====
FROM swift:6.1 AS build

WORKDIR /build

# 依存解決を層キャッシュするため、マニフェストのみ先にコピーして resolve する。
COPY Package.swift Package.resolved ./
RUN swift package resolve

# 残りのソースを入れてリリースビルド。CLI（ticker）は不要なので blt-server のみビルドする。
# SwiftPM はビルド対象外も含め全ターゲットのパス存在を検証するため、テストターゲットの
# パス（SwiftTests/）も必要。コンテキストの絞り込みは .dockerignore で行う。
COPY . .
# swift-nio 2.101.x の _NIOFileSystem が Linux で `import CSystem` を欠き、
# upcoming feature MemberImportVisibility（Swift 6.1+）下でエラー化するため一時的に無効化する。
# swift-nio 修正後に除去。詳細: docs/blt-server-roadmap.md「Linux ビルドの既知の問題」
RUN swift build -c release --product blt-server \
    -Xswiftc -disable-upcoming-feature -Xswiftc MemberImportVisibility

# ===== ランタイムステージ =====
# swift:6.1-slim は Swift ランタイム共有ライブラリを内包するため、追加コピー不要で堅牢。
FROM swift:6.1-slim

WORKDIR /app

# サーバーバイナリと EDINET コード CSV のみコピーする。
# assets/taxonomy（約 105MB）はソース未参照のため含めない。
COPY --from=build /build/.build/release/blt-server ./blt-server
COPY assets/EdinetcodeDlInfo.csv ./assets/EdinetcodeDlInfo.csv

# 自己完結する実行時デフォルト（self-host も fly.toml なしでこのまま動く）。
#   BLT_HOST/PORT       : bind（Fly はこのポートへルーティング）
#   BLUE_TICKER_ASSETS_PATH : EDINET コード CSV の場所
#   BLUE_TICKER_USER_DATA_PATH : キャッシュ・設定の永続先（Fly Volume を /data にマウント）
# EDINET キー・認証トークン・DATABASE_URL は secrets で注入する（イメージに焼かない）。
ENV BLT_HOST=0.0.0.0 \
    BLT_PORT=8080 \
    BLUE_TICKER_ASSETS_PATH=/app/assets \
    BLUE_TICKER_USER_DATA_PATH=/data

EXPOSE 8080

# root 実行。Fly Volume は実行時に root:root でマウントされ、非 root だと書き込めないため
# entrypoint での chown を避けて最小構成にする（単一テナントのデータ取り込みサーバー）。
ENTRYPOINT ["./blt-server"]
