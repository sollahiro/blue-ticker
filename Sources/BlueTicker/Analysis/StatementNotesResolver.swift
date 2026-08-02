// 財務諸表注記取り込み: Stage 4/6/7 が対象外の財務諸表注記（Statement Notes）を note_type ごとに解決する。
// note_type ごとの決定論ロジックをこの1ファイルに集約する（11種×別ファイルは過剰。
// plan「Resolver: StatementNotesResolver.swift」参照）。
//
// 政策保有株式（policy_holding_securities）は当初計画で「LLM必須」と見込んでいたが、実データ検証
// （2026-08-02、20社サンプル）の結果、EDINET標準タクソノミ（jpcrp_cor）で銘柄ごとに完全に構造化
// タグされていると判明したため決定論で実装する（下記 resolvePolicyHoldingSecurities 参照）。

import Foundation
import SwiftSoup
#if canImport(FoundationXML)
import FoundationXML
#endif

enum StatementNotesResolver {

    /// 販管費の内訳（`sga_breakdown` note_type）。
    ///
    /// 実データ検証（2026-08-01、S100TSIJ/S100R0D0/S100VXJA/S100R09Z 等）: 「販売費及び一般管理費の
    /// 主要な内訳」注記は role=`NotesStatementOfIncome` 配下に格納され、内訳科目タグは
    /// `EmployeesSalariesAndAllowancesSGA` のように会社ごとに異なる拡張タグ名だが、末尾は必ず
    /// `SGA` で統一されている（EDINET拡張タクソノミの命名規約）。固定タグリストを持たず、
    /// 「role=NotesStatementOfIncome かつ tag が SGA で終わる」という構造的パターンだけで
    /// 会社非依存に抽出する。
    ///
    /// 開示コンテキストは常に非連結（`NonConsolidatedMember`）だった（サンプル全社）。これは
    /// 連結側の会計基準（IFRS/J-GAAP）とは無関係（実データ検証: IFRS連結のトヨタ自動車
    /// S100VWVY もこの注記を持つ）。単体決算の損益計算書関係注記として開示されるかどうかは
    /// 会社ごとの開示判断であり、キャッシュ済み144件中99件で解決・45件が正当な
    /// `.notApplicable(not_found)`（該当 role 自体が無い）だった。したがって本 note_type の値は
    /// 単体（非連結）ベースであり、Stage 4 の連結 SG&A 合計とは母集団が異なる（合算しても一致しない）。
    static func resolveSGABreakdown(xbrlDir: URL) -> StatementNoteResolveResult {
        let facts = XBRLUtils.collectAllNumericFacts(in: xbrlDir)

        var labelsByTag: [String: String?] = [:]
        for (tag, ctxMap) in facts where tag.hasSuffix("SGA") {
            for fact in ctxMap.values {
                let roles = fact.roles ?? fact.role.map { [$0] } ?? []
                if roles.contains(where: { XBRLUtils.sectionNameFromRole($0) == "NotesStatementOfIncome" }) {
                    labelsByTag[tag] = fact.label
                    break
                }
            }
        }
        guard !labelsByTag.isEmpty else {
            return .notApplicable(reason: statementNoteNotApplicableNotFound)
        }

        // 現在値の解決は非連結 Duration の正規化ロジックを再利用する（実データ検証どおり単体
        // コンテキストのみで開示されるため。自前のコンテキスト文字列パースはしない）。
        let allTagElements = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let ncDurationFS = fieldSetFromNonConsolidatedDuration(allTagElements)

        var items: [StatementLineItem] = []
        for (tag, label) in labelsByTag {
            guard let value = ncDurationFS[tag]?.current else { continue }
            items.append(StatementLineItem(tag: tag, label: label, value: value, unit: "yen", order: nil))
        }
        guard !items.isEmpty else {
            return .notApplicable(reason: statementNoteNotApplicableNotFound)
        }
        items.sort { $0.tag < $1.tag }

        let hash = items.map { "\($0.tag)=\($0.value)" }.joined(separator: ",")
        return .resolved(
            payload: StatementNotePayload(items: items), source: statementNoteSourceXbrlFacts,
            contentHash: hash)
    }

