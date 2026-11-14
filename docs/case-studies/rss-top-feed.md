<!-- 移行元: 旧課題管理のドキュメント。正本はこのファイル。件数の最新値は書かない。 -->

# RSS活用事例：Top feed の高速化と軽量化

> 履歴スナップショット（2026-10-19）。当時「iOS 側は実装予定」と書いた箇所は、現行の正本 `docs/ios-client.md`（Top feed）が勝つ。
>
> 作成: 2026-10-19。有報LAB の iOS「Top feed（最近の有報アップロード）」を、認証付き REST `/v1/feed/updates` から公開静的 RSS（`feed.sollahiro.com`）へ移す事例の要約。サーバー側（RSS へのアイコン追加）は完了・デプロイ済み。計測の詳細は当時のメモのまま残す。

## 一言

RSS は「誰でも読める新しい API」ではなく、**1 日 1 回しか変わらないデータを、事前に作り置いた静的ファイルとして配る**ための形。毎回サーバーで組み立てていた Feed を、cron で生成して R2 に置き、iOS は端末に保存した分をすぐ出して `ETag` で差分だけ確かめる。結果として、表示のたびに HAPIS・オリジン・Neon を待つ経路がなくなる。

## 共通パターン（改善の型）

| 層 | 役割 | REST 時代 | RSS 後 |
| -- | -- | -- | -- |
| 生成 | 一覧を組み立てる | リクエストごとに Neon をクエリして JSON を組み立てる | **1 日 1 回** cron（19:15 JST）で XML を作って R2 に置く |
| 配信 | クライアントへ届ける | トークン取得 → HAPIS → オリジン → Neon | R2 カスタムドメインの静的配信（brotli 圧縮・`ETag`・`Cache-Control`） |
| 端末 | 表示する | 毎回取得を待つ（Feed はキャッシュしない） | 保存済みをすぐ表示し、裏で条件付き GET（ふだんは 304） |
| 付加情報 | アイコン | `icon_url` がなければ拡張子を最大 5 回試す | RSS の `media:thumbnail` で URL を渡す（1 回） |

データの鮮度は元から日次の取り込み（18:00 JST の blt-sync）に縛られていたので、RSS の 1 日 1 回更新で失うものはほぼない。

---

## 事例1 — Top feed の取得経路（旧チケット 134 / 旧 旧チケット 135）

**問題:** iOS は Top を開くたびに `/v1/feed/updates` を待っていた。REST は接続を使い回しても約 680ms から縮まらず、時間のほぼ全部がサーバーの処理（Neon のクエリと組み立て）。Cloudflare のキャッシュも効いていなかった（`Cf-Cache-Status: DYNAMIC`）。iOS の実経路はさらにトークン取得と HAPIS を通るので、もっと遅い。

**改善:**

1. 見出しだけの公開 RSS 2.0 を Cron Worker `blt-feed-rss` で生成し、R2（`blt-public-feed`）に置く（PR Add daily static RSS feed of listed EDINET filings (Cron Worker → R2)、2026-10-10 公開）
2. iOS の Top feed の取得元を RSS に切り替える（旧チケット 134、実装予定）
3. 件数と期間は RSS に合わせる（直近 7 日・最大 200 件・間引きなし）。7 日間に新着がなければセクションごと出さない。REST へのフォールバックは持たない

**簡略化:** iOS 側の「10 件に絞る・同じ日の間引き」はサーバーにもアプリにも要らなくなる。Top feed から HAPIS のレート制限（60/分）も消える。

---

## 事例2 — 端末キャッシュと条件付き GET（旧チケット 134）

**問題:** `ios-client.md` は「検索・Feed はキャッシュしない」。2 回目以降の起動でも毎回ネットワークを待っていた。

**改善:**

1. 生の XML と `ETag` / `Last-Modified` / 取得時刻を Caches に保存し、Top を開いたらすぐ解析して出す（stale-while-revalidate）
2. 裏で `If-None-Match` / `If-Modified-Since` を付けて取り直す。304 なら何もしない、200 なら差し替える
3. 前回取得から 1 時間（RSS の `max-age`）以内は取り直さない。通信に失敗しても保存済みの分を出し続ける

**簡略化:** 静的ファイルなので、キャッシュの正しさを HTTP の `ETag` に任せられる。独自の有効期限ロジックを持たない。

---

## 事例3 — 会社アイコン（PR Feed RSS に会社アイコン URL を載せる（media:thumbnail））

**問題:** iOS はアイコンの URL が分からないと、`icons.sollahiro.com/company-icons/{code}.{ico,png,jpg,gif,bmp}` を順に試す（1 社で最大 5 往復）。RSS に載せずにアイコン URL を一覧で取るには、新しいアイコン用 REST エンドポイントが要るが、それは公開したくなかった。

**改善:**

1. Worker が `company_icons` を 1 回のクエリで引き、アイコンのある会社の item に `<media:thumbnail url="…"/>` を付ける。URL は REST の `icon_url` と同じ規則
2. アイコンは付加情報として扱う。ベース URL が未設定のときや、クエリが失敗したとき（権限不足を含む）は、アイコンなしで RSS を書き続ける
3. 本番 Neon の読み取り専用ロール `blt_feed_reader` に `company_icons` の参照権限を付与（2026-10-19）。Worker をデプロイ済み（Version 9a307d8c）。アイコン付きの初回生成は 2026-10-20 19:15 JST

