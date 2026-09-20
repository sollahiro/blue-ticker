---
name: company-icons
description: JP 上場の会社アイコン欠測・iOS 不能／低視認を manualSources にピンし、R2 と本番 icons ingest まで持っていく。週次 Cursor Automation、差し替え GO、WRITE ingest、失敗の手順訂正。
---

# 会社アイコン（manualSources）

週次 CA と手動ピンの正本。App Icon は対象外。1社1枚。自動 ingest（有報120・府令010 → 電子公告 origin → favicon → R2、`cache_version=icons-v2`）が使える会社は触らない。

失敗パターンの手順化もこのファイルに書く。別 skill に分けない。Cursor Automation の本文はこの CA から書き換えられないので、手順の訂正は **この SKILL を PR する**。

## 先に読む

- `docs/icons-manual-skips.md`（毎ラン開始時。対象除外）
- `Sources/BlueTicker/Analysis/CompanyIconOriginOverride.swift` の `manualSources`（重複禁止）
- 本番 write 境界: `.agents/skills/production-ingest/SKILL.md`
- 実装コメント: `FaviconFetcher.swift`（UA・8s・マジックバイト・WP 既定ハッシュ）

## Cursor Automation プロンプト（貼り付け用）

ダッシュボードのジョブ本文は短くする。手順は毎回この skill を読む。

```
JP 上場の会社アイコン欠測・iOS 不能／低視認を直し、本番に載る状態まで持っていく。
App Icon は対象外。1社1枚。

最初に `.agents/skills/company-icons/SKILL.md` を全文読む。禁止事項・候補出し・GO・R2・ingest・自己修正はそこが正本。

やる: 公式 HTTPS を manualSources に足す（Git はテキストのみ）。公式が無く外部だけなら外部 URL は Git 禁止、実 GET → R2 → CDN URL のみ。テスト 1:1。Ready PR。マージ後この CA が WRITE icons ingest。スキップ台帳を更新。ランで見つかった手順の穴はこの skill を直して同じ PR（または直後の PR）に含める。

やらない: PR Times 等をマップ／テストに書く、画像バイナリを Git へ、Core への画像パイプライン、icons-vN バンプ、TLS 弱体化、無関係リファクタ、明示のない Linear コメント、明示のない既存 URL 変更、Icon Clerk へ渡す。

欠測の新規ピンは visual GO なしで Ready PR 可。差し替えは Before/After とユーザー visual GO 必須。未 GO はマップに入れない。差し替えと欠測を同じ Ready PR に混ぜない。

visual GO = ユーザー。merge = 通常は Maintainer risk GO のあと CA が実行。WRITE = マージ後、この CA が skill の ingest 節に従う。

週次 icons Automation の狭い例外: skill に書いた 5 条件がすべて揃ったときだけ、GrokBot 部屋ターンを待たずに Automations がこの CA を起動して merge+WRITE してよい。例外外は Maintainer risk GO → そのあと CA が merge。
```

## 境界

**やる**

- 公式サイト由来: 公開 HTTPS の `.homepageOrigin` / `.imageURL` を `manualSources` に足す（Git はテキストのみ）
- 公式が無く外部（PR Times 等）だけ: **外部 URL は Git に書かない**。実 GET → R2 `company-icons/{code}.*` → マップは CDN URL のみ（`$BLT_R2_PUBLIC_BASE_URL/company-icons/{code}.*`。既存行と同じ `pragma: allowlist secret`）
- テスト 1:1
- Ready PR（visual GO / merge の可否は権限節）
- マージ後 WRITE ingest（下記）
- スキップ台帳の更新
- このランの失敗を手順に残すなら **この SKILL を更新**

**やらない**

- 外部サイト URL を `manualSources` やテスト期待値に書く
- 画像バイナリを Git に載せる
- Core への crop/resize/pad パイプライン（ワンオフで R2 用 PNG を整えるのは可。製品コードには入れない）
- `icons-vN` / `companyIconsCacheVersion` バンプ
- グローバル TLS 弱体化、FaviconFetcher の timeout 延長
- 無関係リファクタ、Linear コメント（ユーザー明示がない限り）
- 既に `manualSources` にあるコードの URL 変更（明示指示がない限り）。ただし「この CA から GET できない公式 URL」は下記 TLS 節
- `company_icons` の SQL upsert で ingest を迂回する
- Icon Clerk へのハンドオフ
- Wayback / アーカイブ URL をマップに書く
- コードの発明。実在する証券コードだけ