    /// IBD計算用CF補足（`borrowings_schedule_cf_supplement` note_type）。
    ///
    /// 連結附属明細表「借入金等明細表」の構成科目（短期借入金・社債・長期借入金・リース負債等）を
    /// 表として公開する。解析ロジックは `BorrowingsSchedule.extract`（`IBDExtractor` が XBRL タグ
    /// 未整備企業向けフォールバックとして既に使っている本番コード）をそのまま再利用し、
    /// 自前で明細表を再パースしない（重複ロジック回避）。合計行は `isTotal: true` で区別する。
    static func resolveBorrowingsScheduleCFSupplement(
        xbrlDir: URL, accountingStandard: String
    ) -> StatementNoteResolveResult {
        guard
            let result = BorrowingsSchedule.extract(
                xbrlDir: xbrlDir, accountingStandard: accountingStandard)
        else {
            return .notApplicable(reason: statementNoteNotApplicableNotFound)
        }

        var items: [StatementLineItem] = result.components.compactMap { component in
            guard let value = component.current else { return nil }
            return StatementLineItem(
                tag: component.label, label: component.label, value: value, unit: "yen", order: nil)
        }
        if let total = result.total {
            items.append(
                StatementLineItem(
                    tag: "合計", label: "合計", value: total, unit: "yen", order: nil, isTotal: true))
        }
        guard !items.isEmpty else {
            return .notApplicable(reason: statementNoteNotApplicableNotFound)
        }

        let hash = items.map { "\($0.tag)=\($0.value)" }.joined(separator: ",")
        return .resolved(
            payload: StatementNotePayload(items: items), source: statementNoteSourceXbrlFacts,
            contentHash: hash)
    }

    /// 有形固定資産の種類別明細（`property_plant_equipment_schedule` note_type）。
    ///
    /// 実データ検証（2026-08-01）: IFRS連結企業（京セラ S100TSIJ・トヨタ S100VWVY 等）は
    /// role=`NotesPropertyPlantAndEquipmentConsolidatedFinancialStatementsIFRS` 配下に
    /// 「`{資産区分}IFRS`」（正味帳簿価額）・「`{資産区分}AcquisitionCostIFRS`」（取得原価）・
    /// 「`{資産区分}AccumulatedDepreciationAndImpairmentLossesIFRS`」（減価償却・減損累計額）の
    /// 3点セットを資産区分ごとに開示する（`LandIFRS`/`LandAcquisitionCostIFRS`/...等）。本 note_type
    /// では正味帳簿価額タグのみを種類別に抽出する（取得原価・累計償却は含めない）。
    ///
    /// J-GAAP単体の「有形固定資産等明細表」（`AnnexedDetailedScheduleOfPropertyPlantAndEquipmentEtcTextBlock`、
    /// HTMLテーブル）は今回未対応（Task 7、実データ検証で列数が多く「差引当期末残高」列の位置を
    /// ヘッダー文言から検出する処理が別途必要と判明したため、次のタスクへ持ち越し。IFRS企業の
    /// カバレッジのみで先行実装する）。したがって本 note_type は現時点で IFRS 連結企業限定。
    static func resolvePropertyPlantEquipmentSchedule(xbrlDir: URL) -> StatementNoteResolveResult {
        resolveIFRSCategorySchedule(
            xbrlDir: xbrlDir,
            roleName: "NotesPropertyPlantAndEquipmentConsolidatedFinancialStatementsIFRS")
    }

    /// のれん及びその他無形資産の種類別明細（`goodwill_and_intangibles` note_type）。
    ///
    /// `resolvePropertyPlantEquipmentSchedule` と同型のIFRS注記パターン（実データ検証:
    /// role=`NotesGoodwillAndIntangibleAssetsConsolidatedFinancialStatementsIFRS` 配下に
    /// `GoodwillIFRS`/`SoftwareIFRS`/`CustomerRelationshipsIFRS` 等の正味帳簿価額タグ＋
    /// 取得原価・累計償却の3点セット）。J-GAAP単体はこの注記に対応する法定附属明細表が
    /// そもそも存在しない（有形固定資産等明細表と異なり、のれん明細表は財務諸表等規則の
    /// 附属明細表一覧に含まれない）。したがって J-GAAP 単体開示のみの企業は正当に
    /// `.notApplicable(not_found)` になる（IFRS企業限定という制約は PPE 明細と異なり
    /// 開示制度自体の差であり、実装上の未対応ではない）。
    static func resolveGoodwillAndIntangibles(xbrlDir: URL) -> StatementNoteResolveResult {
        resolveIFRSCategorySchedule(
            xbrlDir: xbrlDir,
            roleName: "NotesGoodwillAndIntangibleAssetsConsolidatedFinancialStatementsIFRS")
    }