**公開範囲の判断:** PR Add daily static RSS feed of listed EDINET filings (Cron Worker → R2) では「会社アイコンは載せない（認証越しの配信のみ）」と決めていた。一度はそれを保つと判断したが、アイコン画像自体はすでに認証なしで取れ、URL の形もアプリに入っているので、増えるのは「直近 7 日の約 200 社の対応表」だけと整理し、速度を優先して方針を変えた（2026-10-19 Sorahiro）。アイコン専用のエンドポイントは作らず、アイコン URL を一覧で出す公開面は RSS だけにする。

**簡略化:** 1 社 1 往復になり、アイコン用 API も増えない。2026-10-19 時点で、直近 7 日の 169 社中 153 社（約 9 割）にアイコンがある。

---

## 計測（2026-10-19、ネットワーク部分のみ）

クラウドのコンテナから curl で各 30 回。warm は接続を使い回したときの値。

| ケース | 転送量（圧縮後） | warm 中央値 / p90 | cold 中央値 / p90 |
| -- | -- | -- | -- |
| Before：REST `/v1/feed/updates`（10 件） | 0.7KB | 684ms / 813ms | 705ms / 938ms |
| After：RSS 全件（最大 200 件） | 6.9KB | 168ms / 322ms | 356ms / 451ms |
| After：RSS 304（変更なし） | 0B | 137ms / 163ms | 302ms / 416ms |

* 1 回の取得は約 1/4〜1/5。さらに After では画面表示がネットワークを待たない（待つのは初回起動だけ）
* Before は HAPIS を通らない経路で測った下限値で、iOS の実際の差はもっと大きい
* 端末の回線と XML 解析は含んでいない。実機の Before/After は下の「実機計測」

---

## 実機計測（2026-10-21、iPhone 16）

Release 構成を開発署名で実機に入れ、プロセス起動から Top の最初の行が画面に出るまでを測った（`devicectl` で冷起動、各 5〜8 回の中央値）。Before は `main`（`4f6f889`）、After は PR [#533](https://github.com/sollahiro/blue-ticker/pull/533)（`2b87e89`）。計測コードは一時コピーにだけ入れ、リポジトリには入れていない。TestFlight ビルドは Instruments から attach できないため使わなかった。

| ケース | 最初の行が出るまで | うち通信 |
| -- | -- | -- |
| Before：REST `/v1/feed/updates`（HAPIS 経由・10 件） | 1,219ms | 1,012ms |
| After：RSS 初回（保存なし・153 件） | 844ms | 550ms（200） |
| After：保存あり（取得から 1 時間以内） | 342ms | なし |
| After：保存あり（1 時間超・304） | 312ms | 裏で 664ms（表示は待たない） |

* 2 回目以降の起動では約 0.9 秒（約 1/4）、保存のない初回でも約 0.4 秒速い
* 件数は Before 10 件、After 153 件で揃っていないが、件数の効きは小さい。RSS の解析は 153 件で 9.1ms（1 件あたり約 0.06ms、10 件なら 0.8ms。Mac で計測）。データが届いてから行が出るまでは両方とも約 50ms で、List は見えている行しか作らないので件数に比例しない
* 差のほとんどは通信。After の保存ありでは表示がネットワークを待たない
* 起動から Top の読み込み開始までの約 160ms（アプリの初期化と最初の描画）は両方に共通で、RSS では縮まらない

---

## まだ残っているところ

* iOS 側の実装（取得元の切り替え、端末キャッシュ、アイコンのディスク保存、画面に入った行から順に読み込む）→ 旧チケット 134
* `ios-client.md` の「Feed はキャッシュしない」「直近 90 日・最大 10 件」の書き換え → 旧チケット 134
* RSS のチャネル説明文が「ヘッドラインのみを配信します」のまま（アイコン URL も載るようになった）
* アイコン配信に `Cache-Control` がなく、Cloudflare でキャッシュされていない。R2 側に付けるのは本番 write なので後回し
* REST 経路の改善（COUNT 2 本の削除 旧チケット 133、区間計測 旧チケット 132）は、REST を使う他の利用者のために別に残す

---

## 参照クイックリンク

| 用途 | リンク |
| -- | -- |
| 仕様・決定事項・計測 | 旧チケット 134（旧チケット 135 を統合） |
| 公開 RSS の新設 | PR Add daily static RSS feed of listed EDINET filings (Cron Worker → R2) |
| RSS へのアイコン追加 | PR Feed RSS に会社アイコン URL を載せる（media:thumbnail）（マージ済み `10060ed`） |
| 公開 RSS | [https://feed.sollahiro.com/blue-ticker/edinet-filings.xml](<https://feed.sollahiro.com/blue-ticker/edinet-filings.xml>) |
| 公開範囲の正本 | `docs/public-api.md`「例外: 静的 RSS」 |
| Worker の手順 | `workers/feed-rss/README.md` |
| REST 経路の改善 | 旧チケット 133、旧チケット 132 |

