// 内訳取り込み（事業別・地域別売上の正規化スナップショット）の格納用 Codable 契約。
// docs/breakdown.md参照。
//
// 内部型 BreakdownSnapshot/BreakdownRow/LLMBreakdownAudit（Analysis/BreakdownNormalizer.swift,
// Analysis/GeographyBreakdownLLMNormalizer.swift, internal）は露出させず、有報セクション取り込み の
// ExtractedBreakdown → ExtractedBreakdownPayload 写経と同じパターンで公開 Codable 型へ写す。
// Foundation のみ依存（BlueTickerCore/Models 配置。Fluent モデルは BltServerCore 側）。

import Foundation

/// company_breakdowns.axis の公開定数（BltServerCore / REST / MCP / ingest で共用）。
public let breakdownAxisBusiness = "business"
public let breakdownAxisGeography = "geography"
/// 従業員数のセグメント別内訳軸（2026-08-01追加）。決定論のみ（LLMフォールバックなし）。
public let breakdownAxisEmployees = "employees"
/// 研究開発費（全社合計）のセグメント別内訳軸（2026-08-01追加）。決定論のみ（LLMフォールバックなし）。
public let breakdownAxisResearchAndDevelopment = "research_and_development"
/// のれん（全社合計）のセグメント別内訳軸（2026-08-12追加）。決定論のみ
/// （LLMフォールバックなし）。`goodwill_and_intangibles` note_type（IFRS連結限定の種類別明細）とは別物
/// ——本軸はJ-GAAP企業がBS/注記に持つ「のれん」単一タグをセグメントdimensionで内訳化する
/// （実データ検証: オークマ・三井住友・三菱UFJ）。
public let breakdownAxisGoodwill = "goodwill"
/// 報告セグメント別ののれんの償却額（2026-08-20追加）。決定論のみ。
public let breakdownAxisGoodwillAmortization = "goodwill_amortization"
/// 報告セグメント別の持分法会計処理される投資（2026-08-20追加）。決定論のみ。
public let breakdownAxisEquityMethodInvestments = "equity_method_investments"
/// 設備投資マトリクス（資産 Instant / フロー Duration / Overview Duration）。
/// 旧 4 軸（`segment_assets` / `capital_expenditures` / `noncurrent_asset_additions` /
/// `capital_expenditures_overview`）は REST / MCP / skills から廃止。セル名としては残す。
public let breakdownAxisCapex = "capex"

/// capex 行のセルキー。Instant の連結資産内訳。
public let capexCellSegmentAssets = "segment_assets"
/// capex 行のフローセル。書類単位で `capital_expenditures` があればそれ、無ければ
/// `noncurrent_asset_additions`。レベルを混ぜず、足し算もしない。
public let capexCellFlow = "flow"
/// capex 行の Overview セル。HTML 表があるときは表が正本。HTML ラベルと XBRL member は初期は結合しない。
public let capexCellCapitalExpendituresOverview = "capital_expenditures_overview"

/// フローセルが資本的支出タグ由来。
public let capexFlowMetricCapitalExpenditures = "capital_expenditures"
/// フローセルが非流動性資産／固定資産への追加額タグ由来。
public let capexFlowMetricNoncurrentAssetAdditions = "noncurrent_asset_additions"

/// 財務諸表計上額（無 dimension の連結計上額）。他の「計」行（`subtotal`）とは別。
public let breakdownRowKindEntityTotal = "EntityTotal"

/// 内部の指標組み立てとセル名。公開軸ではない。
public let breakdownAxisSegmentAssets = capexCellSegmentAssets
public let breakdownAxisCapitalExpenditures = capexFlowMetricCapitalExpenditures
public let breakdownAxisCapitalExpendituresOverview = capexCellCapitalExpendituresOverview
public let breakdownAxisNoncurrentAssetAdditions = capexFlowMetricNoncurrentAssetAdditions

/// 旧 4 軸。REST / MCP は 404（`.absent`）。
public let retiredBreakdownAxes = [
    breakdownAxisSegmentAssets,
    breakdownAxisCapitalExpenditures,
    breakdownAxisCapitalExpendituresOverview,
    breakdownAxisNoncurrentAssetAdditions,
]

/// business / geography を除く、報告セグメント別の決定論指標軸。
public let breakdownSegmentMetricAxes = [
    breakdownAxisEmployees,
    breakdownAxisResearchAndDevelopment,
    breakdownAxisGoodwill,
    breakdownAxisGoodwillAmortization,
    breakdownAxisEquityMethodInvestments,
    breakdownAxisCapex,
]

/// `company_breakdowns.axis` として実装済みの軸か。
public func isSupportedBreakdownAxis(_ axis: String) -> Bool {
    axis == breakdownAxisBusiness || axis == breakdownAxisGeography
        || breakdownSegmentMetricAxes.contains(axis)
}