    /// IFRS注記に共通の「資産区分ごとに正味帳簿価額・取得原価・累計償却/減損の3タグが揃う」構造から
    /// 正味帳簿価額タグだけを抽出する共通処理（PPE・のれん双方で使う）。
    private static let ifrsComponentSuffixes = [
        "AcquisitionCostIFRS",
        "AccumulatedDepreciationAndImpairmentLossesIFRS",
        "AccumulatedAmortizationAndImpairmentLossesIFRS",
        "AccumulatedImpairmentLossesIFRS",
    ]

    private static func resolveIFRSCategorySchedule(
        xbrlDir: URL, roleName: String
    ) -> StatementNoteResolveResult {
        let facts = XBRLUtils.collectAllNumericFacts(in: xbrlDir)

        var labelsByTag: [String: String?] = [:]
        for (tag, ctxMap) in facts
        where tag.hasSuffix("IFRS") && !ifrsComponentSuffixes.contains(where: { tag.hasSuffix($0) }) {
            for fact in ctxMap.values {
                let roles = fact.roles ?? fact.role.map { [$0] } ?? []
                if roles.contains(where: { XBRLUtils.sectionNameFromRole($0) == roleName }) {
                    labelsByTag[tag] = fact.label
                    break
                }
            }
        }
        guard !labelsByTag.isEmpty else {
            return .notApplicable(reason: statementNoteNotApplicableNotFound)
        }

        // 正味帳簿価額は連結 Instant コンテキスト（実データ検証: CurrentYearInstant、member接尾辞なし）。
        let allTagElements = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let instantFS = fieldSetFromInstant(allTagElements)

        var items: [StatementLineItem] = []
        for (tag, label) in labelsByTag {
            guard let value = instantFS[tag]?.current else { continue }
            items.append(StatementLineItem(tag: tag, label: label, value: value, unit: "yen", order: nil))
        }
        guard !items.isEmpty else {
            return .notApplicable(reason: statementNoteNotApplicableNotFound)
        }
        items.sort { $0.tag < $1.tag }

        let hash = items.map { "\($0.tag)=\($0.value)" }.joined(separator: ",")
        return .resolved(
            payload: StatementNotePayload(items: items), source: statementNoteSourceXbrlFacts,
            contentHash: hash)
    }

