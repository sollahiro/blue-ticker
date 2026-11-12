# 有報LAB リブランディング方針

出典: 旧課題管理のチケット（移行日 2026-11-12）。当時の題名: 有報LAB リブランディング計画（表に出る名称を移行、blt 接頭辞は維持）。
この文書は決定・契約の正本としてリポジトリで維持する。件数や進捗の最新値はここに書かない。

## 方針（2026-10-27 決定）

* 製品名として表に出るもの（API、MCP、ドキュメント、フィード）は「有報LAB」に統一する。
* 内部の `blt` 接頭辞は **Business Line Terminal** の略として残す（`blt-ingest`、`BLT_*` 環境変数、`blt_reader` / `blt_feed_reader` ロール）。旧課題管理のチームキーも同じ略だったが、いまの正本はリポジトリのこの文書と `AGENTS.md`。
* 「blt は Business Line Terminal の略」と `AGENTS.md` に明記し、エージェントが旧ブランドの残りとして消さないようにする。
* 英字の識別子は `yuholab`（ドメインに合わせる）。`yuho-lab` にはしない（`AGENTS.md` で確定）。

## 現状（読み取り調査 2026-10-27、以降の進捗は Sheet）

* 調査時点: blue-ticker @ `3a5fe026` で約1,700か所、hapis @ `21ca050` で約135か所（28ファイル）の表記が残っている。
* iOS の表示名（`CFBundleDisplayName`）と法務ページ（`yuholab.com`）は対応済み。`sollahiro.com/blue-ticker/*` は 301 で残している。
* 内蔵 MCP は 2026-11-08 に廃止。公開コネクタは HAPIS 側。

## 残作業（壊れるものはほぼない表示名・ドキュメント）

- [ ] README、docs、`AGENTS.md`、`.agents/**` に残る「Blue Ticker」「ブルーティッカーAPI」表記を「有報LAB」に変更（新たに旧名を書かない）
- [x] `blt` の意味（Business Line Terminal）をルールに一行追加
- [ ] GitHub リポジトリ名 `sollahiro/blue-ticker` を変えるか判断（変える場合は CI などの URL も追随）
- [ ] 公開フィード `feed.sollahiro.com/blue-ticker/...` のパスを移行（購読者側が壊れるので 301 で並行させる）

## API・MCP の名称（外部の利用者に影響あり）

- [ ] HAPIS のカタログ slug `blue-ticker`（`examples/blue-ticker-v0.json`、`/v1/apis/blue-ticker/...`）を新 slug に変更。旧名は互換期間中は別名として残す
- [ ] HAPIS 側の MCP Worker 名と `SERVER_INFO.name` を変更。提出済みのコネクタ名と URL も更新する
- [ ] 本番ゲートウェイの Worker `hapis-blue-ticker-production` を改名（ホスト名と service binding も追随）
- [x] `/v1/*` の REST パスはブランド名を含まないので変更しない

## 「blue-ticker」と綴りで書いたインフラ資源

多くは改名できないので、新しく作って切り替えるか、内部名として残す。

- [ ] R2 バケットはコピーして切り替えるか、内部名として残すかを判断（`blt-public-feed` は blt なので維持）
- [ ] Neon プロジェクト `blue-ticker` は表示名だけ変更（ID はそのまま）
- [ ] Worker `blt-feed-rss`、`blt-feed-trend`、`blt-legal` と Fly の `blt-server` / `blt_data` は blt なので維持

## 内部の識別子（必要な分だけ対応）

- [ ] Swift モジュール `BlueTicker` と `BlueTickerCore`、`BLUE_TICKER_ASSETS_PATH`、`~/.config/blue-ticker` を変えるか判断（変えると Mac の取り込みに影響する）
- [ ] iOS のバンドル ID `com.sollahiro.BlueTicker`、CloudKit、Keychain、App Attest は**残す**ことを推奨（App Store と既存ユーザーのデータにつながっているため）
- [x] `cache_version` はブランド名を含まないので変更しない

## 未決事項

1. ~~英字の名前を `yuholab` と `yuho-lab` のどちらにするか~~ → **`yuholab`**（`AGENTS.md`）
2. HAPIS の slug と MCP 名の互換期間（旧名を別名として何か月残すか）
3. R2 バケット、Swift モジュール、設定フォルダなど「blue-ticker」と綴った内部名を残すか
4. フィードのパスを新しくするか（301 で並行させるか）
5. GitHub リポジトリ名を変えるか

## おすすめの順番

表示名とドキュメント → API・MCP（互換を残す） → インフラ資源 → リポジトリ名。フィードは必要な分だけ。

## 関連

Claude Connectors Directory への掲載は公開 MCP の出荷面。進捗はオーナー管理のトラッカー Sheet（`docs/process/tracker-placement.md`）。