/// Neon 内訳取り込み キャッシュ（company_breakdowns.cache_version）の契約スキーマバージョン。
/// **軸別に独立**（business / geography）。片軸の決定的ロジック変更で他軸の全件再計算を起こさない。
/// blueTickerVersion 非連動。
/// 決定論・LLM とも、`needs_review` だけでは再計算せず、本バージョンのバンプ（または欠測・行削除）
/// で再計算する。clean な `segment_info_llm` がバンプを無視すると、誤った profit が再 ingest でも残る。
///
/// 形式: `breakdown-business-vN` / `breakdown-geography-vN`（旧共通 `breakdown-vN` も read 時は受理）。
/// v10: 積み上げセグメント損益表の決定論寄せ（研究開発費→profit 誤寄せを構造側で防止）。
/// v11: 単位のみ表を捨てて dedicated contextRef の period を通し、うち列を抽出時に落とす
/// （`allTablesFromHtml` / `keywordTablesFromHtml` の共有決定論経路。geography と同じ変更）。
/// v12: うち列ドロップを geography 軸＋地域親/兄弟に限定（うち輸出高等の事業指標列を残す）。
/// v13: statement sales が null のとき business 分母を収益認識の顧客契約連結→未マスク売上相当へ
/// フォールバックし、由来タグを偽の `income_statement.sales` にしない。
/// Summary が本表 `Revenue2IFRS`「収益」を sales に載せても、収益認識表の分母は顧客契約のまま
/// （`fin-v21`。金額比較では切り替えない）。
/// v14: ingest 時に jpcrp 標準 member の日本語ラベルを補完（生 `*Member` 表示の誤表示）。
/// v15: 収益分解を Jev 列選択 + 決定論 2 段（category_group / category）に切り替え。
/// 格納 JSON の意味が変わるためバンプする。Luna 経路の誤行を現行版 skip で残さない。
/// `company_breakdowns.payload` は JSONB のため DDL は無い。本番への適用はマージ後の
/// v15 再計算（別承認）で行う。
public let businessBreakdownCacheVersion = "breakdown-business-v15"
/// v11: 単位のみ表を捨てて dedicated contextRef の period を通し、うち列を抽出時に落とす。
/// v12: うち列ドロップの決定論を精緻化（1段うち豪州、地域コンテキスト、軸ゲート）。
/// v13: ingest 時に jpcrp 標準 member の日本語ラベルを補完（生 `*Member` 表示の誤表示）。
/// v11 のままでは決定論変更後も clean 行が skip される。
public let geographyBreakdownCacheVersion = "breakdown-geography-v13"
/// うち / タグ付き合計列の subtotal 化は targeted `--codes`（対象行削除）で定着。v2 は日経225全件再計算になるため上げない。
/// v2: ingest 時に jpcrp 標準 member の日本語ラベルを補完（生 `*Member` 表示の誤表示）。
public let employeesBreakdownCacheVersion = "breakdown-employees-v2"
/// 本文の当期総額、タグ付き行の不足分、研究開発費の外の金額を本文から足す処理は非破壊。
/// 既存行は行削除または `--codes` で再計算する。分母を製造費用込みの注記へ替えるのも同じ。
public let researchAndDevelopmentBreakdownCacheVersion = "breakdown-research-and-development-v2"
public let goodwillBreakdownCacheVersion = "breakdown-goodwill-v2"
/// v2: 分母を segment+reconciling に固定（表小計の閾値切替を廃止）。
/// v3: 連結の無 dimension EntityTotal があるとき分母を連結 BS 計上額に固定。差額表と segment の同額 reconciling を dedupe。
/// v4: ingest 時に jpcrp 標準 member の日本語ラベルを補完（生 `*Member` 表示の誤表示）。
public let segmentAssetsBreakdownCacheVersion = "breakdown-segment-assets-v4"
public let goodwillAmortizationBreakdownCacheVersion = "breakdown-goodwill-amortization-v3"
public let equityMethodInvestmentsBreakdownCacheVersion = "breakdown-equity-method-investments-v3"
/// 旧 4 軸の最終スタンプ。公開軸ではなくなったため上げない。配信は止める。
public let capitalExpendituresBreakdownCacheVersion = "breakdown-capital-expenditures-v3"
public let capitalExpendituresOverviewBreakdownCacheVersion = "breakdown-capital-expenditures-overview-v3"
public let noncurrentAssetAdditionsBreakdownCacheVersion = "breakdown-noncurrent-asset-additions-v3"
/// 設備投資マトリクス。破壊的な新軸のため v1 から。
public let capexBreakdownCacheVersion = "breakdown-capex-v1"