    /// 政策保有株式（`policy_holding_securities` note_type）。
    ///
    /// 実データ検証（2026-08-02、20社ランダムサンプル）: 「特定投資株式」（純投資目的以外で保有する
    /// 上場株式のうち、金額の大きいものから個別開示される銘柄）は EDINET 標準タクソノミ（jpcrp_cor）で
    /// 銘柄ごとに完全に構造化タグされている。`contextRef` が `CurrentYearInstant_Row{N}Member` という
    /// 規則的な連番になっており、銘柄名・保有株式数・貸借対照表計上額・保有目的が行番号で紐付く
    /// （法定開示様式であり、geography/business breakdown 注記のような会社ごとに自由な表ではない）。
    ///
    /// 提出会社自身が保有する場合は `...ReportingCompany` サフィックス、純粋持株会社で子会社が
    /// 保有する場合は `...LargestHoldingCompany`/`...SecondLargestHoldingCompany`
    /// （最大保有会社／第二位保有会社）サフィックスになる。3変体は排他的に出現し contextRef の
    /// Row番号は変体ごとに独立した連番のため、変体をまたいで突き合わせてはならない
    /// （変体ごとに個別に行を組み立てて連結する）。
    ///
    /// 20社サンプルで 19/20 が本ロジックで解決（1社は個別銘柄非開示・金額集計のみのため
    /// 正当な `.notApplicable(not_found)`）。したがって LLM 正規化は不要と判断した。
    ///
    /// **重要**: 保有株式数・貸借対照表計上額の実値は `collectAllNumericElements(nilAsZero: false)`
    /// で読む（`collectAllNumericFacts` の既定 `nilAsZero: true` は使わない）。当年に全数売却済みの
    /// 銘柄は `xsi:nil="true"` の当年 fact のみ存在し、`nilAsZero: true` だとこれが `0` に化けて
    /// 「保有株式数0・計上額0円」という実態と異なる値を返してしまう（実データ検証: S100QXRZ で
    /// 41銘柄中14銘柄がこのケース）。`nil`（未開示）のまま返すのが正しい。本ファイルの他の
    /// resolver（`resolveSGABreakdown`/`resolveIFRSCategorySchedule`）も同じ理由で値取得には
    /// `nilAsZero: false` を使っており、本関数もそれに揃える。
    static func resolvePolicyHoldingSecurities(xbrlDir: URL) -> StatementNoteResolveResult {
        let numericElements = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let textFacts = collectPolicyHoldingTextFacts(in: xbrlDir)

        var securities: [PolicyHoldingSecurityPayload] = []
        for variant in policyHoldingHolderVariants {
            let nameTag = policyHoldingNamePrefix + variant
            guard let names = textFacts[nameTag], !names.isEmpty else { continue }

            let sharesTag = policyHoldingSharesPrefix + variant
            let bookValueTag = policyHoldingBookValuePrefix + variant
            let sharesByCtx = numericElements[sharesTag] ?? [:]
            let bookValueByCtx = numericElements[bookValueTag] ?? [:]
            let purposeTag = textFacts.keys.first { isPolicyHoldingPurposeTag($0, variant: variant) }
            let purposeByCtx = purposeTag.flatMap { textFacts[$0] } ?? [:]

            var variantRows: [(row: Int, security: PolicyHoldingSecurityPayload)] = []
            for (ctx, name) in names {
                guard let row = policyHoldingCurrentYearRowNumber(ctx) else { continue }
                variantRows.append((
                    row,
                    PolicyHoldingSecurityPayload(
                        issuerName: name,
                        numberOfShares: sharesByCtx[ctx],
                        carryingAmount: bookValueByCtx[ctx],
                        purpose: purposeByCtx[ctx])
                ))
            }
            securities.append(contentsOf: variantRows.sorted { $0.row < $1.row }.map(\.security))
        }

        guard !securities.isEmpty else {
            return .notApplicable(reason: statementNoteNotApplicableNotFound)
        }

        let hash = securities.map { "\($0.issuerName)=\($0.numberOfShares ?? -1),\($0.carryingAmount ?? -1)" }
            .joined(separator: ";")
        return .resolved(
            payload: StatementNotePayload(securities: securities), source: statementNoteSourceXbrlFacts,
            contentHash: hash)
    }

    /// `ReportingCompany`/`LargestHoldingCompany`/`SecondLargestHoldingCompany` の順（実データ確認済み、
    /// 3変体は排他的に出現するため順序自体に意味はないが、出力順を安定させるため固定する）。
    private static let policyHoldingHolderVariants = [
        "ReportingCompany", "LargestHoldingCompany", "SecondLargestHoldingCompany",
    ]

    private static let policyHoldingNamePrefix =
        "NameOfSecuritiesDetailsOfSpecifiedInvestmentEquitySecuritiesHeldForPurposesOtherThanPureInvestment"
    private static let policyHoldingSharesPrefix =
        "NumberOfSharesHeldDetailsOfSpecifiedInvestmentEquitySecuritiesHeldForPurposesOtherThanPureInvestment"
    private static let policyHoldingBookValuePrefix =
        "BookValueDetailsOfSpecifiedInvestmentEquitySecuritiesHeldForPurposesOtherThanPureInvestment"

    /// 保有目的タグは実データ上、`ReportingCompany` 変体と `Largest`/`SecondLargest` 変体で中間の
    /// 語句が異なる（後者は「事業上の関係の概要」が挿入される）ため、固定タグ名ではなく
    /// プレフィックス＋サフィックスで判定する。`LargestHoldingCompany` は `SecondLargestHoldingCompany`
    /// の末尾一致でもあるため、`variant` が前者のときは後者を明示的に除外する。
    private static func isPolicyHoldingPurposeTag(_ tag: String, variant: String) -> Bool {
        guard tag.hasPrefix("PurposeOfShareholding"),
              tag.contains("DetailsOfSpecifiedInvestmentSharesHeldForPurposesOtherThanPureInvestment"),
              tag.hasSuffix(variant)
        else { return false }
        if variant == "LargestHoldingCompany" && tag.hasSuffix("SecondLargestHoldingCompany") { return false }
        return true
    }

    private static let policyHoldingRowContextRegex = try? NSRegularExpression(
        pattern: "^CurrentYearInstant_Row([0-9]+)Member$")

