---
name: blue-ticker-cli-workflow
description: BLUE TICKER CLIを使って日本株の銘柄検索、財務分析、EDINET有価証券報告書抽出、セクター調査を行うときに使うワークフロースキル
---

# BLUE TICKER CLIワークフロー

BLUE TICKER CLIで日本株を調査するときの実行手順を定める。目的は、CLIの結果に基づいて銘柄・財務・有価証券報告書の情報を整理し、ユーザーが投資判断や企業調査に使える形で返すこと。

## 使う場面

- 銘柄名や証券コードから企業を探す
- 日本株の財務推移を確認する
- 有価証券報告書のMD&A、事業等のリスク、経営方針を抽出する
- 同業・同セクター銘柄を比較する
- EDINETデータや分析キャッシュの状態を確認・準備する

## 基本姿勢

- 売買推奨はしない。事実、指標、提出書類の内容を整理し、最終判断はユーザーに委ねる。
- BLUE TICKER CLIの出力を主情報源にする。数値を勝手に補完したり、CLIにない結論を断定しない。
- `ticker analyze`、`ticker filings`、`ticker filing` を使う調査では、原則としてWeb検索を使わない。ユーザーが「ニュースも検索して」「Webも見て」などと明示した場合だけ、CLI結果とは別枠で扱う。
- EDINET APIへの負荷を抑える。分析・書類抽出の前にはキャッシュ状態を確認し、必要な準備を先に済ませる。
- 出力が長い場合は、重要な数値・変化・リスク記述を要約する。必要に応じて、実行したコマンドも明記する。

## 事前確認

最初に設定を確認する。

```bash
ticker config show
```

設定が未完了なら、ユーザーに初期化を案内する。

```bash
ticker config init
```

銘柄検索だけで終わる場合を除き、調査前にキャッシュ状態を確認する。

```bash
ticker cache status
```

`next_action` が表示されたら、分析や書類抽出へ進む前にその内容を実行する。代表例:

```bash
ticker cache prepare --years 5
ticker cache catchup --years 5
```

`--years` はユーザーの希望に合わせる。指定がなければ、通常の調査は5年、財務推移をしっかり見る場合は6年を目安にする。

## 調査フロー

### 銘柄を特定する

社名、略称、証券コードから銘柄を検索する。

```bash
ticker search <社名またはコード>
ticker search <社名またはコード> --format json
```

候補が複数ある場合は、会社名・コード・市場などを示して、どれを分析するか判断できるようにする。ユーザーの意図が明らかな場合は、そのまま次へ進む。

### 財務を分析する

主要財務指標の水準値（売上・利益・BS・CF など）を年度横断で一覧する。

```bash
ticker summarize <code> --years 6
```

増減分析（前年差分解）を見る。事業利益増減・ROIC増減・ROE増減・ネットキャッシュ増減・運転資本/CCC増減の5ブロックを表示する。

```bash
ticker analyze <code> --years 6
```

半期の季節性や直近の変化を見る（`summarize`・`analyze` とも `--half` 対応。半期は前年同期差）。

```bash
ticker analyze <code> --half
```

キャッシュ済み分析ではなく再計算したい場合に使う。

```bash
ticker analyze <code> --no-cache
```

回答では、CLIの表やJSONをそのまま長く貼るより、ユーザーの問いに合わせて以下を中心に整理する。

- 売上高、営業利益、営業利益率の推移
- ROE、ROICなどの資本効率
- 営業CF、投資CF、フリーCF
- 有利子負債、投下資本、純資産などの財務構造
- 配当性向や株主還元に関わる項目
- `DocID` が出ている場合は、有報抽出に使えること

#### 体系的な分析観点

ユーザーが広く「分析して」と依頼した場合は、単発の指標ではなく以下の3系統で整理する。計算ロジックの説明に寄せすぎず、CLI出力から読める事業構造・資本構造・現金創出力をつなげて説明する。

| 観点 | 見るもの | 返し方 |
|---|---|---|
| バランスシート | 総資産、流動資産、固定資産、流動負債、固定負債、純資産、有利子負債、投下資本 | 資産規模、資本調達、財務余力、負債依存度の変化を年次推移で述べる |
| 営業利益分析 | 売上高、売上総利益または業務粗利益、営業利益、粗利率、営業利益率、営業利益前年差の分解項目 | 売上成長、採算性、販管費負担のどれが営業利益を動かしているかを整理する |
| キャッシュフロー | 営業CF、投資CF、フリーCF、営業利益との差 | 利益が現金化されているか、投資負担後に資金が残るか、継続性があるかを確認する |

バランスシートを見るときは、資産サイドと負債・純資産サイドを分けて読む。資産が増えている場合は、それが成長投資なのか運転資本の増加なのかを確認し、負債や純資産の増減と合わせて説明する。

営業利益分析では、増収・粗利率変化・販管費影響を分けて見る。営業利益率だけで結論を出さず、売上総利益または業務粗利益の変化と販管費負担を合わせて述べる。

キャッシュフローでは、営業利益、営業CF、投資CF、フリーCFを一連で見る。営業利益が伸びていても営業CFが弱い場合、または投資CFが大きくフリーCFが継続的にマイナスの場合は、有報のMD&Aで要因を確認する。

#### グラフ化する場合

ユーザーが可視化や資料化を求めた場合は、以下のグラフを基本形にする。グラフは見栄えよりも、年次推移・構成変化・前年差要因が読み取れることを優先する。**デフォルトは5期分を表示する。**