/// 軸に対応する現行 cache_version 文字列。未知の軸は business 扱い（安全側に決定的バンプ対象へ）。
public func breakdownCacheVersion(forAxis axis: String) -> String {
    switch axis {
    case breakdownAxisGeography: return geographyBreakdownCacheVersion
    case breakdownAxisEmployees: return employeesBreakdownCacheVersion
    case breakdownAxisResearchAndDevelopment: return researchAndDevelopmentBreakdownCacheVersion
    case breakdownAxisGoodwill: return goodwillBreakdownCacheVersion
    case breakdownAxisCapex: return capexBreakdownCacheVersion
    case breakdownAxisGoodwillAmortization: return goodwillAmortizationBreakdownCacheVersion
    case breakdownAxisEquityMethodInvestments: return equityMethodInvestmentsBreakdownCacheVersion
    default: return businessBreakdownCacheVersion
    }
}

/// business 軸は `BusinessBreakdownResolver` が、geography 軸は呼び出し側が
/// `GeographyBreakdownLLMNormalizer`（html_table）または xbrl_facts 経路（`BreakdownNormalizer`）で
/// 解決した経路。監査・再計算方針の判断に使う。決定論・LLM とも `cache_version` バンプで
/// 再計算する（clean な `segment_info_llm` がバンプを無視すると誤 profit が残る）。
/// `.notFound` は行を作らない方針のため、この文字列が DB に書かれることはない
/// （欠ける軸は出さない）。
public let breakdownSourceXbrlFacts = "xbrl_facts"
/// 積み上げセグメント損益表の決定論寄せ（`StackedSegmentPnLNormalizer`）。
public let breakdownSourceStackedSegmentPnL = "stacked_segment_pnl"
public let breakdownSourceRevenueRecognitionLLM = "revenue_recognition_llm"
public let breakdownSourceSegmentInfoLLM = "segment_info_llm"
/// geography 軸を `GeographyBreakdownLLMNormalizer`（html_table）経由で解決した行の source。
public let breakdownSourceGeographyLLM = "geography_llm"
/// business 軸の内訳が解決できなかった（E/F/unknown）ことを表す行の source（issue #132）。
/// `BreakdownExtractor.classifyNotApplicableReason` による決定的判定のため、xbrl_facts と同様
/// `cache_version` 世代でゲートする（`isVersionGatedBreakdownSource` 参照）。
public let breakdownSourceNotApplicable = "not_applicable"
/// 数値タグが無く、研究開発活動の本文から当期の会社全体の総額だけを採用した行。
/// Jev は文の分類だけを返し、金額はコードが円へ換算する。`cache_version` は上げない。
public let breakdownSourceResearchAndDevelopmentProse = "research_and_development_prose"
/// 数値タグも該当表も無く、設備投資等の概要本文から当期の会社全体の総額だけを採用した行。
/// Jev は文の Role だけを返し、金額はコードが円へ換算する。公開面は研究開発費本文総額と同じ。
public let breakdownSourceCapexProse = "capex_prose"
/// 本文総額の分母出所。数値 fact のタグが無いときの sentinel。
public let breakdownDenominatorTagResearchAndDevelopmentProse = "research_and_development_prose"
public let breakdownDenominatorTagCapexProse = "capex_prose"
/// セグメントへ配分できない、またはセグメント別の記載をしないため総額のみ、という開示。
/// `not_applicable_reason` にはしない。404 にすると総額が消える。
public let breakdownWarningNotAllocatableToSegments = "not_allocatable_to_segments"
/// 全社合計の数値タグがあり、タグ付き行の不足分を本文の1文から足した印。
/// `needs_review` は合計が再び揃えば外す。404 にはしない。
public let breakdownWarningResearchAndDevelopmentProseRemainder =
    "research_and_development_prose_remainder"
/// 本文が研究開発費の総額の外に置いた金額を、負の reconciling 行として足した印。
/// `needs_review` は合計が再び揃えば外す。404 にはしない。
public let breakdownWarningResearchAndDevelopmentProseExclusion =
    "research_and_development_prose_exclusion"
public let breakdownWarningCapexProseRemainder = "capex_prose_remainder"
public let breakdownWarningCapexProseExclusion = "capex_prose_exclusion"