    /// `CurrentYearInstant_Row{N}Member` 形式の contextRef から行番号を取り出す。前期（Prior1YearInstant）
    /// の行や他の contextRef パターンは対象外（nil）。
    private static func policyHoldingCurrentYearRowNumber(_ contextRef: String) -> Int? {
        guard let regex = policyHoldingRowContextRegex else { return nil }
        let range = NSRange(contextRef.startIndex..<contextRef.endIndex, in: contextRef)
        guard let match = regex.firstMatch(in: contextRef, range: range),
              let numRange = Range(match.range(at: 1), in: contextRef)
        else { return nil }
        return Int(contextRef[numRange])
    }

    /// 政策保有株式の銘柄名・保有目的テキストを {tag: {contextRef: text}} で集める。
    private static func collectPolicyHoldingTextFacts(in xbrlDir: URL) -> [String: [String: String]] {
        collectTextFacts(in: xbrlDir) {
            $0.hasPrefix("NameOfSecuritiesDetailsOfSpecifiedInvestment")
                || $0.hasPrefix("PurposeOfShareholding")
        }
    }

    /// 配当の状況（`dividends` note_type）。
    ///
    /// 実データ検証（2026-08-02、レーザーテック S100JRT9）: role=`DividendPolicy` 配下に
    /// `DateOfResolutionDividendsOfSurplus`(決議年月日・テキスト)・`ResolutionDividendsOfSurplus`
    /// (決議機関・テキスト)・`DividendPerShareDividendsOfSurplus`(1株配当額)・
    /// `TotalAmountOfDividendsDividendsOfSurplus`(配当金総額) の4タグが `FilingDateInstant_Row{N}Member`
    /// で決議（中間・期末等）ごとに行番号付けされている（政策保有株式の `CurrentYearInstant_Row{N}Member`
    /// とプレフィックスが異なる点に注意）。中間/期末の区分ラベルは実データから直接読み取れないため
    /// 持たない（`DividendEventPayload` のコメント参照）。
    static func resolveDividends(xbrlDir: URL) -> StatementNoteResolveResult {
        let numericElements = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let textFacts = collectTextFacts(in: xbrlDir) {
            $0 == "DateOfResolutionDividendsOfSurplus" || $0 == "ResolutionDividendsOfSurplus"
        }

        let dateByCtx = textFacts["DateOfResolutionDividendsOfSurplus"] ?? [:]
        let bodyByCtx = textFacts["ResolutionDividendsOfSurplus"] ?? [:]
        let perShareByCtx = numericElements["DividendPerShareDividendsOfSurplus"] ?? [:]
        let totalByCtx = numericElements["TotalAmountOfDividendsDividendsOfSurplus"] ?? [:]

        var rowContexts = Set(dateByCtx.keys)
        rowContexts.formUnion(bodyByCtx.keys)
        rowContexts.formUnion(perShareByCtx.keys)
        rowContexts.formUnion(totalByCtx.keys)

        var rows: [(row: Int, event: DividendEventPayload)] = []
        for ctx in rowContexts {
            guard let row = dividendRowNumber(ctx) else { continue }
            rows.append((
                row,
                DividendEventPayload(
                    resolutionDate: dateByCtx[ctx], resolutionBody: bodyByCtx[ctx],
                    dividendPerShare: perShareByCtx[ctx], totalAmount: totalByCtx[ctx])
            ))
        }
        guard !rows.isEmpty else {
            return .notApplicable(reason: statementNoteNotApplicableNotFound)
        }
        let events = rows.sorted { $0.row < $1.row }.map(\.event)

        let hash = events.map { "\($0.resolutionDate ?? ""):\($0.dividendPerShare ?? -1):\($0.totalAmount ?? -1)" }
            .joined(separator: ";")
        return .resolved(
            payload: StatementNotePayload(dividendEvents: events), source: statementNoteSourceXbrlFacts,
            contentHash: hash)
    }