| 分析 | 推奨グラフ | 見せ方 |
|---|---|---|
| バランスシート | 年度別の左右ペア積み上げ棒グラフ | 各年度で「資産」と「負債＋純資産」を2本並べる。資産は固定資産＋流動資産、負債＋純資産は純資産＋固定負債＋流動負債で積み上げる |
| 営業利益分析 | 営業利益前年差のウォーターフォールチャート | 前期営業利益から当期営業利益までを、売上差影響、粗利率差影響、販管費影響で橋渡しする。複数年では年度ごとに前年差要因を並べる |
| キャッシュフロー | 営業CF・投資CF・FCFのオーバーラップ棒グラフ | 同一x位置に3本を重ねて描画する（積み上げではない）。営業CFは上向き（通常プラス）、投資CFは下向き（通常マイナス、プラスの場合は上向き）、FCFは細幅で最前面に重ねる |

バランスシートのグラフでは、左右の棒の合計が同じ総資産になるようにし、同じ縦軸で資産構成と調達構成を比較する。

営業利益分析のグラフでは、増益要因と減益要因を色分けし、どの要因が営業利益を押し上げたか、または押し下げたかを読みやすくする。

キャッシュフローのグラフでは、営業CFが安定しているか、投資CFの負担が大きすぎないか、FCFが継続的にプラスかを確認できるようにする。営業CFと投資CFは独立した棒として描き、FCFは細幅で重ねることで値の確認を補助する。

### 有価証券報告書を確認する

提出書類の一覧を確認する。

```bash
ticker filings <code>
ticker filings <code> --years 6
```

最新の有価証券報告書から主要セクションを抽出する。

```bash
ticker filing <code> --sections business_risks mda segments geography management_policy
```

特定の書類IDを指定する。

```bash
ticker filing <code> --doc-id <DOC_ID> --sections mda
```

抽出できるセクション:

| section | 内容 |
|---|---|
| `business_risks` | 事業等のリスク |
| `mda` | 経営者による財政状態、経営成績及びキャッシュ・フローの状況の分析 |
| `segments` | 事業別、報告セグメント別の情報 |
| `geography` | 地域別、所在地別の情報 |
| `management_policy` | 経営方針、経営環境及び対処すべき課題等 |
| `capex_overview` | 設備投資等の概要 |
| `major_facilities` | 主要な設備の状況 |
| `facility_plans` | 設備の新設、除却等の計画 |
| `research_and_development` | 研究開発活動 |

財務分析で気になった変化がある場合は、まず `mda` で会社側の増減要因を確認する。事業別の差は `segments`、地域別の差は `geography`、設備投資や研究開発の背景は `capex_overview` / `major_facilities` / `facility_plans` / `research_and_development`、リスク要因は `business_risks`、今後の対応は `management_policy` で補う。

### セクターや同業を探す

東証33業種の一覧または業種内銘柄を確認する。

```bash
ticker sector
ticker sector <業種名>
```

同業比較では、まず候補銘柄を確認し、各銘柄に同じ年数・同じ形式で `ticker analyze` を実行する。比較時は、売上成長、利益率、ROE/ROIC、キャッシュフロー、財務レバレッジなど、同じ観点で揃える。

## よく使うワークフロー

### 会社名から財務と有報を調べる

```bash
ticker config show
ticker cache status
ticker cache catchup --years 5
ticker search <社名>
ticker analyze <code> --years 6
ticker filing <code> --sections business_risks mda segments geography management_policy
```

`cache status` が準備不要を示す場合は、`cache catchup` や `cache prepare` は省略してよい。

### 証券コードが分かっている銘柄を素早く見る

```bash
ticker cache status
ticker analyze <code> --years 6
```

必要に応じて、半期分析や有報抽出を追加する。

```bash
ticker analyze <code> --half
ticker filing <code> --sections mda
```

### 複数銘柄を比較する

```bash
ticker cache status
ticker search <社名A>
ticker search <社名B>
ticker analyze <codeA> --years 6
ticker analyze <codeB> --years 6
```

比較結果は、同じ指標を横並びで説明する。数値差だけでなく、推移の方向、安定性、キャッシュフローとの整合、有報に書かれた要因を分けて述べる。

### リスクや経営課題を中心に見る

```bash
ticker filings <code> --years 3
ticker filing <code> --sections business_risks management_policy
```

回答では、リスク項目を羅列するだけでなく、事業環境、財務への影響可能性、会社の対処方針が分かるように整理する。

## キャッシュ管理

キャッシュ状態を見る。

```bash
ticker cache status
```

不足分を準備・更新する。

```bash
ticker cache prepare --years 5
ticker cache catchup --years 5
ticker cache refresh --years 5
```

不要キャッシュの削除対象を確認する（dry-run）。

```bash
ticker cache clean --dry-run
ticker cache clean --dry-run --edinet-doc-index-years 3
```

確認後に実際に削除する（`--dry-run` を外すと実行される）。

```bash
ticker cache clean
ticker cache clean --edinet-xbrl-days 30
ticker cache clean --edinet-search-days 90 --edinet-doc-index-years 3
```

主なオプション:

| オプション | 意味 |
|---|---|
| `--edinet-search-days N` | N 日より古い検索キャッシュを削除 |
| `--edinet-xbrl-days N` | N 日より古い XBRL ディレクトリを削除 |
| `--edinet-doc-index-years N` | 年次インデックスを直近 N 年分だけ残す（デフォルト: 6） |

## トラブル時

- 設定エラーやAPIキー不足の場合は、`ticker config init` または `ticker config check` を案内する。
- EDINETデータ不足やキャッシュ不足が出た場合は、`ticker cache status` の `next_action` に従う。
- CLIがエラーを返した場合は、エラー内容を要約し、次に試すコマンドを1つか2つに絞って提示する。