## 権限（visual GO / merge / WRITE）

役割は混ぜない。個人名は書かない。visual GO を出す人は **ユーザー**。

| 行為 | 誰 |
| --- | --- |
| visual GO | **ユーザー**。差し替え / Before-After に必須。欠測の新規ピンは不要 |
| merge | 通常は **Maintainer risk GO** のあと、CA が merge してよい |
| WRITE | マージ後、CA が本 skill の ingest 節に従う |

### 週次 icons Automation の狭い例外

icons weekly 専用。次の **5 条件がすべて揃ったときだけ**、Automations は GrokBot 部屋ターンを待たずに CA を起動して merge+WRITE してよい。

1. **company-icons skill 範囲だけ。** 変更は `manualSources` マップ、スキップ台帳、この skill、それらへの docs 参照に限る。契約 / MCP / REST / HAPIS / Neon schema は触らない。`icons-vN` バンプなし。
2. **差し替えは記録済み visual GO のある code だけ。** 欠測ピンは GO なしで可。差し替えと欠測を同じ Ready PR に混ぜない。
3. **tip の CI が緑。**
4. **CA が tip で次の 3 フラグを自己確認し、いずれも該当しない。** `issuer contains` / `new .all()` / `Blocked-by` ignore。
5. **マージ後 WRITE** は本 skill の ingest 節。完了後、Blue Ticker 部屋へ短い FYI を出す。

1つでも欠ける、または例外の外は **Maintainer risk GO → そのあと CA が merge**。WRITE はどちらもマージ後に ingest 節へ。

## データ源

- Neon は本番（WRITE と同系統）を直接読む。RO ブランチは使わない
- 候補: listed × `company_icons` 欠行、極小オブジェクト、低解像度、横長で正方形化すると中身が小さいもの、ingest 失敗ログ
- 売上上位キャップや「1回20社」上限は設けない（PR が巨大なら分割してよい）
- main の `manualSources` キーとスキップ台帳を先に読み、重複させない

## 候補

次のいずれかに当たる会社だけ:

1. `company_icons` に行が無い
2. 行はあるが iOS で使えない／差し替え候補
3. ブランドが違う（グローバル vs 日本向け、子会社 vs 上場会社本体）

失敗パターンの例: 紙面のみ / URL 無し → 公式 HP（6150, 7888）。frameset → 公式 HP（9267。TLS 不能な直 logo は `homepageOrigin`）。Pronexus → `pronexusDisclosureHomepages`（7893 除外）。英数字コードは有報120があれば `--codes` 可（581A）。持株 16×16 → グループ大きい apple-touch。極小 1bit → 同ページ 180–192px PNG。白地消滅 → コントラストのある大きい PNG。公式パス 404/410/403 → 別の公式パス。公式無し・外部のみ → R2 → CDN。安定取得不能 → 台帳。

対象外: 台帳済み、自動 pipeline で十分、既にマップにあるコード（変更指示なし、かつこの CA から GET できる）。

## 差し替え — ユーザー visual GO 必須

既存行があっても候補にする:

1. 解像度が低い（目安: 辺がおおむね 128px 未満、または iOS 一覧でガビガビ）
2. iOS で視認性が低い（白地消滅、1bit ICO、Pronexus / WP 既定、コントラスト不足）
3. 横長／縦長で正方形に落とすとマークが小さい（目安: 有効マークがキャンバスの半分未満）

**欠測の新規ピン**は GO なしで Ready PR まで進めてよい。

**差し替え**は必須:

1. 候補ごとに Before（現行）/ After（提案）を並べる
2. ユーザーの明示 visual GO がある銘柄だけマップ／R2／PR へ
3. GO なし・却下・無回答はマップに入れない。台帳に `awaiting_go` / `rejected`
4. 差し替えを未 GO のまま Ready PR に混ぜない。欠測だけ先に出すなら PR を分ける

無理に引き伸ばさない。ユーザー添付の高解像ロゴやワンオフ白地パッドは **CDN マップ**（公式の低解像 URL を残すと次の ingest が戻る）。

### OGP 横長

- 欠測で公式の正方形が無いとき、検証済み OGP（多く 1200×630）はピンしてよい（グリコ型）
- 正方形化するとワードマークだけが小さくなる OGP は不採用 → 台帳 `low_vis_no_source`
- 白地パッド 512 はユーザー指示または差し替え GO のあと。欠測ピンで勝手にやらない