    /// 1株当たり情報（`per_share_information` note_type）。
    ///
    /// 実データ検証（2026-08-02）: EPS・潜在株式調整後EPS・BPSはいずれも「業績等の概要
    /// （SummaryOfBusinessResults）」の離散数値タグから決定論で取得できる（注記本体のHTML
    /// テーブルはパースしない）。EPSは既存 `PerShareExtractor.extract`（`Xbrl.basicEpsTags`）を
    /// そのまま再利用する（重複ロジック回避）。BPSはJGAAPが`NetAssetsPerShareSummaryOfBusinessResults`、
    /// IFRSは`EquityToAssetRatioIFRSSummaryOfBusinessResults`（タグ名誤り、`unitRef=JPYPerShares`で
    /// 判別、日立 S100QZT0「１株当たり親会社株主持分」ラベルと完全一致を確認済み）。
    /// カバレッジ実測（キャッシュ144件）: EPS 144/144、BPS 142/144、潜在株式調整後EPS 65/144
    /// （IFRS企業の一部は希薄化効果のある証券が無く注記自体に希薄化後EPSを持たない）。
    ///
    /// 前期比較値は持たない。`company_statement_notes` はdocID（＝1事業年度）単位でingestされる
    /// ため、前期値は前期docIDの`value`で取得できる（Stage4 `years[]` と同型、ユーザー判断
    /// 2026-08-02）。
    static func resolvePerShareInformation(xbrlDir: URL) -> StatementNoteResolveResult {
        let allTagElements = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let durationFS = fieldSetFromDuration(allTagElements)
        let instantFS = fieldSetFromInstant(allTagElements)

        var items: [StatementLineItem] = []

        if let eps = PerShareExtractor.extract(durationFS: durationFS, tagElements: allTagElements).eps {
            items.append(
                StatementLineItem(tag: "eps", label: "１株当たり当期純利益", value: eps, unit: "yen_per_share", order: nil))
        }
        if let diluted = resolveItem(durationFS, tags: Xbrl.dilutedEpsTags).current {
            items.append(
                StatementLineItem(
                    tag: "diluted_eps", label: "潜在株式調整後１株当たり当期純利益", value: diluted,
                    unit: "yen_per_share", order: nil))
        }
        if let bps = resolveItem(instantFS, tags: Xbrl.netAssetsPerShareTags).current {
            items.append(
                StatementLineItem(tag: "bps", label: "１株当たり純資産額", value: bps, unit: "yen_per_share", order: nil))
        } else if let bps = resolveEquityPerShareIFRSMislabeled(xbrlDir: xbrlDir) {
            items.append(
                StatementLineItem(
                    tag: "bps", label: "１株当たり親会社株主持分", value: bps, unit: "yen_per_share", order: nil))
        }

        guard !items.isEmpty else {
            return .notApplicable(reason: statementNoteNotApplicableNotFound)
        }
        let hash = items.sorted { $0.tag < $1.tag }.map { "\($0.tag)=\($0.value)" }.joined(separator: ",")
        return .resolved(
            payload: StatementNotePayload(items: items), source: statementNoteSourceXbrlFacts,
            contentHash: hash)
    }

    /// IFRS企業の「1株当たり親会社株主持分」相当値。EDINETタクソノミ上は
    /// `EquityToAssetRatioIFRSSummaryOfBusinessResults`（自己資本比率）という誤った名前だが、
    /// `unitRef=JPYPerShares`（円/株）の場合のみ実体は円建て金額（実データ確認済み）。
    /// US-GAAP企業では同名タグが `unitRef=pure`（真の比率、0〜1）で使われるため、unitRef を
    /// 見ずにタグ名だけで判定してはならない（実データ確認済み: 小松製作所 S100QYNI）。
    private static func resolveEquityPerShareIFRSMislabeled(xbrlDir: URL) -> Double? {
        let facts = XBRLUtils.collectAllNumericFacts(in: xbrlDir)
        guard let fact = facts["EquityToAssetRatioIFRSSummaryOfBusinessResults"]?["CurrentYearInstant"],
              fact.unitRef == "JPYPerShares"
        else { return nil }
        return fact.value
    }

    /// 設備投資等の概要（`capital_expenditures_overview` note_type）。
    ///
    /// 実データ検証（2026-08-02）: 単一セグメント企業（レーザーテック S100JRT9）は注記が自由記述の
    /// 文章のみで、総額タグ（`Xbrl.capexOverviewTags`）1本が唯一の数値源。複数セグメント企業
    /// （日立 S100QZT0）は注記HTML内にセグメント名・設備投資金額・前年度比・主な内容/目的の4列
    /// テーブルを持つ。セグメント別の設備投資金額自体は `CapitalExpendituresOverviewOfCapitalExpendituresEtc`
    /// タグにセグメントmember付きcontextでも構造化されているが、前年度比・主な内容/目的はタグ化
    /// されておらずHTML表にしか無いため、表がある場合は表を正として解析する（構造化タグと
    /// 二重に読まず、表の抽出結果に一本化する）。表が無ければ単一値へフォールバックする。
    static func resolveCapitalExpendituresOverview(xbrlDir: URL) -> StatementNoteResolveResult {
        if let segments = parseCapexTable(xbrlDir: xbrlDir), !segments.isEmpty {
            let hash = segments.map { "\($0.segmentName ?? "-")=\($0.investmentAmount ?? -1)" }
                .joined(separator: ";")
            return .resolved(
                payload: StatementNotePayload(capexSegments: segments),
                source: statementNoteSourceXbrlFacts, contentHash: hash)
        }

        let allTagElements = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let durationFS = fieldSetFromDuration(allTagElements)
        guard let total = resolveItem(durationFS, tags: Xbrl.capexOverviewTags).current else {
            return .notApplicable(reason: statementNoteNotApplicableNotFound)
        }
        let segment = CapexSegmentPayload(
            segmentName: nil, investmentAmount: total, yoyPercent: nil, description: nil)
        return .resolved(
            payload: StatementNotePayload(capexSegments: [segment]),
            source: statementNoteSourceXbrlFacts, contentHash: "\(total)")
    }