/// business breakdown が解決できなかった理由（issue #130、E/F判定の検知結果明示化）。
/// `BreakdownExtractor.BusinessBreakdownNotApplicableReason`（internal 型）の rawValue と揃える
/// 公開文字列定数（`breakdownSource*` と同じ「internal enum ⇔ public 文字列定数」パターン）。
/// `CompanyBreakdown.notApplicableReason` に永続化され、REST/MCP の 404 応答へ反映される（issue #132）。
/// E: 報告セグメントが地域別のみで、business 軸への swap（収益認識注記等）が見つからなかった。
public let breakdownNotApplicableGeographyOnly = "geography_only"
/// F: 単一セグメントのため報告セグメント開示自体が省略されていた
/// （`DescriptionOfFactThatCompanysBusinessComprisesSingleSegment` タグで確認）。
public let breakdownNotApplicableSingleSegmentDisclosed = "single_segment_disclosed"
/// 上記いずれにも該当しない・原因未特定（要調査）。ingest 側は `needsReview=true` で保存する。
/// 決定論（`not_applicable`）なので通常巡回では再計算せず、分類ロジック改善後は
/// `cache_version` バンプ（または行削除）で再分類する。
public let breakdownNotApplicableUnknown = "unknown"
/// geography 軸: 地域注記自体が無い（`BreakdownExtractor.extractGeographyInfo` の
/// `method == "not_found"`）。正当欠測として `needsReview=false` で永続化し、無駄な再 LLM を止める
/// （business の E/F と同型の決定的 not_applicable。REST/MCP の geography 公開は別途）。
public let breakdownNotApplicableNotFound = "not_found"

/// not_applicable 行のうち、決定的判定のため `needs_review=false` にする reason か。
/// E/F（business）と geography の正当欠測（`not_found`）が該当。`unknown` は
/// `needs_review=true` で残すが、決定論のため再計算は `cache_version` バンプ（または行削除）。
/// LLM 失敗の `needs_review=true` だけが通常巡回の再処理キューに載る。
public func isDeterministicBreakdownNotApplicableReason(_ reason: String) -> Bool {
    reason == breakdownNotApplicableGeographyOnly
        || reason == breakdownNotApplicableSingleSegmentDisclosed
        || reason == breakdownNotApplicableNotFound
}

/// breakdown read（REST/MCP）が適用する最低スキーマバージョン番号（軸別 `…-vN` の N）。
/// **明示指定**。決定論・LLM とも `isServableBreakdown` でこの床を見る（パース不能な
/// cache_version は非 servable）。不変条件: 各軸の床 ≤ その軸の現行 `…-vN` の N。
public let businessBreakdownMinServableVersion = 1
public let geographyBreakdownMinServableVersion = 1
public let employeesBreakdownMinServableVersion = 1
public let researchAndDevelopmentBreakdownMinServableVersion = 1
public let goodwillBreakdownMinServableVersion = 1
public let segmentAssetsBreakdownMinServableVersion = 1
public let goodwillAmortizationBreakdownMinServableVersion = 1
public let equityMethodInvestmentsBreakdownMinServableVersion = 1
public let capitalExpendituresBreakdownMinServableVersion = 1
public let capitalExpendituresOverviewBreakdownMinServableVersion = 1
public let noncurrentAssetAdditionsBreakdownMinServableVersion = 1
public let capexBreakdownMinServableVersion = 1

/// 軸に対応する read 床。未知の軸は business 床。
public func breakdownMinServableVersion(forAxis axis: String) -> Int {
    switch axis {
    case breakdownAxisGeography: return geographyBreakdownMinServableVersion
    case breakdownAxisEmployees: return employeesBreakdownMinServableVersion
    case breakdownAxisResearchAndDevelopment: return researchAndDevelopmentBreakdownMinServableVersion
    case breakdownAxisGoodwill: return goodwillBreakdownMinServableVersion
    case breakdownAxisCapex: return capexBreakdownMinServableVersion
    case breakdownAxisGoodwillAmortization: return goodwillAmortizationBreakdownMinServableVersion
    case breakdownAxisEquityMethodInvestments: return equityMethodInvestmentsBreakdownMinServableVersion
    default: return businessBreakdownMinServableVersion
    }
}

/// `breakdown-business-vN` / `breakdown-geography-vN` / `breakdown-employees-vN` /
/// `breakdown-research-and-development-vN` / `breakdown-goodwill-vN` / 旧 `breakdown-vN` から世代番号 N を取り出す。
/// パース不能なら nil（非 servable 扱い）。
public func breakdownCacheVersionNumber(_ version: String) -> Int? {
    let prefixes = [
        "breakdown-business-v", "breakdown-geography-v", "breakdown-employees-v",
        "breakdown-research-and-development-v", "breakdown-goodwill-v",
        "breakdown-segment-assets-v",
        "breakdown-goodwill-amortization-v",
        "breakdown-equity-method-investments-v", "breakdown-capital-expenditures-v",
        "breakdown-capital-expenditures-overview-v", "breakdown-noncurrent-asset-additions-v",
        "breakdown-capex-v",
        "breakdown-v",
    ]
    for prefix in prefixes where version.hasPrefix(prefix) {
        let suffix = version.dropFirst(prefix.count)
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber), let n = Int(suffix) else { return nil }
        return n
    }
    return nil
}