## 公式 origin / 画像 URL

origin: (1) ユーザー指定のコンシューマサイト (2) 有報「公告掲載方法」が自社なら scheme+host のみ (3) Pronexus なら有報本文の公式 URL、無ければトップで社名照合 (4) 公告に URL 無しなら Web 検索と IR。Pronexus / frameset / 紙面は favicon 取得先にしない。

画像は FaviconFetcher（rel=icon 優先）と**逆順**:

1. 正方形 apple-touch（144–192px）
2. 上場会社本体の logo / corporate_mark（正方形）
3. 同ページの大きい PNG（android-chrome、192 等）
4. 検証済み OGP（上の横長ルール）
5. favicon.ico は実体が大きく読めるときだけ

**必ず実 GET**、マジックバイト。Content-Type は信用しない。WP 既定 `w-logo-*-white-bg.png` は棄てる。持株 vs 子会社は本体マーク（8377 はほくほく FG。北海道銀行禁止）。例外: 持株 16×16 のときだけグループ／証券の大きい公式画像。

### マップに書いてよい URL

この CA（同じ VM・同じ `FaviconFetcher` 条件）から **200 + 画像マジックバイト** で取れるものだけ。ピンした直後に GET できない公式 URL を Git に残さない。

| 状況 | マップ |
| --- | --- |
| 公式 origin から favicon が取れる | `.homepageOrigin`（scheme+host） |
| 公式画像の直 URL がこの CA から GET できる | `.imageURL`（その公式 URL） |
| 外部のみ、ユーザー添付、ワンオフ整形、公式がこの CA から TLS/timeout | 実体を R2 へ → `.imageURL` は CDN のみ |

Wayback は **バイト取得の代用** であってマップ値ではない。同一公式パスのアーカイブから取れたら R2 → CDN。`web.archive.org` を `manualSources` に書かない。

## R2

- キー: `company-icons/{code}.*`。秘密は既存 `BLT_R2_*`
- 無い／入らない場合は止めて報告。新しい CLI フラグや恒常スクリプトを足さない
- バイトを先に持っている（添付・Wayback・ワンオフ PNG）ときは既存 R2 経路で PUT してよい。その後 **マップを CDN にして** `blt-server ingest --stages icons --codes` で DB 行を書く
- SQL で `company_icons` を upsert しない（ingest の skip / source_url 照合から外れる）
- 同一キー上書き時は CDN `max-age=14400` に注意

## コード変更

- `Sources/BlueTicker/Analysis/CompanyIconOriginOverride.swift` の `manualSources`
- `SwiftTests/BlueTickerTests/Spec/Policy/CompanyIconOriginOverrideTests.swift`（1:1）
- `docs/icons-manual-skips.md`
- 必要なら **この SKILL**（自己修正）
- cache ラベルは ingest 側 `icons-manual`。`companyIconsCacheVersion` は触らない
- Cloud: `-Xswiftc -disable-upcoming-feature -Xswiftc MemberImportVisibility`
- `swift test --filter CompanyIconOriginOverrideTests`
- ライブ URL テストをテストコードに足さない
- 0 社なら PR なし。台帳かこの skill の自己修正に「候補なし」と理由

## 事前確認（Ready PR の前）

短い現状を出す（GO 待ちの差し替えと欠測を混ぜない）:

- 欠測ピン: code とソース種別（公式 URL / CDN）。ユーザー visual GO 不要
- 差し替え: ユーザー visual GO 済みだけ。未 GO は Before/After のみでマップに入れない
- ingest はマージ後。未マージで WRITE しない
- 差し替えと欠測を同じ Ready PR に載せない

## Ready PR

必須:

- マージ後この CA が WRITE ingest する旨（merge 可否は権限節）
- 差し替えと欠測を混ぜていないこと。差し替えは記録済みユーザー visual GO のみ
- `--codes` に **新規ピン + キャッチアップ**（マップにあるが欠行、または `icons-manual` であるべきのに古い `icons-vN`）
- ピンした code → マップ値（公式 or CDN）。外部元 URL は PR 本文にも書かない
- スキップした code と理由
- 外部／添付／TLS 回避で R2 したものはオブジェクトキー
- このランで skill を直したらその要約

Git に Linear ID（`BLT-N`）を新たに書かない。