    /// `OverviewOfCapitalExpendituresEtcTextBlock` 内のセグメント別テーブルをパースする。
    /// 表が無ければ nil。金額の単位はヘッダーの「（億円）」「（百万円）」表記から判定する
    /// （未検出時は円のまま）。
    ///
    /// 実データ検証（2026-08-02）: 列数・ヘッダー文言・`rowspan` の使われ方が会社ごとに揺れる。
    /// - 日立: 4列（セグメント名/設備投資金額（億円）/前年度比（％）/主な内容・目的）、rowspanなし
    /// - ソフトバンクグループ: 2列（セグメントの名称/設備投資額（百万円））、先頭行に「報告セグメント」
    ///   を1文字ずつ縦書き表示する区分見出しセルが `rowspan` で複数行にまたがる（実データではない）
    /// - コニカミノルタ: 3列、`rowspan` が金額・目的セルに付き2つのセグメント名で1つの金額を共有
    ///   （デジタルワークプレイス事業/プロフェッショナルプリント事業が22,148百万円を共有）
    ///
    /// 固定の列位置に依存すると上記いずれかで欠落・ズレが起きるため、`gridRows` で `rowspan` を
    /// 展開した仮想グリッドを作り、「セグメント名の直後に来る最初の数値セル＝金額、その次の数値
    /// セルがあればYoY%、さらに残りの非空文字セルは説明」という内容ベースの列判定にする
    /// （列インデックス固定にしない）。
    private static func parseCapexTable(xbrlDir: URL) -> [CapexSegmentPayload]? {
        guard let html = XBRLUtils.extractTextblockHtml(
            in: xbrlDir, textblockTag: "OverviewOfCapitalExpendituresEtcTextBlock"),
            let soup = try? SwiftSoup.parse(html),
            let tables = (try? soup.select("table"))?.array()
        else { return nil }

        for table in tables {
            let rows = gridRows(from: table)
            var scale: Double?
            var segments: [CapexSegmentPayload] = []
            for cols in rows {
                guard !cols.isEmpty else { continue }
                if cols.contains(where: { $0.contains("設備投資") }) {
                    if cols.contains(where: { $0.contains("億円") }) { scale = 100_000_000 }
                    else if cols.contains(where: { $0.contains("百万円") }) { scale = 1_000_000 }
                    continue
                }
                guard let scale else { continue }
                guard let amountIdx = cols.firstIndex(where: { XBRLUtils.parseTextblockCellValue($0) != nil }),
                      amountIdx > 0
                else { continue }
                let amount = XBRLUtils.parseTextblockCellValue(cols[amountIdx])!
                let name = cols[amountIdx - 1]
                let after = Array(cols[(amountIdx + 1)...])
                var yoy: Double?
                var description: String?
                if let first = after.first, let v = XBRLUtils.parseTextblockCellValue(first) {
                    yoy = v
                    description = after.count > 1 ? after[1] : nil
                } else {
                    description = after.first
                }
                if let d = description, d.isEmpty || d == "－" { description = nil }
                let normalizedName = name.replacingOccurrences(of: "　", with: "").replacingOccurrences(
                    of: " ", with: "")
                // 「計」で終わる行（合計・小計・報告セグメント計等）は他行の集約であり、
                // 個別セグメントとして加算すると二重集計になる（実データ検証: 神戸製鋼所 S100QYHM
                // の「報告セグメント計」が鉄鋼アルミ〜電力7segmentの小計だった）。segmentNameは
                // ラベルのまま保持し、isTotalで集約行だと分かるようにする。
                let isTotal = normalizedName.hasSuffix("計")
                segments.append(
                    CapexSegmentPayload(
                        segmentName: name, investmentAmount: amount * scale, yoyPercent: yoy,
                        description: description, isTotal: isTotal))
            }
            if !segments.isEmpty { return segments }
        }
        return nil
    }