/// `cache_version` 世代で再計算・read 可否を判定すべき source か。
/// 決定論（xbrl_facts / stacked_segment_pnl / not_applicable）に加え、LLM 経由
/// （segment_info_llm / revenue_recognition_llm / geography_llm）と
/// 研究開発費の本文総額（research_and_development_prose）と設備投資本文総額
/// （capex_prose）を含める。
/// clean な LLM 行がバンプを無視すると誤った profit が再 ingest でも残るため
/// （`isServableBreakdown` / 内訳取り込み ingest の staleness 判定で共用）。
/// 本文総額は `isLLMBreakdownSource` に入れない。`needs_review` だけでは再試行しない。
public func isVersionGatedBreakdownSource(_ source: String) -> Bool {
    source == breakdownSourceXbrlFacts
        || source == breakdownSourceStackedSegmentPnL
        || source == breakdownSourceNotApplicable
        || source == breakdownSourceResearchAndDevelopmentProse
        || source == breakdownSourceCapexProse
        || isLLMBreakdownSource(source)
}

/// LLM 経由の breakdown source か。version gate に加え、現行版でも `needs_review=true`
/// なら再試行する（決定論の needs_review だけでは再試行しない方針と非対称）。
public func isLLMBreakdownSource(_ source: String) -> Bool {
    source == breakdownSourceSegmentInfoLLM
        || source == breakdownSourceRevenueRecognitionLLM
        || source == breakdownSourceGeographyLLM
}

/// LLM 正規化が表の単位（百万円 / 千円）を確定できなかったときの `warnings` フラグ。
/// 千円表が 1000 倍誤って公開される実害の印。抽出側の文字列と一致させる。
public let breakdownWarningLLMUnitUnresolved = "llm_unit_unresolved"

/// 公開 REST / MCP（iOS Breakdown の backing）が当該格納行を出してよいか。
/// `needs_review` または `llm_unit_unresolved` の行は出さない（千円単位の 1000 倍誤りの stopgap。
/// fail closed）。XBRL（`xbrl_facts` / `stacked_segment_pnl`）と `not_applicable`（'none'）、
/// 研究開発費の本文総額（`research_and_development_prose`）と設備投資本文総額
/// （`capex_prose`）はフラグがあってもそのまま出す。
/// `not_allocatable_to_segments` は総額行に付く警告であり、404 にしない。
/// ただし訂正 overlay 回帰（`overlay_regression`）はこれらの行も隠す。
/// ingest / status-report の `isServableBreakdown` とは独立（格納行は消さない・書き換えない。
/// `cache_version` も上げない）。
public func isPubliclyServableBreakdown(
    source: String, needsReview: Bool, warnings: [String]
) -> Bool {
    if hasOverlayRegressionWarning(warnings) { return false }
    if source == breakdownSourceXbrlFacts
        || source == breakdownSourceStackedSegmentPnL
        || source == breakdownSourceNotApplicable
        || source == breakdownSourceResearchAndDevelopmentProse
        || source == breakdownSourceCapexProse
    {
        return true
    }
    if needsReview { return false }
    if warnings.contains(breakdownWarningLLMUnitUnresolved) { return false }
    return true
}

/// 格納行が read 可能か。version-gated な source は cache_version が当該軸の床以上のときのみ。
/// パース不能な cache_version は非 servable（誤った clean LLM 行を古い版のまま出し続けない）。
/// `axis` 省略時は business（現行 REST/MCP 公開軸）。公開面の `needs_review` /
/// `llm_unit_unresolved` 除外は `isPubliclyServableBreakdown`（この関数は ingest 床専用）。
public func isServableBreakdown(source: String, cacheVersion: String, axis: String = "business") -> Bool {
    guard isVersionGatedBreakdownSource(source) else { return true }
    guard let n = breakdownCacheVersionNumber(cacheVersion) else { return false }
    return n >= breakdownMinServableVersion(forAxis: axis)
}

/// capex 軸の指標別分母。開示が無いときは null。
public struct CapexMetricTotalsPayload: Codable, Sendable, Equatable {
    public var denominator: Double
    public var denominatorTag: String

    public init(denominator: Double, denominatorTag: String) {
        self.denominator = denominator
        self.denominatorTag = denominatorTag
    }

    func jsonObject() -> [String: Any] {
        ["denominator": denominator, "denominator_tag": denominatorTag]
    }
}