## マージ後 WRITE ingest

接続・禁止事項は `production-ingest`。WRITE はマージ後に限り、本節に従う。merge 自体の可否は権限節（通常は Maintainer risk GO。週次 icons は 5 条件がすべて揃ったときだけ例外）。

1. CI 緑・merge を確認。作業ツリーは merge commit（main）に合わせる
2. 必要なら R2 オブジェクトの存在確認
3. Cloud フラグで release ビルド:

```bash
swift build -c release -Xswiftc -disable-upcoming-feature -Xswiftc MemberImportVisibility --product blt-server
DATABASE_URL="$BLT_NEON_WRITE_DATABASE_URL" ./.build/release/blt-server ingest --stages icons --codes <codes>
```

`<codes>` = この PR の新規ピン + キャッチアップ（マップ済み・未格納／版ずれ）。

4. 公開 CDN を確認するときは **FaviconFetcher 相当のブラウザ UA で GET**。HEAD やデフォルト UA の 403 を失敗とみなさない
5. 失敗したら止めて報告。同一 origin のリトライは 1 回まで。TCP は通るが TLS handshake がハングするホストは timeout を延ばしても直らない → CDN 化か台帳 `tls`

## スキップ台帳

`docs/icons-manual-skips.md` が会社単位の正本。Cursor Memories だけに頼らない。

各行: `code` / 理由 (`blocked` | `needs_link` | `tls` | `timeout` | `low_vis_no_source` | `awaiting_go` | `rejected` | …) / 日付 / メモ

毎ラン開始時に読み、対象から除外。新規スキップはピン PR に含める。

- 会社固有の「取れない」→ 台帳
- 手順・検証・ingest の穴 → この SKILL（次節）
- 両方に同じ物語を長文で複製しない

## 自己修正（この SKILL）

毎ランの完了条件に含める。別 skill にしない。

1. ピン／ingest／CDN／GO で、このファイルに無い判断をしたら、**再利用できる一文**を該当節へ足す
2. 日記や銘柄名の羅列は書かない。銘柄は台帳。クラス化した失敗だけ skill に残す
3. 既存の節と矛盾するなら古い方を消して一本化する
4. Automation ダッシュボードの長文は増やさない。権限・visual GO・merge 例外・「この skill を読め」だけ
5. 小さく済む訂正はピンと同じ PR。ピンが 0 社でも手順の穴があれば skill だけの Ready PR を出してよい
6. 秘密・CDN ホストの生値・外部画像 URL を skill に貼らない

## 既知の失敗（再発防止）

ランで潰した穴。新しい穴はここに足し、上の節へ折り込んだら重複を消す。

- **マップ ≠ 格納。** 公式 URL が Git にあっても `company_icons` 行が無いことがある。キャッチアップを `--codes` に入れる。GET できない公式は CDN 化するか台帳 `tls`。公式 URL を残したまま SQL upsert しない
- **TLS handshake hang。** TCP 443 成功でも ClientHello に応答しないホストがある（やまや `www.yamaya.jp`）。FaviconFetcher 8s でも openssl 15s でも同じ。グローバル timeout を伸ばさない
- **CDN 確認の UA。** カスタムドメインはデフォルト Python/curl UA の HEAD/GET が 403、ブラウザ UA の GET は 200 になりうる
- **ユーザー添付・ワンオフ 512 白地。** 公式低解像をマップに残さない。CDN のみ（7236 型）
- **Wayback。** ライブ origin が TLS 不能なときのバイト源にはしてよい。マップ禁止

## 完了条件

- [ ] 本番 DB から候補を取り、台帳と既存マップを除外済み
- [ ] 新規ピンは実 GET + マジックバイト + 視認性ゲート合格（この CA から取れる URL、または CDN）
- [ ] 差し替えは Before/After とユーザー visual GO 済み（未 GO は含めない。欠測と混ぜない）
- [ ] 外部由来は Git に外部 URL なし、R2 + CDN のみ
- [ ] テスト緑、Ready PR、事前確認を出している
- [ ] merge は権限節（Maintainer risk GO、または週次 icons の 5 条件例外）に従っている
- [ ] マージ後 WRITE ingest 完了（または 0 社で PR なし）。キャッチアップ含む
- [ ] バイナリ commit / icons-vN バンプ / Core 画像処理 / SQL upsert なし
- [ ] 手順の穴があればこの SKILL を更新している
