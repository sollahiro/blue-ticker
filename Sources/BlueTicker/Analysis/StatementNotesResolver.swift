// 財務諸表注記取り込み: 財務取り込み・内訳取り込み・Statement取り込み が対象外の財務諸表注記（Statement Notes）を note_type ごとに解決する。
// note_type ごとの決定論ロジックをこの1ファイルに集約する（種別×別ファイルは過剰。
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
    /// 単体（非連結）ベースであり、財務取り込み の連結 SG&A 合計とは母集団が異なる（合算しても一致しない）。
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

    /// IBD計算用CF補足（`borrowings_schedule` note_type）。
    ///
    /// 連結附属明細表「借入金等明細表」の構成科目（短期借入金・社債・長期借入金・リース負債等）を
    /// 当期首/当期末残高・平均利率つきで表として公開する。解析ロジックは
    /// `BorrowingsSchedule.extractRows`（`IBDExtractor` が使う `extract` と表探索・合計行判定を
    /// 共有、`BorrowingsSchedule.parseTable`）をそのまま再利用し、自前で明細表を再パースしない
    /// （重複ロジック回避）。合計行は `isTotal: true` で区別する（平均利率は「－」表記のため nil）。
    ///
    /// v2（2026-08-02）: 当初は当期末残高のみ `items: [StatementLineItem]` で返していたが、実データ
    /// レビュー（ユーザー、SOMPO S100R1LR）で平均利率・当期首残高も欲しいとの要望があり、
    /// `BorrowingsComponentPayload` へ切り出した（単一値の `StatementLineItem` では複数値を表現
    /// できないため）。返済期限（表の5列目）はユーザー判断で対象外（フリーテキストで構造化コストが
    /// 見合わない）。
    static func resolveBorrowingsSchedule(xbrlDir: URL) -> StatementNoteResolveResult {
        // US-GAAP 連結は附属明細表タグ経路が無く、Statement 本体と同様に明示対象外
        // （タグ不在の not_found に頼らず会計基準で揃える。2026-08-09）。
        let tagElements = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        if detectAccountingStandard(tagElements) == "US-GAAP" {
            return .notApplicable(reason: statementNotApplicableUSGAAP)
        }

        guard let result = BorrowingsSchedule.extractRows(xbrlDir: xbrlDir) else {
            return .notApplicable(reason: statementNoteNotApplicableNotFound)
        }

        var components: [BorrowingsComponentPayload] = result.rows.compactMap { row in
            guard row.current != nil || row.prior != nil else { return nil }
            return BorrowingsComponentPayload(
                label: row.label, priorBalance: row.prior, currentBalance: row.current,
                averageInterestRatePercent: row.averageInterestRatePercent)
        }
        if result.totalCurrent != nil || result.totalPrior != nil {
            components.append(
                BorrowingsComponentPayload(
                    label: "合計", priorBalance: result.totalPrior, currentBalance: result.totalCurrent,
                    averageInterestRatePercent: nil, isTotal: true))
        }
        guard !components.isEmpty else {
            return .notApplicable(reason: statementNoteNotApplicableNotFound)
        }

        let hash = components.map {
            "\($0.label)=\($0.priorBalance ?? -1),\($0.currentBalance ?? -1),\($0.averageInterestRatePercent ?? -1)"
        }.joined(separator: ";")
        return .resolved(
            payload: StatementNotePayload(borrowingsComponents: components),
            source: statementNoteSourceXbrlFacts, contentHash: hash)
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
    /// 本 note_type は意図的に IFRS 連結企業限定（ユーザー判断、2026-08-12）。smoke 固定11社の
    /// 実データ検証で、非IFRS企業の扱いは会計基準で以下のように分かれることを確認済み:
    ///
    /// - J-GAAP連結企業: `statement`（Statement本体のBS）の`PropertyPlantAndEquipmentAbstract`配下に
    ///   区分別タグ（`BuildingsAndStructuresNet`・`MachineryEquipmentAndVehiclesNet`等）が構造化されて
    ///   おり、そちらから取得できる（オークマ S100W043・ニチレイ S100VYA0・AZplanning S100VU4O・
    ///   三菱UFJ S100W4FB・三井住友 S100W0S7 で実データ確認済み）。連結財務諸表を持たない企業
    ///   （東邦レマック S100XRD8）は個別BS（role=`jppfs/rol_BalanceSheet`）の`BuildingsNet`等が同役割を
    ///   果たす。これらは本note_typeでは扱わず、`statementNoteNotApplicableAvailableViaStatement`
    ///   （`reason`でStatementを案内）に倒す。
    /// - US-GAAP連結企業: `ix:nonFraction`が無く構造化タグで判定できない。開示HTML自体に区分別
    ///   内訳が載るか会社によって異なる（実データ確認済み、2026-08-12: 富士フイルム S100W3XJ は
    ///   連結BS本表に「土地／建物及び構築物／機械装置及びその他の有形固定資産／建設仮勘定」の内訳が
    ///   直接載るが、キヤノン S100XTLJ は連結BSに「Ⅳ有形固定資産」の合計1行のみで、区分別内訳は
    ///   別注記「注５　有形固定資産」のHTML表にしかない。`statement`のUS-GAAP HTML抽出
    ///   （`USGAAPStatementHtml`）はBS本表しか読まないため、キヤノンのように内訳が別注記にある
    ///   会社ではStatementからも取得できない）。会社ごとに開示形式が違い構造化タグでの判別もできない
    ///   ため、Statementを案内する`available_via_statement`は誤りうる。`resolveBorrowingsSchedule`と
    ///   同じ`statementNotApplicableUSGAAP`（US-GAAP自体を対応見送り）に倒す。
    static func resolvePropertyPlantEquipmentSchedule(xbrlDir: URL) -> StatementNoteResolveResult {
        let tagElements = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        switch detectAccountingStandard(tagElements) {
        case "IFRS":
            return resolveIFRSCategorySchedule(
                xbrlDir: xbrlDir,
                roleName: "NotesPropertyPlantAndEquipmentConsolidatedFinancialStatementsIFRS")
        case "US-GAAP":
            return .notApplicable(reason: statementNotApplicableUSGAAP)
        default:
            return .notApplicable(reason: statementNoteNotApplicableAvailableViaStatement)
        }
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
    ///
    /// smoke 固定11社の実データ検証・目視確認（2026-08-12）: IFRS連結3社中、味の素(S100VXJA)・
    /// クボタ(S100XR0M)は開示HTML（のれん・無形資産の帳簿価額増減表）の実数値と完全一致
    /// （ユーザー確認済みgolden、`GoodwillAndIntangiblesOracleFormatTests`参照）。スズキ(S100W4MT)は
    /// `.notApplicable(not_found)` だが実装ギャップではない——スズキの開示に`GoodwillIFRS`タグ自体が
    /// 一切存在せず（のれんの重要性なし）、注記見出しも標準タクソノミの別ロール
    /// `NotesIntangibleAssetsConsolidatedFinancialStatementsIFRS`（「のれん」を含まない無形資産のみの
    /// 注記）になっている。役割名バリアントの追加対応は行わない（ユーザー判断: goodwill行ゼロの
    /// payloadは`goodwill_and_intangibles`の名として不適切）。
    static func resolveGoodwillAndIntangibles(xbrlDir: URL) -> StatementNoteResolveResult {
        resolveIFRSCategorySchedule(
            xbrlDir: xbrlDir,
            roleName: "NotesGoodwillAndIntangibleAssetsConsolidatedFinancialStatementsIFRS")
    }

    /// リース負債（`lease_liabilities` note_type）。
    ///
    /// **notes は TextBlock 注記のみ**（実データ検証 2026-08-12、smoke 固定11社）。
    /// 連結 BS の構造化タグ（`LeaseLiabilities*IFRS` / `LeaseObligations*`）は `statement` と同じ
    /// 値になるため本 note では採用しない。タグがある場合は `available_via_statement`。
    ///
    /// 1. IFRS リース注記 TextBlock（`IFRSLease` の TextBlock 経路。**BS HTML・BS タグは使わない**）。
    ///    味の素は「支払期日が1年以内／1年超」＝流動・非流動の帳簿価額。スズキは帳簿価額合計
    ///    ＋満期バケット（割引前CF）、クボタは現在価値合計＋満期バケット。貸手表とは表単位で分離。
    /// 2. BS にリース負債タグあり、または US-GAAP → `.notApplicable(available_via_statement)`。
    /// 3. それ以外 → `not_found`（オークマ等のリース債務は `borrowings_schedule` 側）。
    static func resolveLeaseLiabilities(xbrlDir: URL) -> StatementNoteResolveResult {
        let tagElements = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let accountingStandard = detectAccountingStandard(tagElements)
        let fieldSet = fieldSetFromInstant(tagElements)

        // TextBlock があるときだけ IFRSLease を呼ぶ。fieldSet は空渡しでパターンA（BSタグ）をスキップ。
        let hasIFRSTextblock =
            XBRLUtils.extractTextblockHtml(in: xbrlDir, textblockTag: Xbrl.ifrsLeasesTextblockTag)
            != nil
        if hasIFRSTextblock {
            let lease = IFRSLease.extractLeaseLiabilities(fieldSet: [:], xbrlDir: xbrlDir)
            var textblockItems: [StatementLineItem] = []
            for (order, component) in lease.components.enumerated() {
                guard let current = component.current else { continue }
                textblockItems.append(
                    StatementLineItem(
                        tag: Xbrl.ifrsLeasesTextblockTag, label: component.label, value: current,
                        unit: "yen", order: order))
            }
            if textblockItems.isEmpty, let current = lease.current {
                textblockItems.append(
                    StatementLineItem(
                        tag: Xbrl.ifrsLeasesTextblockTag, label: "リース負債", value: current,
                        unit: "yen", order: 0))
            }
            let baseOrder = textblockItems.count
            for (offset, bucket) in lease.maturityBuckets.enumerated() {
                guard let current = bucket.current else { continue }
                textblockItems.append(
                    StatementLineItem(
                        tag: Xbrl.ifrsLeasesTextblockTag, label: bucket.label, value: current,
                        unit: "yen", order: baseOrder + offset))
            }
            if !textblockItems.isEmpty {
                return resolvedLeaseLiabilities(items: textblockItems)
            }
        }

        let bsLeaseTags = [
            "LeaseLiabilitiesCLIFRS", "LeaseLiabilitiesNCLIFRS",
            "LeaseObligationsCL", "LeaseObligationsNCL",
        ]
        let hasBSLeaseTag = bsLeaseTags.contains {
            resolveItem(fieldSet, tags: [$0]).current != nil
        }
        if hasBSLeaseTag || accountingStandard == "US-GAAP" {
            return .notApplicable(reason: statementNoteNotApplicableAvailableViaStatement)
        }
        return .notApplicable(reason: statementNoteNotApplicableNotFound)
    }

    private static func resolvedLeaseLiabilities(items: [StatementLineItem]) -> StatementNoteResolveResult {
        let hash = items.map { "\($0.tag)=\($0.value)" }.joined(separator: ",")
        return .resolved(
            payload: StatementNotePayload(items: items), source: statementNoteSourceXbrlFacts,
            contentHash: hash)
    }

    /// IFRS注記に共通の「資産区分ごとに正味帳簿価額・取得原価・累計償却/減損の3タグが揃う」構造から
    /// 正味帳簿価額タグだけを抽出する共通処理（PPE・のれん双方で使う）。
    ///
    /// 実データ検証（2026-08-02、トヨタ S100VWVY）: 「取得原価」「累計償却/減損」を示す
    /// キーワード（`AcquisitionCost`/`AccumulatedDepreciation`/`AccumulatedAmortization`/
    /// `AccumulatedImpairment`）の後に付く語尾は会社により揺れる（トヨタの
    /// `VehiclesAndEquipmentOnOperatingLeasesAccumulatedDepreciationAndImpairmentIFRS` は
    /// 「Losses」が無く固定サフィックス完全一致では除外できなかった）。除外判定はサフィックス
    /// 完全一致ではなくキーワードの部分一致にする（トヨタはPPE区分ごとに正味帳簿価額タグ自体を
    /// 持たず取得原価・累計償却の2タグのみのため、修正後は本note_typeが正しく notApplicable になる）。
    private static let ifrsComponentKeywords = [
        "AcquisitionCost",
        "AccumulatedDepreciation",
        "AccumulatedAmortization",
        "AccumulatedImpairment",
    ]

    private static func resolveIFRSCategorySchedule(
        xbrlDir: URL, roleName: String
    ) -> StatementNoteResolveResult {
        let facts = XBRLUtils.collectAllNumericFacts(in: xbrlDir)

        // 表示順は presentation linkbase の並び順（`XbrlFact.orderByRole`、Statement 本体の
        // `StatementClassifier` と同じ仕組み）を使う。取得できないタグはタグ名のアルファベット順に
        // フォールバックする（決定的な順序を保つため）。
        var labelsByTag: [String: String?] = [:]
        var orderByTag: [String: Int] = [:]
        for (tag, ctxMap) in facts
        where tag.hasSuffix("IFRS") && !ifrsComponentKeywords.contains(where: { tag.contains($0) }) {
            for fact in ctxMap.values {
                let roles = fact.roles ?? fact.role.map { [$0] } ?? []
                if let matchedRole = roles.first(where: { XBRLUtils.sectionNameFromRole($0) == roleName }) {
                    labelsByTag[tag] = fact.label
                    if let order = fact.orderByRole?[matchedRole] { orderByTag[tag] = order }
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
            items.append(
                StatementLineItem(tag: tag, label: label, value: value, unit: "yen", order: orderByTag[tag]))
        }
        guard !items.isEmpty else {
            return .notApplicable(reason: statementNoteNotApplicableNotFound)
        }
        items.sort { lhs, rhs in
            switch (lhs.order, rhs.order) {
            case let (l?, r?) where l != r: return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.tag < rhs.tag
            }
        }

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
    /// 「みなし保有株式」（退職給付信託等、議決権行使を指図する権限のみ保有するケース）も同一開示
    /// セクション内に別のタグ体系（`DeemedHoldingsOfEquitySecurities...`、変体構造は特定投資株式と同型）
    /// で開示されるため、`isDeemedHolding` フラグを立てて特定投資株式の後に連結する（実データ検証
    /// 2026-08-11: smoke固定11社中4社・トヨタ含む既存golden3社で確認、開示上も特定投資株式セクションの
    /// 直後に別表として並ぶ）。
    ///
    /// 提出会社自身が保有する場合は `...ReportingCompany` サフィックス、純粋持株会社で子会社が
    /// 保有する場合は `...LargestHoldingCompany`/`...SecondLargestHoldingCompany`
    /// （最大保有会社／第二位保有会社）サフィックスになる。3変体は排他的に出現し contextRef の
    /// Row番号は変体ごとに独立した連番のため、変体をまたいで突き合わせてはならない
    /// （変体ごとに個別に行を組み立てて連結する）。特定投資株式とみなし保有株式も互いに独立した
    /// Row連番を持つ（同じ会社でも両方が変体・Row番号を共有しない）。
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
    ///
    /// **既知の限界**: ごく稀に提出会社側のXBRLタグ付け自体が開示本文（HTMLテーブル）に対して
    /// 大幅に不完全な書類が存在する（実データ検証2026-08-11: 三井住友FGの2025年3月期有価証券報告書
    /// 原本S100W0S7は本文70銘柄のうち構造化タグは13銘柄のみ。同社の訂正報告書S100WRZHでは70銘柄
    /// 全件が正しくタグ付けされており、前後の期（2024年3月期・2026年3月期）の原本も問題なし。
    /// 本関数はXBRLの構造化タグのみを読むため、この種の提出者側タグ付け不備は検出できない）。
    static func resolvePolicyHoldingSecurities(xbrlDir: URL) -> StatementNoteResolveResult {
        let numericElements = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let textFacts = collectPolicyHoldingTextFacts(in: xbrlDir)

        var securities: [PolicyHoldingSecurityPayload] = []
        for category in policyHoldingCategories {
            for variant in policyHoldingHolderVariants {
                let nameTag = category.namePrefix + variant
                guard let names = textFacts[nameTag], !names.isEmpty else { continue }

                let sharesTag = category.sharesPrefix + variant
                let bookValueTag = category.bookValuePrefix + variant
                let sharesByCtx = numericElements[sharesTag] ?? [:]
                let bookValueByCtx = numericElements[bookValueTag] ?? [:]
                let purposeTag = textFacts.keys.first {
                    isPolicyHoldingPurposeTag($0, purposeKeyword: category.purposeKeyword, variant: variant)
                }
                let purposeByCtx = purposeTag.flatMap { textFacts[$0] } ?? [:]

                var variantRows: [(row: Int, security: PolicyHoldingSecurityPayload)] = []
                for (ctx, name) in names {
                    guard let row = policyHoldingCurrentYearRowNumber(ctx) else { continue }
                    variantRows.append((
                        row,
                        PolicyHoldingSecurityPayload(
                            issuerName: normalizePolicyHoldingIssuerName(name),
                            numberOfShares: sharesByCtx[ctx],
                            carryingAmount: bookValueByCtx[ctx],
                            purpose: purposeByCtx[ctx],
                            isDeemedHolding: category.isDeemedHolding)
                    ))
                }
                securities.append(contentsOf: variantRows.sorted { $0.row < $1.row }.map(\.security))
            }
        }

        let summary = resolvePolicyHoldingAggregateSummary(numericElements: numericElements)

        guard !securities.isEmpty || summary != nil else {
            return .notApplicable(reason: statementNoteNotApplicableNotFound)
        }

        let securitiesHash = securities.map {
            "\($0.issuerName)=\($0.numberOfShares ?? -1),\($0.carryingAmount ?? -1),\($0.isDeemedHolding)"
        }.joined(separator: ";")
        let summaryHash = summary.map {
            "summary=\($0.unlistedIssueCount ?? -1),\($0.unlistedCarryingAmount ?? -1)," +
            "\($0.listedIssueCount ?? -1),\($0.listedCarryingAmount ?? -1)"
        } ?? ""
        return .resolved(
            payload: StatementNotePayload(
                securities: securities.isEmpty ? nil : securities, policyHoldingSummary: summary),
            source: statementNoteSourceXbrlFacts,
            contentHash: securitiesHash + ";" + summaryHash)
    }

    /// 政策保有株式（保有目的が純投資目的以外の目的である投資株式）の銘柄数及び貸借対照表計上額の
    /// 合計額。個別開示される`securities`とは別の集計タグ（`NumberOfIssuesShares...`/
    /// `CarryingAmountShares...`、非上場株式／非上場株式以外の株式の2区分）で、開示される全銘柄
    /// （個別開示されない銘柄も含む）を対象とする。提出会社・子会社の各variantの値を合算する
    /// （実データ確認2026-08-11: 富士フイルムは提出会社=上場株式のみ・第二位保有会社=両区分ありと
    /// variantごとに片方しか無いケースがあるため、単純合算が必要）。
    private static func resolvePolicyHoldingAggregateSummary(
        numericElements: XbrlTagElements
    ) -> PolicyHoldingAggregateSummaryPayload? {
        var unlistedCount: Double?
        var unlistedAmount: Double?
        var listedCount: Double?
        var listedAmount: Double?

        for variant in policyHoldingHolderVariants {
            unlistedCount = sumOptional(
                unlistedCount, numericElements[policyHoldingUnlistedIssueCountPrefix + variant]?["CurrentYearInstant"])
            unlistedAmount = sumOptional(
                unlistedAmount, numericElements[policyHoldingUnlistedAmountPrefix + variant]?["CurrentYearInstant"])
            listedCount = sumOptional(
                listedCount, numericElements[policyHoldingListedIssueCountPrefix + variant]?["CurrentYearInstant"])
            listedAmount = sumOptional(
                listedAmount, numericElements[policyHoldingListedAmountPrefix + variant]?["CurrentYearInstant"])
        }

        guard unlistedCount != nil || unlistedAmount != nil || listedCount != nil || listedAmount != nil else {
            return nil
        }
        return PolicyHoldingAggregateSummaryPayload(
            unlistedIssueCount: unlistedCount.map { Int($0) }, unlistedCarryingAmount: unlistedAmount,
            listedIssueCount: listedCount.map { Int($0) }, listedCarryingAmount: listedAmount)
    }

    /// `a`・`b`のうち存在する方を足す（両方nilならnil）。`nilAsZero: false`で読んだ値を跨いで
    /// 合算するため、単純な`(a ?? 0) + (b ?? 0)`だと「両方未開示」を`0`として返してしまう。
    private static func sumOptional(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case (nil, nil): return nil
        case (let a?, nil): return a
        case (nil, let b?): return b
        case (let a?, let b?): return a + b
        }
    }

    private static let policyHoldingUnlistedIssueCountPrefix =
        "NumberOfIssuesSharesNotListedInvestmentSharesHeldForPurposesOtherThanPureInvestment"
    private static let policyHoldingUnlistedAmountPrefix =
        "CarryingAmountSharesNotListedInvestmentSharesHeldForPurposesOtherThanPureInvestment"
    private static let policyHoldingListedIssueCountPrefix =
        "NumberOfIssuesSharesOtherThanThoseNotListedInvestmentSharesHeldForPurposesOtherThanPureInvestment"
    private static let policyHoldingListedAmountPrefix =
        "CarryingAmountSharesOtherThanThoseNotListedInvestmentSharesHeldForPurposesOtherThanPureInvestment"

    /// `ReportingCompany`/`LargestHoldingCompany`/`SecondLargestHoldingCompany` の順（実データ確認済み、
    /// 3変体は排他的に出現するため順序自体に意味はないが、出力順を安定させるため固定する）。
    private static let policyHoldingHolderVariants = [
        "ReportingCompany", "LargestHoldingCompany", "SecondLargestHoldingCompany",
    ]

    private struct PolicyHoldingCategory {
        let namePrefix: String
        let sharesPrefix: String
        let bookValuePrefix: String
        /// 保有目的タグ判定用のキーワード（`isPolicyHoldingPurposeTag` 参照）。
        let purposeKeyword: String
        let isDeemedHolding: Bool
    }

    /// 特定投資株式を先、みなし保有株式を後に連結する（開示本文の表の並び順と一致させる）。
    private static let policyHoldingCategories: [PolicyHoldingCategory] = [
        PolicyHoldingCategory(
            namePrefix: "NameOfSecuritiesDetailsOfSpecifiedInvestmentEquitySecuritiesHeldForPurposesOtherThanPureInvestment",
            sharesPrefix: "NumberOfSharesHeldDetailsOfSpecifiedInvestmentEquitySecuritiesHeldForPurposesOtherThanPureInvestment",
            bookValuePrefix: "BookValueDetailsOfSpecifiedInvestmentEquitySecuritiesHeldForPurposesOtherThanPureInvestment",
            purposeKeyword: "DetailsOfSpecifiedInvestmentSharesHeldForPurposesOtherThanPureInvestment",
            isDeemedHolding: false),
        PolicyHoldingCategory(
            namePrefix: "NameOfSecuritiesDetailsOfDeemedHoldingsOfEquitySecuritiesHeldForPurposesOtherThanPureInvestment",
            sharesPrefix: "NumberOfSharesHeldDetailsOfDeemedHoldingsOfEquitySecuritiesHeldForPurposesOtherThanPureInvestment",
            bookValuePrefix: "BookValueDetailsOfDeemedHoldingsOfEquitySecuritiesHeldForPurposesOtherThanPureInvestment",
            purposeKeyword: "DetailsOfDeemedHoldingsOfSharesHeldForPurposesOtherThanPureInvestment",
            isDeemedHolding: true),
    ]

    /// 保有目的タグは実データ上、`ReportingCompany` 変体と `Largest`/`SecondLargest` 変体で中間の
    /// 語句が異なる（後者は「事業上の関係の概要」が挿入される）ため、固定タグ名ではなく
    /// プレフィックス＋サフィックスで判定する。`LargestHoldingCompany` は `SecondLargestHoldingCompany`
    /// の末尾一致でもあるため、`variant` が前者のときは後者を明示的に除外する。
    private static func isPolicyHoldingPurposeTag(_ tag: String, purposeKeyword: String, variant: String) -> Bool {
        guard tag.hasPrefix("PurposeOfShareholding"),
              tag.contains(purposeKeyword),
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

    /// 銘柄名のfact自体に改行が混入しているケースがある（実データ確認: 味の素「㈱セブン＆アイ・\n
    /// ホールディングス」、ニチレイ「㈱三菱ＵＦＪ\nフィナンシャル・グループ」等）。開示HTML側で
    /// 長い社名がセル内で折り返されており、その改行がXBRLのテキストfactにそのまま残ったもの
    /// （保有目的テキストの箇条書き改行とは異なり、社名は本来1行のテキストであるため除去する）。
    private static func normalizePolicyHoldingIssuerName(_ name: String) -> String {
        name.replacingOccurrences(of: "\r\n", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }

    /// 政策保有株式（特定投資株式・みなし保有株式）の銘柄名・保有目的テキストを
    /// {tag: {contextRef: text}} で集める。
    private static func collectPolicyHoldingTextFacts(in xbrlDir: URL) -> [String: [String: String]] {
        collectTextFacts(in: xbrlDir) {
            $0.hasPrefix("NameOfSecuritiesDetailsOfSpecifiedInvestment")
                || $0.hasPrefix("NameOfSecuritiesDetailsOfDeemedHoldings")
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
    ///
    /// タグ透明性（2026-08-11、smoke固定11社で生タグ再確認）: `dividendPerShare`/`totalAmount` は
    /// スモーク11社すべてで上記2タグ固定（フォールバック候補なし）のため、値が取れた行にのみ
    /// タグ名をそのまま `dividendPerShareTag`/`totalAmountTag` として付与する。
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
                    dividendPerShare: perShareByCtx[ctx], totalAmount: totalByCtx[ctx],
                    dividendPerShareTag: perShareByCtx[ctx] != nil ? "DividendPerShareDividendsOfSurplus" : nil,
                    totalAmountTag: totalByCtx[ctx] != nil ? "TotalAmountOfDividendsDividendsOfSurplus" : nil)
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
    /// US-GAAPが`EquityAttributableToOwnersOfParentPerShareUSGAAPSummaryOfBusinessResults`
    /// （2026-08-11 smoke確認: 富士フイルム S100W3XJ=2779.50・キヤノン S100XTLJ=3974.81、
    /// HTMLラベル「１株当たり株主資本」）、IFRSは`EquityToAssetRatioIFRSSummaryOfBusinessResults`
    /// （タグ名誤り、`unitRef=JPYPerShares`で判別、日立 S100QZT0「１株当たり親会社株主持分」
    /// ラベルと完全一致を確認済み）。
    /// カバレッジ実測（キャッシュ144件）: EPS 144/144、BPS 142/144（US-GAAP連結BPSタグ未対応時）、
    /// 潜在株式調整後EPS 65/144（希薄化効果のある証券が無く注記自体に希薄化後EPSを持たない企業は欠落OK、
    /// 2026-08-11 ユーザー確認）。
    ///
    /// 前期比較値は持たない。`company_statement_notes` はdocID（＝1事業年度）単位でingestされる
    /// ため、前期値は前期docIDの`value`で取得できる（財務取り込み `years[]` と同型、ユーザー判断
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
        } else if let bps = resolveItem(instantFS, tags: Xbrl.equityPerShareUSGAAPTags).current {
            items.append(
                StatementLineItem(
                    tag: "bps", label: "１株当たり株主資本", value: bps, unit: "yen_per_share", order: nil))
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
    /// セグメント表が無ければ nil。金額の単位は表内の「億円」「百万円」「千円」表記から判定する
    /// （未検出時は円のまま）。「（単位：百万円）」だけの注記表がデータ表の前に置かれる会社
    /// （ニチレイ S100VYA0）があるため、単位は前の表から継承する。
    ///
    /// 実データ検証（2026-08-02 初回、2026-08-10 smoke 11社で拡張）。列数・ヘッダー文言・
    /// `rowspan`/`colspan` の使われ方が会社ごとに揺れる:
    /// - 日立: 4列（セグメント名/設備投資金額（億円）/前年度比（％）/主な内容・目的）、rowspanなし
    /// - ソフトバンクグループ: 2列（セグメントの名称/設備投資額（百万円））。ヘッダーの
    ///   「セグメントの名称」とデータの「その他」「合計」が colspan=2。先頭行に「報告セグメント」
    ///   を縦書き表示する区分見出しセルが `rowspan` で複数行にまたがる（実データではない）
    /// - コニカミノルタ: 3列、`rowspan` が金額・目的セルに付き2つのセグメント名で1つの金額を共有
    ///   （デジタルワークプレイス事業/プロフェッショナルプリント事業が22,148百万円を共有）
    /// - ニチレイ: 単位表記が別テーブルに分離。ヘッダーの「前/当連結会計年度」「前期比」が
    ///   colspan=2 で空白の整形列をまたぐ。「前期比」列は差額（百万円）で％ではないため
    ///   yoyPercent には入れない
    /// - クボタ: 2段見出し（「前年度/当年度/前年度比（％）」＋「金額（百万円)」）。金額は当期列を選ぶ
    ///   （旧実装は最初の数値セル=金額のため前期値を誤取得していた）
    /// - 富士フイルム: セグメント表の直後に「主要な設備の状況」と同型の個別設備一覧が同じ
    ///   TextBlock に混入する（個別設備一覧は除外対象）
    /// - オークマ: 表が個別設備一覧（会社名・事業所名/所在地/セグメントの名称/設備の内容/金額）
    ///   のみ。「主な設備投資」の抜粋で総額の内訳ではないため除外し、総額タグへフォールバックする
    ///
    /// 固定の列位置に依存すると上記いずれかで欠落・ズレが起きるため、`gridRows` で `rowspan`/
    /// `colspan` を展開した仮想グリッドを作り、ヘッダー行の文言（当/前/％/金額/名称/内容）で列を
    /// 分類する内容ベースの列判定にする（列インデックス固定にしない）。ヘッダーから列を分類
    /// できない表だけ旧来のフォールバック（セグメント名の直後の最初の数値=金額、その次の数値
    /// があればYoY%）を使う。
    private static func parseCapexTable(xbrlDir: URL) -> [CapexSegmentPayload]? {
        guard let html = XBRLUtils.extractTextblockHtml(
            in: xbrlDir, textblockTag: "OverviewOfCapitalExpendituresEtcTextBlock"),
            let soup = try? SwiftSoup.parse(html),
            let tables = (try? soup.select("table"))?.array()
        else { return nil }

        var inheritedScale: Double?
        for table in tables {
            let rows = gridRows(from: table)
            if let scale = capexTableScale(rows) { inheritedScale = scale }
            guard let scale = inheritedScale else { continue }

            let headerRowCount = rows.prefix(while: { isCapexHeaderRow($0) }).count
            let headerRows = rows.prefix(headerRowCount)
            // 「会社名・事業所名／所在地」列を持つ表はセグメント別内訳ではなく個別設備一覧
            // （オークマ S100W043、富士フイルム S100W3XJ の後続表）。主な設備の抜粋であり総額の
            // 内訳ではないため除外する
            let headerCells = headerRows.flatMap { $0 }
            if headerCells.contains(where: {
                $0.contains("会社名") || $0.contains("事業所名") || $0.contains("所在地")
            }) { continue }

            // ヘッダー文言から列を分類する（複数段見出しは同じ列の文言を連結して判定）
            var colHeader: [Int: String] = [:]
            for row in headerRows {
                for (i, cell) in row.enumerated() where !cell.isEmpty {
                    colHeader[i, default: ""] += " " + cell
                }
            }
            var nameCols: [Int] = []
            var currentCols: [Int] = []
            var amountCols: [Int] = []
            var yoyCols: [Int] = []
            var descCols: [Int] = []
            for (i, h) in colHeader {
                if h.contains("％") || h.contains("%") {
                    yoyCols.append(i)
                } else if h.contains("比") {
                    // 「前期比」が差額（百万円）の会社（ニチレイ）があるため、％表記でない
                    // 比較列は yoyPercent に入れない
                    continue
                } else if h.contains("前"), h.contains("期") || h.contains("年度") {
                    continue  // 前期列は payload にフィールドがなく、金額列候補からも外す
                } else if h.contains("当"), h.contains("期") || h.contains("年度") {
                    currentCols.append(i)
                } else if h.contains("設備投資") || h.contains("投資額") || h.contains("金額") {
                    amountCols.append(i)
                } else if h.contains("名称") || h.contains("セグメント") {
                    nameCols.append(i)
                } else if h.contains("内容") || h.contains("目的") {
                    descCols.append(i)
                }
            }
            // 当期列が特定できたらそこだけを使う。なければ汎用の金額列。どちらも無ければ
            // 旧フォールバック（行内の最初の数値=金額）
            let primaryAmountCols = (currentCols.isEmpty ? amountCols : currentCols).sorted()

            var segments: [CapexSegmentPayload] = []
            for cols in rows.dropFirst(headerRowCount) {
                guard !cols.isEmpty else { continue }
                let amount: Double
                let amountIdx: Int
                var yoy: Double?
                var description: String?
                if !primaryAmountCols.isEmpty {
                    var found: (idx: Int, value: Double)?
                    for i in primaryAmountCols where i < cols.count {
                        if let v = XBRLUtils.parseTextblockCellValue(cols[i]) {
                            found = (i, v)
                            break
                        }
                    }
                    guard let f = found else { continue }  // 金額欄が「―」等の行は飛ばす
                    amount = f.value
                    amountIdx = f.idx
                    for i in yoyCols where i < cols.count {
                        if let v = XBRLUtils.parseTextblockCellValue(cols[i]) { yoy = v; break }
                    }
                    if !descCols.isEmpty {
                        description = descCols.lazy.filter { $0 < cols.count }.map { cols[$0] }
                            .first { !$0.isEmpty && XBRLUtils.parseTextblockCellValue($0) == nil }
                    }
                } else {
                    guard let idx = cols.firstIndex(where: {
                        XBRLUtils.parseTextblockCellValue($0) != nil
                    }), idx > 0
                    else { continue }
                    amountIdx = idx
                    amount = XBRLUtils.parseTextblockCellValue(cols[idx])!
                    let after = Array(cols[(idx + 1)...])
                    if let first = after.first, let v = XBRLUtils.parseTextblockCellValue(first) {
                        yoy = v
                        description = after.count > 1 ? after[1] : nil
                    } else {
                        description = after.first
                    }
                }
                // セグメント名: 名称列が分類できていればその末尾側を優先する（ソフトバンクGは
                // 「報告セグメント」区分見出しが名称列の手前に rowspan で入るため、先頭を取ると
                // 区分見出しをセグメント名と誤認する）。分類できなければ金額列より左の最初の
                // 非数値セルを使う
                var name: String?
                if !nameCols.isEmpty {
                    name = nameCols.sorted().reversed().lazy.filter { $0 < cols.count }
                        .map { cols[$0] }
                        .first { !$0.isEmpty && XBRLUtils.parseTextblockCellValue($0) == nil }
                }
                if name == nil, amountIdx > 0 {
                    name = cols[..<amountIdx]
                        .first { !$0.isEmpty && XBRLUtils.parseTextblockCellValue($0) == nil }
                }
                guard let name else { continue }
                if description == nil, descCols.isEmpty, !primaryAmountCols.isEmpty {
                    // 説明列が分類できなかった表向けの従来互換フォールバック（金額列より右の
                    // 最初の非数値セル）。YoY列は数値なのでここには来ない
                    description = cols[(amountIdx + 1)...]
                        .first { !$0.isEmpty && XBRLUtils.parseTextblockCellValue($0) == nil }
                }
                if let d = description, d.isEmpty || ["－", "-", "—", "―"].contains(d) {
                    description = nil
                }
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

    /// 設備投資表の金額単位。表内のいずれかのセルの単位表記から判定する（億円→百万円→千円の
    /// 優先順。ヘッダー行の「設備投資金額（億円）」のような表記を含む行がデータ行とは限らない
    /// ため、行ではなくセル単位で走査する）。
    private static func capexTableScale(_ rows: [[String]]) -> Double? {
        let cells = rows.flatMap { $0 }
        if cells.contains(where: { $0.contains("億円") }) { return 100_000_000 }
        if cells.contains(where: { $0.contains("百万円") }) { return 1_000_000 }
        if cells.contains(where: { $0.contains("千円") }) { return 1_000 }
        return nil
    }

    /// 設備投資表の見出し行判定。数値セルを含まず見出し語を含む行を見出しとみなす。
    /// 2段見出し（クボタ S100XR0M の「前年度/当年度」＋「金額（百万円)」）や単位だけの行
    /// （富士フイルム S100W3XJ の「（百万円）」）に対応するため、先頭から連続する限り
    /// すべて見出し行として列分類の材料にする。
    private static func isCapexHeaderRow(_ cols: [String]) -> Bool {
        if cols.contains(where: { XBRLUtils.parseTextblockCellValue($0) != nil }) { return false }
        let joined = cols.joined(separator: " ")
        return [
            "名称", "年度", "会計年度", "金額", "投資額", "設備投資", "内容", "目的",
            "億円", "百万円", "千円", "％", "比",
        ].contains { joined.contains($0) }
    }

    /// 発行済株式総数・資本金等（`issued_shares_and_capital` note_type）。
    ///
    /// 2経路を併記する（2026-08-11）:
    /// 1. **`as_of_period_end`（離散XBRLタグ）**: 期末の発行済株式・資本金・資本準備金。
    ///    発行済は `PerShareExtractor` と同じ解決（financials / smoke の `per_share.issued_shares`
    ///    と一致）。資本金は `ShareCapitalIFRS`→Summary→`CapitalStock`、資本準備金は
    ///    `LegalCapitalSurplus`（その他資本剰余金を含む `CapitalSurplus*` は使わない）。
    ///    将来 summary を notes から読む場合も期末値の正はこちら。
    /// 2. **`issued_shares_events`（textblock HTML表）**: 分割・消却・増資などのイベント列。
    ///    表が千株丸めの会社では最終行残高がタグ期末と数百株ずれることがある（味の素・クボタ等）。
    ///    履歴用途であり期末の正には使わない。
    ///
    /// 表パースの揺れ（2026-08-02 実データ検証）:
    /// - 単位が会社ごとに揺れる（株数=株/千株、金額=千円/百万円）。ヘッダー文言から都度判定し、
    ///   常に「株」「円」の生値へ正規化する（列固定にしない）
    /// - 「自◯年◯月◯日 至◯年◯月◯日」という期間表記の行が挟まる会社がある。日立は変動なし
    ///   確認用（3つの増減欄＝株数・資本金・資本準備金がすべて「－」）だが、メルカリは新株予約権
    ///   行使の集約開示（増減欄が実数）に使っており、「単発日付か期間表記か」では判定できない。
    ///   Notes は基本 XBRL からそのまま構造化する方針のため、なるべく行を省かない: 3つの増減欄の
    ///   いずれか1つでも実数なら採用する（残高欄は前行から常に繰り越されるため判定に使わない）。
    ///   JT・横河電機は株数は動かず資本準備金だけ動いた行（会社法448条に基づく振替）を持ち、
    ///   株数増減欄だけで判定すると取りこぼす（実データで発見）
    /// - メルカリは各セルが「普通株式」というラベル行＋数値行の2つの`<p>`を1つの`<td>`にまとめて
    ///   持つ（例:「普通株式 2,840,500」）。列固定・完全一致パースだと数値を取りこぼすため、
    ///   セルの末尾トークンを数値として解釈する方式にする
    /// - 自己株式消却による減少は「△」表記（例: 日立・ソフトバンクG）
    /// - 表に現れない期末後の増減（例: 日立の注記6「2023年５月31日付で新株発行」）は脚注の
    ///   自由記述にしかなく構造化抽出の対象外（決議日/表記載基準のみ、他note_typeと同様の割り切り）
    ///
    /// 表が無くてもタグ期末が取れれば resolved（summary 床用）。両方無ければ notApplicable。
    static func resolveIssuedSharesAndCapital(xbrlDir: URL) -> StatementNoteResolveResult {
        let allTagElements = XBRLUtils.collectAllNumericElements(in: xbrlDir, nilAsZero: false)
        let durationFS = fieldSetFromDuration(allTagElements)
        let issuedShares = PerShareExtractor.extract(
            durationFS: durationFS, tagElements: allTagElements).issuedShares
        let capitalStock = resolveCurrentInstantFact(allTagElements, tags: Xbrl.capitalStockTags)
        let capitalReserve = resolveCurrentInstantFact(allTagElements, tags: Xbrl.capitalReserveTags)
        let asOf: IssuedSharesAsOfPayload?
        if issuedShares != nil || capitalStock != nil || capitalReserve != nil {
            asOf = IssuedSharesAsOfPayload(
                issuedShares: issuedShares, capitalStock: capitalStock, capitalReserve: capitalReserve)
        } else {
            asOf = nil
        }
        let events = parseIssuedSharesTable(xbrlDir: xbrlDir)

        guard asOf != nil || !(events ?? []).isEmpty else {
            return .notApplicable(reason: statementNoteNotApplicableNotFound)
        }
        let eventHash = (events ?? []).map {
            "\($0.date):\($0.sharesDelta ?? -1):\($0.sharesBalance ?? -1)"
        }.joined(separator: ";")
        let asOfHash = [
            "s=\(issuedShares.map { String($0) } ?? "-")",
            "c=\(capitalStock.map { String($0) } ?? "-")",
            "r=\(capitalReserve.map { String($0) } ?? "-")",
        ].joined(separator: ",")
        return .resolved(
            payload: StatementNotePayload(
                issuedSharesEvents: events.flatMap { $0.isEmpty ? nil : $0 },
                issuedSharesAsOf: asOf),
            source: statementNoteSourceXbrlFacts,
            contentHash: "asOf{\(asOfHash)}|events{\(eventHash)}")
    }

    /// 期末 Instant の離散 fact。連結 `CurrentYearInstant` を優先し、無ければ
    /// `CurrentYearInstant_NonConsolidatedMember`（資本金・資本準備金は親会社科目が多い）、
    /// さらに `CurrentYearInstant*` を辞書順で拾う。
    private static func resolveCurrentInstantFact(
        _ tagElements: XbrlTagElements, tags: [String]
    ) -> Double? {
        let preferred = [
            Xbrl.currentYearInstantContext,
            "\(Xbrl.currentYearInstantContext)_NonConsolidatedMember",
            Xbrl.filingDateInstantContext,
        ]
        for tag in tags {
            guard let ctxs = tagElements[tag] else { continue }
            for key in preferred {
                if let v = ctxs[key] { return v }
            }
            for key in ctxs.keys.sorted() where key.contains(Xbrl.currentYearInstantContext) {
                return ctxs[key]
            }
        }
        return nil
    }

    /// セルのテキストが金額欄（数値または「－」）として解釈できるか。ラベル文字列（日付・
    /// 「（注）」等）は対象外。
    private static func isIssuedSharesAmountToken(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if ["－", "-", "—", "―"].contains(trimmed) { return true }
        return issuedSharesAmountValue(text) != nil
    }

    /// 金額欄の値。「－」は nil（実変動なし）。メルカリのように「普通株式 2,840,500」のような
    /// ラベル＋数値の複合セルは、空白区切りの末尾トークンを数値として解釈する。
    private static func issuedSharesAmountValue(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let v = XBRLUtils.parseTextblockCellValue(trimmed) { return v }
        if ["－", "-", "—", "―"].contains(trimmed) { return nil }
        guard let lastToken = trimmed.split(separator: " ").last else { return nil }
        return XBRLUtils.parseTextblockCellValue(String(lastToken))
    }

    private static func parseIssuedSharesTable(xbrlDir: URL) -> [IssuedSharesEventPayload]? {
        guard let html = XBRLUtils.extractTextblockHtml(
            in: xbrlDir, textblockTag: "ChangesInNumberOfIssuedSharesStatedCapitalEtcTextBlock"),
            let soup = try? SwiftSoup.parse(html),
            let tables = (try? soup.select("table"))?.array()
        else { return nil }

        for table in tables {
            let rows = gridRows(from: table)
            var sharesScale = 1.0
            var yenScale = 1.0
            var events: [IssuedSharesEventPayload] = []
            for cols in rows {
                guard !cols.isEmpty else { continue }
                let joined = cols.joined(separator: " ")
                if joined.contains("千株") { sharesScale = 1000 }
                if joined.contains("百万円") { yenScale = 1_000_000 } else if joined.contains("千円") {
                    yenScale = 1000
                }

                let amountTokens = cols.filter { isIssuedSharesAmountToken($0) }
                guard amountTokens.count >= 2 else { continue }
                let sharesDelta = issuedSharesAmountValue(amountTokens[0])
                let sharesBalance = issuedSharesAmountValue(amountTokens[1])
                let capitalDelta = amountTokens.count > 2 ? issuedSharesAmountValue(amountTokens[2]) : nil
                let capitalBalance = amountTokens.count > 3 ? issuedSharesAmountValue(amountTokens[3]) : nil
                let reserveDelta = amountTokens.count > 4 ? issuedSharesAmountValue(amountTokens[4]) : nil
                let reserveBalance = amountTokens.count > 5 ? issuedSharesAmountValue(amountTokens[5]) : nil
                // 3つの増減欄がすべて「－」＝実変動なしの参考行（日立の期間ラベル行等）は除外。
                // いずれか1つでも実数があれば採用する（JT・横河電機のように株数は動かず資本準備金
                // だけ動く行を取りこぼさないため）。
                guard sharesDelta != nil || capitalDelta != nil || reserveDelta != nil else { continue }

                let date = cols[0].trimmingCharacters(in: .whitespaces)
                events.append(
                    IssuedSharesEventPayload(
                        date: date, sharesDelta: sharesDelta.map { $0 * sharesScale },
                        sharesBalance: sharesBalance.map { $0 * sharesScale },
                        capitalDelta: capitalDelta.map { $0 * yenScale },
                        capitalBalance: capitalBalance.map { $0 * yenScale },
                        capitalReserveDelta: reserveDelta.map { $0 * yenScale },
                        capitalReserveBalance: reserveBalance.map { $0 * yenScale }))
            }
            if !events.isEmpty { return events }
        }
        return nil
    }

    /// `<table>` の各 `<tr>` を `rowspan`/`colspan` を展開した仮想グリッド（列固定・欠損セルなし）
    /// へ変換する。`colspan` は結合された各列へ同じテキストを複製する（実データ検証: ニチレイ
    /// S100VYA0 の設備投資表はヘッダーの「前/当連結会計年度」が colspan=2 で空白の整形列を
    /// またぐため、展開しないとヘッダー文言とデータ列の位置が対応しない）。
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
                let colspan = Int((try? td.attr("colspan")) ?? "") ?? 1
                for _ in 0..<colspan {
                    cols.append(text)
                    if rowspan > 1 { pending[col] = (text, rowspan - 1) }
                    col += 1
                }
                cellIdx += 1
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
