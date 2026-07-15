import Foundation

// `ticker skill` が出力する CLI 利用ワークフローの本文。
// 旧 Claude Code スキル (~/.claude/skills/blue-ticker-cli-workflow/SKILL.md) から移植し、
// バイナリ同梱・Git 管理下に置くために CLI へ内包した。
// エージェント／MCP がこの出力を読み、ticker を使った調査手順の基準にする。
let skillWorkflowText = """
# BLUE TICKER CLIワークフロー

BLUE TICKER CLIで日本株を調査するときの実行手順を定める。目的は、CLIの結果に基づいて銘柄・財務・有価証券報告書の情報を整理し、ユーザーが投資判断や企業調査に使える形で返すこと。

## 使う場面

- 銘柄名や証券コードから企業を探す
- 日本株の財務推移を確認する
- 有価証券報告書のMD&A、事業等のリスク、経営方針を抽出する
- 同業・同セクター銘柄を比較する

## 基本姿勢

- 売買推奨はしない。事実、指標、提出書類の内容を整理し、最終判断はユーザーに委ねる。
- BLUE TICKER CLIの出力を主情報源にする。数値を勝手に補完したり、CLIにない結論を断定しない。
- `ticker summarize`、`ticker analyze`、`ticker filings`、`ticker filing` を使う調査では、原則としてWeb検索を使わない。ユーザーが「ニュースも検索して」「Webも見て」などと明示した場合だけ、CLI結果とは別枠で扱う。
- 出力が長い場合は、重要な数値・変化・リスク記述を要約する。必要に応じて、実行したコマンドも明記する。

## 事前確認

最初に設定を確認する。

```bash
ticker config show
```

サーバーURLが未設定、または `ticker login` が必要と表示された場合は、ユーザーに案内する。

`--years` はユーザーの希望に合わせる。指定がなければ、通常の調査は5年、財務推移をしっかり見る場合は6年を目安にする。

## 調査フロー

### 銘柄を特定する

社名、略称、証券コードから銘柄を検索する。

```bash
ticker search <社名またはコード>
ticker search <社名またはコード> --json
```

`search` は証券コードと会社名（部分一致）で照合する。業種名では絞り込めない。候補が複数ある場合は、コード・会社名・業種・市場を示して、どれを分析するか判断できるようにする。ユーザーの意図が明らかな場合は、そのまま次へ進む。

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

回答では、CLIの表やJSONをそのまま長く貼るより、ユーザーの問いに合わせて以下を中心に整理する。

- 売上高、営業利益、営業利益率の推移
- ROE、ROICなどの資本効率
- 営業CF、投資CF、フリーCF
- 有利子負債、投下資本、純資産などの財務構造
- 配当性向や株主還元に関わる項目
- `DocID` が出ている場合は、有報抽出に使えること

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

東証33業種の一覧と各業種の銘柄数を確認する。`sector` は一覧表示のみで、業種を指定して銘柄を絞り込む引数は持たない。

```bash
ticker sector
ticker sector --json
```

同業比較では、比較対象の銘柄名をユーザーと特定したうえで、各銘柄を `ticker search` で引き当て、同じ年数・同じ形式で `ticker analyze` を実行する。比較時は、売上成長、利益率、ROE/ROIC、キャッシュフロー、財務レバレッジなど、同じ観点で揃える。

## よく使うワークフロー

### 会社名から財務と有報を調べる

```bash
ticker search <社名>
ticker analyze <code> --years 6
ticker filing <code> --sections business_risks mda segments geography management_policy
```

### 証券コードが分かっている銘柄を素早く見る

```bash
ticker analyze <code> --years 6
```

必要に応じて、半期分析や有報抽出を追加する。

```bash
ticker analyze <code> --half
ticker filing <code> --sections mda
```

### 複数銘柄を比較する

```bash
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

## トラブル時

- 接続エラーの場合は、`ticker config show` で `サーバーURL` と `SSO ログイン` の状態を確認し、未ログインなら `ticker login` を案内する。
- 銘柄が見つからない・データ未格納のエラーが出た場合は、証券コードや検索語を再確認し、それでも解決しない場合はその旨をユーザーに伝える。
- CLIがエラーを返した場合は、エラー内容を要約し、次に試すコマンドを1つか2つに絞って提示する。
"""