/// BreakdownRow（内部型）の公開 Codable 写経。
public struct BreakdownRowPayload: Codable, Sendable, Equatable {
    public var labelRaw: String
    // 表示用の解決済みラベル。xbrl_facts 経路は XBRL ラベルリンクベースの日本語ラベル（無ければ
    // labelRaw にフォールバック）、html_table/LLM 経路は元々開示書類のテキストのため labelRaw と同値。
    // 収益分解は DB に label を残さず、読み出し時に category_group / category から組む。
    public var label: String
    public var amount: Double
    public var profit: Double?
    public var rowKind: String
    /// notes「設備投資等の概要」の設備内容・目的。その他の軸は nil。
    public var description: String?
    /// capex 軸の名前付きセル。他軸は nil。REST では capex だけ出す。
    public var segmentAssets: Double?
    public var flow: Double?
    public var capitalExpendituresOverview: Double?
    /// 収益分解の親区分。他軸・旧行は nil。
    public var categoryGroup: String?
    /// 収益分解の明細。フラット表では nil。
    public var category: String?

    private enum CodingKeys: String, CodingKey {
        case labelRaw, label, amount, profit, rowKind, description
        case segmentAssets, flow, capitalExpendituresOverview
        case categoryGroup = "category_group"
        case category
    }

    public init(
        labelRaw: String, label: String, amount: Double, profit: Double?, rowKind: String,
        description: String? = nil, segmentAssets: Double? = nil, flow: Double? = nil,
        capitalExpendituresOverview: Double? = nil,
        categoryGroup: String? = nil, category: String? = nil
    ) {
        self.labelRaw = labelRaw
        self.label = label
        self.amount = amount
        self.profit = profit
        self.rowKind = rowKind
        self.description = description
        self.segmentAssets = segmentAssets
        self.flow = flow
        self.capitalExpendituresOverview = capitalExpendituresOverview
        self.categoryGroup = categoryGroup
        self.category = category
        if let categoryGroup {
            self.label = Self.displayLabel(categoryGroup: categoryGroup, category: category)
        }
    }

    /// 手書き実装（`StatementLine.init(from:)` と同型、`StatementContract.swift` 参照）: `label` を
    /// 非 Optional のまま `decodeIfPresent` で読み、無ければ `labelRaw` にフォールバックする。
    /// `company_breakdowns.payload` は JSON カラムで Fluent が直接デコードするため、`label` 追加前に
    /// 格納された本番行（business/geography 225社分、`label` キーが無い）は合成 `Decodable` では
    /// `keyNotFound` で読み取り自体が失敗し、REST 読み出しも ingest の既存行チェックも共倒れする
    /// （cache_version バンプで再計算される前の行が対象。Opus 監査で発見、2026-08-03）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        labelRaw = try container.decode(String.self, forKey: .labelRaw)
        categoryGroup = try container.decodeIfPresent(String.self, forKey: .categoryGroup)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        amount = try container.decodeIfPresent(Double.self, forKey: .amount) ?? 0
        profit = try container.decodeIfPresent(Double.self, forKey: .profit)
        rowKind = try container.decode(String.self, forKey: .rowKind)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        segmentAssets = try container.decodeIfPresent(Double.self, forKey: .segmentAssets)
        flow = try container.decodeIfPresent(Double.self, forKey: .flow)
        capitalExpendituresOverview = try container.decodeIfPresent(
            Double.self, forKey: .capitalExpendituresOverview)
        if let categoryGroup {
            label = try container.decodeIfPresent(String.self, forKey: .label)
                ?? Self.displayLabel(categoryGroup: categoryGroup, category: category)
        } else {
            label = try container.decodeIfPresent(String.self, forKey: .label) ?? labelRaw
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(labelRaw, forKey: .labelRaw)
        if categoryGroup == nil {
            try container.encode(label, forKey: .label)
        }
        try container.encode(amount, forKey: .amount)
        try container.encodeIfPresent(profit, forKey: .profit)
        try container.encode(rowKind, forKey: .rowKind)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(segmentAssets, forKey: .segmentAssets)
        try container.encodeIfPresent(flow, forKey: .flow)
        try container.encodeIfPresent(
            capitalExpendituresOverview, forKey: .capitalExpendituresOverview)
        try container.encodeIfPresent(categoryGroup, forKey: .categoryGroup)
        try container.encodeIfPresent(category, forKey: .category)
    }

    public static func displayLabel(categoryGroup: String, category: String?) -> String {
        guard let category, !category.isEmpty else { return categoryGroup }
        return "\(category)（\(stripOwnBrackets(categoryGroup))）"
    }

    public static func stripOwnBrackets(_ group: String) -> String {
        var s = group.trimmingCharacters(in: .whitespacesAndNewlines)
        if (s.hasPrefix("（") && s.hasSuffix("）")) || (s.hasPrefix("(") && s.hasSuffix(")")) {
            s.removeFirst()
            s.removeLast()
        }
        return s
    }
}