    /// `<table>` の各 `<tr>` を `rowspan` を展開した仮想グリッド（列固定・欠損セルなし）へ変換する。
    /// `colspan` は非対応（本note_typeで観測されていない。必要になれば拡張する）。
    private static func gridRows(from table: Element) -> [[String]] {
        guard let trs = (try? table.select("tr"))?.array() else { return [] }
        var pending: [Int: (text: String, remaining: Int)] = [:]
        var result: [[String]] = []
        for tr in trs {
            guard let tds = (try? tr.select("td"))?.array() else { continue }
            var cols: [String] = []
            var col = 0
            var cellIdx = 0
            while true {
                if let p = pending[col], p.remaining > 0 {
                    cols.append(p.text)
                    pending[col] = p.remaining == 1 ? nil : (p.text, p.remaining - 1)
                    col += 1
                    continue
                }
                guard cellIdx < tds.count else { break }
                let td = tds[cellIdx]
                let text = (try? td.text(trimAndNormaliseWhitespace: true)) ?? ""
                let rowspan = Int((try? td.attr("rowspan")) ?? "") ?? 1
                cols.append(text)
                if rowspan > 1 { pending[col] = (text, rowspan - 1) }
                cellIdx += 1
                col += 1
            }
            result.append(cols)
        }
        return result
    }

    private static let dividendRowContextRegex = try? NSRegularExpression(
        pattern: "^FilingDateInstant_Row([0-9]+)Member$")

    /// `FilingDateInstant_Row{N}Member` 形式の contextRef から行番号を取り出す。
    private static func dividendRowNumber(_ contextRef: String) -> Int? {
        guard let regex = dividendRowContextRegex else { return nil }
        let range = NSRange(contextRef.startIndex..<contextRef.endIndex, in: contextRef)
        guard let match = regex.firstMatch(in: contextRef, range: range),
              let numRange = Range(match.range(at: 1), in: contextRef)
        else { return nil }
        return Int(contextRef[numRange])
    }

    /// 指定条件に一致するタグの生テキストを contextRef 別に集める。`XBRLUtils.collectAllNumericFacts`
    /// は数値化できないテキストを破棄するため、本 resolver 専用に軽量な非数値テキストパーサーを持つ
    /// （現時点で 財務諸表注記取り込み note_type 以外に利用箇所が無いため `XBRLUtils` へは昇格させない）。
    private static func collectTextFacts(
        in xbrlDir: URL, isRelevantTag: @escaping (String) -> Bool
    ) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        for file in XBRLUtils.findXbrlFiles(in: xbrlDir) {
            guard let data = try? Data(contentsOf: file) else { continue }
            let delegate = StatementNoteTextFactParser(isRelevantTag: isRelevantTag)
            let parser = XMLParser(data: data)
            parser.delegate = delegate
            parser.parse()
            for (tag, ctxMap) in delegate.results {
                for (ctx, text) in ctxMap {
                    result[tag, default: [:]][ctx] = text
                }
            }
        }
        return result
    }
}

/// 指定条件に一致するタグの生テキストを contextRef 別に集める XMLParserDelegate。無関係な
/// テキストタグ（大量にある）を `isRelevantTag` で読み捨てる。
private final class StatementNoteTextFactParser: NSObject, XMLParserDelegate {
    var results: [String: [String: String]] = [:]
    private let isRelevantTag: (String) -> Bool

    private var currentTag = ""
    private var currentCtx = ""
    private var currentText = ""
    private var capturing = false

    init(isRelevantTag: @escaping (String) -> Bool) {
        self.isRelevantTag = isRelevantTag
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        capturing = false
        let localTag = XBRLUtils.localName(of: elementName)
        guard isRelevantTag(localTag), let ctx = attributeDict["contextRef"], !ctx.isEmpty else { return }
        currentTag = localTag
        currentCtx = ctx
        currentText = ""
        capturing = true
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { currentText += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard capturing else { return }
        capturing = false
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        results[currentTag, default: [:]][currentCtx] = trimmed
    }
}