/// BreakdownSnapshot（内部型）の公開 Codable 写経。company_breakdowns.payload の中身。
public struct BreakdownSnapshotPayload: Codable, Sendable, Equatable {
    public var axis: String
    public var denominator: Double
    public var denominatorTag: String
    public var rows: [BreakdownRowPayload]
    public var sourceKind: String
    public var needsReview: Bool
    public var warnings: [String]
    /// capex 軸だけ。書類単位のフロー指標。無いときは nil。
    public var flowMetric: String?
    public var segmentAssets: CapexMetricTotalsPayload?
    public var flow: CapexMetricTotalsPayload?
    public var capitalExpendituresOverview: CapexMetricTotalsPayload?

    public init(
        axis: String, denominator: Double, denominatorTag: String, rows: [BreakdownRowPayload],
        sourceKind: String, needsReview: Bool, warnings: [String],
        flowMetric: String? = nil, segmentAssets: CapexMetricTotalsPayload? = nil,
        flow: CapexMetricTotalsPayload? = nil,
        capitalExpendituresOverview: CapexMetricTotalsPayload? = nil
    ) {
        self.axis = axis
        self.denominator = denominator
        self.denominatorTag = denominatorTag
        self.rows = rows
        self.sourceKind = sourceKind
        self.needsReview = needsReview
        self.warnings = warnings
        self.flowMetric = flowMetric
        self.segmentAssets = segmentAssets
        self.flow = flow
        self.capitalExpendituresOverview = capitalExpendituresOverview
    }
}

/// Jev に一度聞いた Choice。適用しなくても残す。
public struct SegmentNoteJevCallPayload: Codable, Sendable, Equatable {
    public var question: String
    public var options: [String]
    public var selected: String?
    public var probability: Double?
    public var sentences: [String]
    public var applied: Bool

    public init(
        question: String, options: [String], selected: String?, probability: Double?,
        sentences: [String], applied: Bool
    ) {
        self.question = question
        self.options = options
        self.selected = selected
        self.probability = probability
        self.sentences = sentences
        self.applied = applied
    }
}

/// セグメント注記の Jev 判断。`company_breakdowns.llm_audit` の任意フィールド。
/// 列の追加はしない（既存 JSON に無いキーは nil）。
public struct SegmentNoteJevAuditPayload: Codable, Sendable, Equatable {
    public var code: String
    public var docID: String
    public var axis: String
    public var model: String
    public var threshold: Double
    public var applied: Bool
    public var needsReview: Bool
    public var sentences: [String]
    public var calls: [SegmentNoteJevCallPayload]
    /// 製品90％を省略にしなかった理由。公開 reason ではない。無い行は nil。
    public var withheldReason: String?
    /// business を専用タグ本文で確定したとき `dedicated_single_segment_tag`。Jev 呼び出しは無い。
    /// 公開 reason ではない。無い行は nil。
    public var decisionSource: String?

    public init(
        code: String, docID: String, axis: String, model: String, threshold: Double,
        applied: Bool, needsReview: Bool, sentences: [String], calls: [SegmentNoteJevCallPayload],
        withheldReason: String? = nil, decisionSource: String? = nil
    ) {
        self.code = code
        self.docID = docID
        self.axis = axis
        self.model = model
        self.threshold = threshold
        self.applied = applied
        self.needsReview = needsReview
        self.sentences = sentences
        self.calls = calls
        self.withheldReason = withheldReason
        self.decisionSource = decisionSource
    }
}

/// LLMBreakdownAudit（内部型）の公開 Codable 写経。LLM 経由の行にのみ添える軽量な監査情報
/// （どの表・期間列・単位・利益開示有無を採用したか）。生レスポンス全文のログ化は別途未着手
/// 。`jev` はセグメント注記の判断を載せたときだけある。
public struct LLMBreakdownAuditPayload: Codable, Sendable, Equatable {
    public var sourceTableIndex: Int?
    public var periodColumn: String?
    public var unit: String
    /// 表がそもそも事業別/製品別の利益情報を含んでいたか。`profit == nil` だけでは
    /// 「未開示（確認済み）」と「見落とし」を区別できないため独立して持つ。
    public var profitDisclosed: Bool
    public var notes: String
    public var jev: SegmentNoteJevAuditPayload?

    public init(
        sourceTableIndex: Int?, periodColumn: String?, unit: String, profitDisclosed: Bool, notes: String,
        jev: SegmentNoteJevAuditPayload? = nil
    ) {
        self.sourceTableIndex = sourceTableIndex
        self.periodColumn = periodColumn
        self.unit = unit
        self.profitDisclosed = profitDisclosed
        self.notes = notes
        self.jev = jev
    }

    /// 正規化監査が無いときの Jev だけの行。
    public static func segmentNoteJev(_ jev: SegmentNoteJevAuditPayload) -> LLMBreakdownAuditPayload {
        LLMBreakdownAuditPayload(
            sourceTableIndex: nil, periodColumn: nil, unit: "", profitDisclosed: false, notes: "",
            jev: jev)
    }

    public func replacingJev(_ jev: SegmentNoteJevAuditPayload) -> LLMBreakdownAuditPayload {
        var copy = self
        copy.jev = jev
        return copy
    }

    /// ingest が証券コードを知っているので、空のときだけ埋める。
    public func stamped(code: String) -> LLMBreakdownAuditPayload {
        guard var jev, jev.code.isEmpty, !code.isEmpty else { return self }
        jev.code = code
        return replacingJev(jev)
    }
}

public extension BreakdownRowPayload {
    /// REST/MCP 応答用 JSON オブジェクト（snake_case キー）。欠損は NSNull（`FinancialsYear` の
    /// delta フィールドと同じ表現方針）。
    func jsonObject() -> [String: Any] {
        let resolvedLabel: String
        if let categoryGroup {
            resolvedLabel = Self.displayLabel(categoryGroup: categoryGroup, category: category)
        } else {
            resolvedLabel = label
        }
        var object: [String: Any] = [
            "label_raw": labelRaw,
            "label": resolvedLabel,
            "amount": amount,
            "profit": profit ?? NSNull(),
            "row_kind": rowKind,
        ]
        if let categoryGroup {
            object["category_group"] = categoryGroup
            object["category"] = category ?? NSNull()
        }
        // description は Capex Overview 等で値があるときだけ載せる（他軸に null を増やすのを避ける）。
        if let description {
            object["description"] = description
        }
        return object
    }

    /// capex 軸の行。`amount` は出さない（名前付きセルが正）。欠測セルは null。
    func capexJsonObject() -> [String: Any] {
        var object: [String: Any] = [
            "label_raw": labelRaw,
            "label": label,
            "row_kind": rowKind,
            capexCellSegmentAssets: segmentAssets ?? NSNull(),
            capexCellFlow: flow ?? NSNull(),
            capexCellCapitalExpendituresOverview: capitalExpendituresOverview ?? NSNull(),
        ]
        if let description {
            object["description"] = description
        }
        return object
    }
}

public extension BreakdownSnapshotPayload {
    /// REST/MCP 応答用 JSON オブジェクト（snake_case キー）。
    func jsonObject() -> [String: Any] {
        if axis == breakdownAxisCapex {
            return capexJsonObject()
        }
        return [
            "axis": axis,
            "denominator": denominator,
            "denominator_tag": denominatorTag,
            "rows": rows.map { $0.jsonObject() },
            "source_kind": sourceKind,
            "needs_review": needsReview,
            "warnings": warnings,
        ]
    }

    /// capex 軸の公開形。単一 `amount` / 単一 `denominator` は出さない。
    func capexJsonObject() -> [String: Any] {
        [
            "axis": axis,
            "flow_metric": flowMetric ?? NSNull(),
            capexCellSegmentAssets: segmentAssets?.jsonObject() ?? NSNull(),
            capexCellFlow: flow?.jsonObject() ?? NSNull(),
            capexCellCapitalExpendituresOverview: capitalExpendituresOverview?.jsonObject()
                ?? NSNull(),
            "rows": rows.map { $0.capexJsonObject() },
            "source_kind": sourceKind,
            "needs_review": needsReview,
            "warnings": warnings,
        ]
    }
}

public extension LLMBreakdownAuditPayload {
    /// REST/MCP 応答用 JSON オブジェクト（snake_case キー）。欠損は NSNull。
    /// `notes` は「どの表・期間列・単位・転置有無を採用したか」の自由文で、`denominator_tag`が
    /// "income_statement.sales" 以外（例: "llm_table_subtotal"）のときに実際の指標名を知る手がかりになる。
    func jsonObject() -> [String: Any] {
        var object: [String: Any] = [
            "source_table_index": sourceTableIndex ?? NSNull(),
            "period_column": periodColumn ?? NSNull(),
            "unit": unit,
            "profit_disclosed": profitDisclosed,
            "notes": notes,
        ]
        if let jev {
            object["jev"] = jev.jsonObject()
        }
        return object
    }
}

extension SegmentNoteJevAuditPayload {
    func jsonObject() -> [String: Any] {
        var object: [String: Any] = [
            "code": code,
            "doc_id": docID,
            "axis": axis,
            "model": model,
            "threshold": threshold,
            "applied": applied,
            "needs_review": needsReview,
            "sentences": sentences,
            "calls": calls.map { $0.jsonObject() },
        ]
        if let withheldReason {
            object["withheld_reason"] = withheldReason
        }
        if let decisionSource {
            object["decision_source"] = decisionSource
        }
        return object
    }
}

extension SegmentNoteJevCallPayload {
    func jsonObject() -> [String: Any] {
        [
            "question": question,
            "options": options,
            "selected": selected ?? NSNull(),
            "probability": probability ?? NSNull(),
            "sentences": sentences,
            "applied": applied,
        ]
    }
}
