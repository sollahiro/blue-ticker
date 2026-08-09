// 実 EDINET XBRL キャッシュ（analysis_cache）での Statement 取り込み Statement 抽出の golden 回帰テスト。
//
// 対象（2026-07-31 実データ検証で確定した値）:
// - 7203 トヨタ自動車 S100VWVY（IFRS連結、2025-03期）
// - 6902 デンソー S100VWHL（IFRS連結、2025-03期。デンソーは `LiabilitiesIFRS` の直接の親が
//   負債・純資産を束ねる `LiabilitiesAndEquityIFRSAbstract` であり、区分判定バグの回帰対象）
// - 7974 任天堂 S100W73A（J-GAAP連結、2025-03期）
//
// 2026-08-09、smoke（`smoke/smoke_expected/*.json`、SmokeTests.swift）が対象とする固定11社
// セットのうち US-GAAP2社を除く9社**全件**を、statement 側の床として追加（AGENTS.md「テスト」節・
// docs/test-spec-assets.md「既知のギャップ」参照。SmokeTests.swift 自体は Extractors.swift 経由の
// 抽出器のみを検証しており StatementAnalyzer は通らないため、床を広げるにはここへ追加する）。
// 追加した9社は「同一区分内で他行の components からも参照されていない isTotal 行」（＝各区分の
// 最上位合計）を構造的に特定した上で、smoke_expected の既存 golden 値（total_assets/net_assets/
// sales/cfo/cfi）と突合して一致を確認済み（2026-08-09）:
// - 2802 味の素 S100VXJA（IFRS連結、2025-03期）
// - 2871 ニチレイ S100VYA0（J-GAAP連結、2025-03期）
// - 3490 AZplanning S100VU4O（J-GAAP連結、2025-02期、小規模企業）
// - 6103 オークマ S100W043（J-GAAP連結、2025-03期）
// - 6326 クボタ S100XR0M（IFRS連結、2025-12期）
// - 7269 スズキ S100W4MT（IFRS連結、2025-03期）
// - 7422 東邦レマック S100XRD8（J-GAAP連結、2025-12-20期。小規模企業・決算期末が月中）
// - 8306 三菱UFJフィナンシャル・グループ S100W4FB（J-GAAP連結・銀行、2025-03期。流動/非流動の
//   区分を持たない銀行特有のBS構造の回帰対象）
// - 8316 三井住友フィナンシャルグループ S100W0S7（J-GAAP連結・銀行、2025-03期）
// smoke の US-GAAP2社（4901 富士フイルム S100W3XJ、7751 キヤノン S100XTLJ）は下記
// 「US-GAAP（明示 notApplicable）」で別途カバー済み。
//
// smoke 由来の9社は `ensureAvailable`（`BLT_EDINET_API_KEY` があれば自動取得）で、
// Toyota/Denso/Nintendo 他の既存分は `.enabled(if:)` で自動 SKIP（`swift test` は鍵なしでも緑）。
// ラベルの標準タクソノミ補完（`assets/taxonomy`、git 管理外）が無い環境でもここで検証する
// 数値・区分・is_total/components は独立して成立する（ラベル解決率自体はここでは検証しない）。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct RealXbrlStatementTests {
    private static let xbrlRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl")
    }()

    private static func cacheAvailable(_ docID: String) -> Bool {
        FileManager.default.fileExists(atPath: xbrlRoot.appendingPathComponent("\(docID)_xbrl").path)
    }

    /// `BLT_EDINET_API_KEY` があれば不足キャッシュを取得し、それでも無ければ SKIP する
    /// （`RealXbrlBreakdownTests.swift` と同型。smoke 由来の企業セットで採用し、CI・新規
    /// checkout でもキャッシュ未取得のまま無条件 SKIP にならないようにする）。
    private static func ensureAvailable(_ docID: String) async -> Bool {
        await SmokeCacheSupport.ensureCached([docID], cacheDir: xbrlRoot)
        guard cacheAvailable(docID) else {
            print("SKIP   \(docID): XBRL キャッシュなし（BLT_EDINET_API_KEY 未設定または取得失敗）")
            return false
        }
        return true
    }

    private static func analyzer() -> StatementAnalyzer {
        let cacheDir = defaultUserDataPath().appendingPathComponent("analysis_cache", isDirectory: true)
        return StatementAnalyzer(edinetClient: EdinetAPIClient(cacheDir: cacheDir))
    }

    private static func requireResolved(_ result: StatementDocResolveResult) throws -> StatementYear {
        guard case .resolved(let year) = result else {
            Issue.record("expected .resolved, got \(result)")
            struct ExpectationFailed: Error {}
            throw ExpectationFailed()
        }
        return year
    }

    /// `assets/taxonomy`（EDINET 公式タクソノミ、ユーザーが配置。git 管理外）が無い環境では
    /// 標準タグのラベルは解決できない（`XBRLUtils.loadStandardTaxonomyLabels` 参照）。
    /// ラベル文言に依存するテストはこれで追加ガードし、値・区分・is_total/components の検証
    /// （taxonomy 非依存）とは環境依存性を切り分ける。
    private static var taxonomyAvailable: Bool {
        resolveAssetFileURL(filename: "taxonomy") != nil
    }

    // MARK: - トヨタ自動車 S100VWVY

    @Test(.enabled(if: cacheAvailable("S100VWVY"), "XBRL cache S100VWVY not available"))
    func toyotaBalanceSheetTotalsMatchPublicFiguresWithCalculationComponents() async throws {
        let year = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100VWVY", statementTypes: [.balanceSheet]))
        let byTag = Dictionary(uniqueKeysWithValues: year.balanceSheet.map { ($0.tag, $0) })

        // 公表値と一致（2026-07-30 実データ検証済み）。
        #expect(byTag["AssetsIFRS"]?.value == 93_601_350_000_000)
        #expect(byTag["LiabilitiesIFRS"]?.value == 56_722_437_000_000)
        #expect(byTag["EquityIFRS"]?.value == 36_878_913_000_000)

        // 区分（presentation linkbase 祖先由来）。
        #expect(byTag["AssetsIFRS"]?.section == .assets)
        #expect(byTag["LiabilitiesIFRS"]?.section == .liabilities)
        #expect(byTag["EquityIFRS"]?.section == .netAssets)
        // 複数区分にまたがるグランドトータルは section=nil のまま。
        #expect(byTag["LiabilitiesAndEquityIFRS"]?.section == nil)

        // 合計行の構成要素（計算リンクベース由来）。
        #expect(byTag["AssetsIFRS"]?.isTotal == true)
        #expect(
            Set(byTag["AssetsIFRS"]?.components?.map(\.tag) ?? [])
                == ["CurrentAssetsIFRS", "NonCurrentAssetsIFRS"])
        // section が nil のグランドトータルでも is_total/components は独立して取得できる。
        #expect(byTag["LiabilitiesAndEquityIFRS"]?.isTotal == true)
        #expect(
            Set(byTag["LiabilitiesAndEquityIFRS"]?.components?.map(\.tag) ?? [])
                == ["LiabilitiesIFRS", "EquityIFRS"])
    }

    @Test(.enabled(if: cacheAvailable("S100VWVY"), "XBRL cache S100VWVY not available"))
    func toyotaIncomeStatementMatchesPublicFigures() async throws {
        let year = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100VWVY", statementTypes: [.incomeStatement]))
        let byTag = Dictionary(uniqueKeysWithValues: year.incomeStatement.map { ($0.tag, $0) })

        #expect(byTag["TotalNetRevenuesIFRS"]?.value == 48_036_704_000_000)
        #expect(byTag["ProfitLossAttributableToOwnersOfParentIFRS"]?.value == 4_765_086_000_000)
        // 損益計算書には section を付けない（2026-07-30 合意）。
        #expect(byTag["TotalNetRevenuesIFRS"]?.section == nil)
        // 控除項目は weight=-1（例: 売上原価並びに販管費合計 = 売上原価 + 金融費用 + 販管費）。
        #expect(byTag["OperatingProfitLossIFRS"]?.isTotal == true)
    }

    @Test(.enabled(if: cacheAvailable("S100VWVY"), "XBRL cache S100VWVY not available"))
    func toyotaCashFlowIncludesDistinctPeriodStartAndEndCashReconciliation() async throws {
        // 回帰テスト: CF の Instant/Duration 混在バグ修正（現金及び現金同等物の期首/期末残高が
        // 一時期 CF から欠落していた）と、期首/期末で異なる preferredLabel バリアントを
        // 選び直すロジックの両方を検証する。
        let year = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100VWVY", statementTypes: [.cashFlow]))
        let cashRows = year.cashFlow.filter { $0.tag == "CashAndCashEquivalentsIFRS" }

        #expect(cashRows.count == 2)
        #expect(Set(cashRows.map(\.value)) == [8_982_404_000_000, 9_412_060_000_000])
        // 期首・期末で異なるラベルが選ばれ、同じラベルに収束していない。
        #expect(Set(cashRows.compactMap(\.label)).count == 2)

        // 回帰テスト: 出力順が実行のたびに入れ替わらないこと（Opus 監査で発見・修正、
        // 2026-07-31。期首/期末残高は同一タグ・同一 order のため、fact の contextRef を
        // 決定的なタイブレークキーに使う前は入力の走査順に依存していた）。
        let secondRun = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100VWVY", statementTypes: [.cashFlow]))
        let secondCashRows = secondRun.cashFlow.filter { $0.tag == "CashAndCashEquivalentsIFRS" }
        #expect(cashRows.map(\.value) == secondCashRows.map(\.value))
    }

    @Test(.enabled(if: cacheAvailable("S100VWVY"), "XBRL cache S100VWVY not available"))
    func toyotaChangesInEquityTotalsMatchPublicFiguresWithOpeningClosingBalances() async throws {
        // 持分変動計算書（SS）: 合計列のみ。自己株式の取得・包括利益・資本の期首/期末残高。
        // 実データ検証: トヨタ7203 S100VWVY（2026-08-09）。
        let year = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100VWVY", statementTypes: [.changesInEquity]))
        #expect(!year.changesInEquity.isEmpty)

        let byTag = Dictionary(
            year.changesInEquity.map { ($0.tag, $0) },
            uniquingKeysWith: { first, _ in first })
        // Dictionary uniquing keeps first; EquityIFRS は期首/期末の2行あるので filter で取る。
        let equityRows = year.changesInEquity.filter { $0.tag == "EquityIFRS" }
        #expect(equityRows.count == 2)
        #expect(Set(equityRows.map(\.value)) == [35_239_338_000_000, 36_878_913_000_000])
        // 期首・期末で異なるラベル（taxonomy が無い環境では label が nil になりうるため値で担保）。
        #expect(equityRows.map(\.section) == [nil, nil])

        #expect(byTag["PurchaseOfTreasurySharesSSIFRS"]?.value == -1_179_043_000_000)
        #expect(byTag["ComprehensiveIncomeIFRS"]?.value == 4_043_724_000_000)
        // SS 行には section を付けない（PL と同型）。
        #expect(byTag["PurchaseOfTreasurySharesSSIFRS"]?.section == nil)

        // 出力順の決定性（同一タグの期首/期末）。
        let second = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100VWVY", statementTypes: [.changesInEquity]))
        #expect(
            year.changesInEquity.map(\.value) == second.changesInEquity.map(\.value))
        #expect(year.changesInEquity.map(\.tag) == second.changesInEquity.map(\.tag))
    }

    @Test(
        .enabled(if: cacheAvailable("S100VWVY"), "XBRL cache S100VWVY not available"),
        .enabled(if: taxonomyAvailable, "assets/taxonomy not available")
    )
    func toyotaBalanceSheetTotalRowsUseTotalLabelNotPeriodEndLabel() async throws {
        // 回帰テスト（Opus 監査で発見・修正、2026-07-31）: BS の合計行が標準タクソノミの
        // periodEndLabel を持つ場合（`EquityIFRS` 等）、期首/期末残高の区別ロジックが CF に
        // 限定されていなかったため `preferredLabel=totalLabel`（「資本合計」）が無視され
        // 常に「期末残高」になっていた（キャッシュ済み実XBRL 140件中136件で発生）。
        let year = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100VWVY", statementTypes: [.balanceSheet]))
        let byTag = Dictionary(uniqueKeysWithValues: year.balanceSheet.map { ($0.tag, $0) })

        #expect(byTag["EquityIFRS"]?.label == "資本合計")
        #expect(byTag["EquityIFRS"]?.label?.contains("残高") == false)
    }

    // MARK: - デンソー S100VWHL

    @Test(.enabled(if: cacheAvailable("S100VWHL"), "XBRL cache S100VWHL not available"))
    func densoLiabilitiesTotalIsClassifiedAsLiabilitiesDespiteAmbiguousParentHeader() async throws {
        // 回帰テスト: `LiabilitiesIFRS` の直接の親 `LiabilitiesAndEquityIFRSAbstract` は
        // 負債・純資産両方のキーワードに一致し曖昧なため、優先順位だけで確定させると
        // 誤って純資産に分類されていた（2026-07-30 発見・修正）。
        let year = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100VWHL", statementTypes: [.balanceSheet]))
        let byTag = Dictionary(uniqueKeysWithValues: year.balanceSheet.map { ($0.tag, $0) })

        #expect(byTag["LiabilitiesIFRS"]?.value == 2_936_082_000_000)
        #expect(byTag["LiabilitiesIFRS"]?.section == .liabilities)
        #expect(byTag["AssetsIFRS"]?.value == 8_125_000_000_000)

        // 回帰テスト: 上記修正の副作用として、無関係な部分文字列（"EquityMethod" の "Equity"、
        // "AssetsHeldForSale" の "Asset"）を含む明細タグが誤分類されないことも確認する。
        #expect(byTag["InvestmentsAccountedForUsingEquityMethodIFRS"]?.section == .assets)
        #expect(byTag["OtherComprehensiveIncomeRelatedToAssetsHeldForSaleIFRS"]?.section == .netAssets)
    }

    @Test(.enabled(if: cacheAvailable("S100VWHL"), "XBRL cache S100VWHL not available"))
    func densoIncomeStatementMatchesPublicFigures() async throws {
        let year = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100VWHL", statementTypes: [.incomeStatement]))
        let byTag = Dictionary(uniqueKeysWithValues: year.incomeStatement.map { ($0.tag, $0) })

        // issue #157 記載値・公表値と一致。
        #expect(byTag["RevenueIFRS"]?.value == 7_161_777_000_000)
        #expect(byTag["ProfitLossAttributableToOwnersOfParentIFRS"]?.value == 419_081_000_000)
    }

    // MARK: - 任天堂 S100W73A

    @Test(.enabled(if: cacheAvailable("S100W73A"), "XBRL cache S100W73A not available"))
    func nintendoBalanceSheetTotalsChainThroughMultipleLevels() async throws {
        // 回帰テスト: 明細→小計→中計→総合計の多段階の積み上げが計算リンクベース経由で
        // 正しく連鎖することを確認する（J-GAAP、IFRS とはタグ体系が異なる）。
        let year = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100W73A", statementTypes: [.balanceSheet]))
        let byTag = Dictionary(uniqueKeysWithValues: year.balanceSheet.map { ($0.tag, $0) })

        #expect(byTag["Assets"]?.value == 3_398_515_000_000)
        #expect(Set(byTag["Assets"]?.components?.map(\.tag) ?? []) == ["CurrentAssets", "NoncurrentAssets"])
        #expect(
            Set(byTag["NoncurrentAssets"]?.components?.map(\.tag) ?? [])
                == ["PropertyPlantAndEquipment", "IntangibleAssets", "InvestmentsAndOtherAssets"])

        // 複数区分にまたがるグランドトータルも is_total/components は独立して取得できる。
        #expect(byTag["LiabilitiesAndNetAssets"]?.section == nil)
        #expect(byTag["LiabilitiesAndNetAssets"]?.isTotal == true)
        #expect(
            Set(byTag["LiabilitiesAndNetAssets"]?.components?.map(\.tag) ?? [])
                == ["Liabilities", "NetAssets"])
    }

    @Test(
        .enabled(if: cacheAvailable("S100W73A"), "XBRL cache S100W73A not available"),
        .enabled(if: taxonomyAvailable, "assets/taxonomy not available")
    )
    func nintendoValuationAndTranslationAdjustmentsUsesTotalLabelVariant() async throws {
        // 回帰テスト: `preferredLabel=totalLabel` により通常ラベル「評価・換算差額等」ではなく
        // 合計ラベル（「…合計」）を使うべきケース。標準タグのラベル解決は `assets/taxonomy`
        // （git 管理外）が無い環境では成立しないため、値/区分/is_total とは別テストに分離する。
        let year = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100W73A", statementTypes: [.balanceSheet]))
        let byTag = Dictionary(uniqueKeysWithValues: year.balanceSheet.map { ($0.tag, $0) })
        #expect(byTag["ValuationAndTranslationAdjustments"]?.label?.contains("合計") == true)
    }

    @Test(.enabled(if: cacheAvailable("S100W73A"), "XBRL cache S100W73A not available"))
    func nintendoIncomeStatementMatchesPublicFigures() async throws {
        let year = try Self.requireResolved(
            await Self.analyzer().extract(docID: "S100W73A", statementTypes: [.incomeStatement]))
        let byTag = Dictionary(uniqueKeysWithValues: year.incomeStatement.map { ($0.tag, $0) })

        #expect(byTag["NetSales"]?.value == 1_164_922_000_000)
        #expect(byTag["ProfitLossAttributableToOwnersOfParent"]?.value == 278_806_000_000)
    }

    // MARK: - smoke 企業セット（US-GAAP除く7社、床の拡張。2026-08-09）

    /// 同一 section 内で他行の components からも参照されていない isTotal 行 = その区分の
    /// 最上位合計（根）。参照元を同一 section 内に限定するのは、複数区分を跨ぐグランドトータル
    /// （section=nil、例: LiabilitiesAndNetAssets）が Liabilities/NetAssets を参照することで
    /// 区分内の本来の root が誤って「参照済み」判定されるのを防ぐため。
    private static func rootTotal(_ items: [StatementLineItem], section: StatementLineSection) -> StatementLineItem? {
        let inSection = items.filter { $0.section == section }
        let referenced = Set(inSection.compactMap(\.components).flatMap { $0.map(\.tag) })
        let roots = inSection.filter { $0.isTotal && !referenced.contains($0.tag) }
        return roots.count == 1 ? roots.first : nil
    }

    /// 貸借対照表の会計等式（資産=負債+純資産）。上記 `rootTotal` で3行を抽出結果から
    /// 実行時に構造的に特定して検証する（固定タグ名を再掲するだけの重複チェックにしない）。
    /// 開示側の百万円/千円丸めにより厳密には一致しない場合があるため、絶対誤差2,000,000円まで
    /// は許容する（実データ検証: 7社中の最大の乖離は1,000,000円）。
    private static func expectBalanceSheetIdentity(_ balanceSheet: [StatementLineItem]) {
        guard let assets = rootTotal(balanceSheet, section: .assets),
            let liabilities = rootTotal(balanceSheet, section: .liabilities),
            let netAssets = rootTotal(balanceSheet, section: .netAssets)
        else {
            Issue.record("could not structurally locate assets/liabilities/netAssets root totals")
            return
        }
        #expect(abs(assets.value - (liabilities.value + netAssets.value)) <= 2_000_000)
    }

    // MARK: - 味の素 S100VXJA

    @Test
    func ajinomotoStatementMatchesSmokeFixture() async throws {
        guard await Self.ensureAvailable("S100VXJA") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(
                docID: "S100VXJA", statementTypes: [.balanceSheet, .incomeStatement, .cashFlow]))
        let bsByTag = Dictionary(uniqueKeysWithValues: year.balanceSheet.map { ($0.tag, $0) })

        #expect(bsByTag["AssetsIFRS"]?.value == 1_721_131_000_000)
        #expect(bsByTag["LiabilitiesIFRS"]?.value == 907_858_000_000)
        #expect(bsByTag["EquityIFRS"]?.value == 813_273_000_000)
        #expect(bsByTag["AssetsIFRS"]?.section == .assets)
        #expect(bsByTag["LiabilitiesIFRS"]?.section == .liabilities)
        #expect(bsByTag["EquityIFRS"]?.section == .netAssets)
        Self.expectBalanceSheetIdentity(year.balanceSheet)

        #expect(year.incomeStatement.first { $0.tag == "NetSalesIFRS" }?.value == 1_530_556_000_000)

        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInOperatingActivitiesIFRS" })?.value == 209_898_000_000)
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInOperatingActivitiesIFRS" })?.section == .operating)
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInInvestingActivitiesIFRS" })?.value == -77_382_000_000)
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInInvestingActivitiesIFRS" })?.section == .investing)
    }

    // MARK: - ニチレイ S100VYA0

    @Test
    func nichireiStatementMatchesSmokeFixture() async throws {
        guard await Self.ensureAvailable("S100VYA0") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(
                docID: "S100VYA0", statementTypes: [.balanceSheet, .incomeStatement, .cashFlow]))
        let bsByTag = Dictionary(uniqueKeysWithValues: year.balanceSheet.map { ($0.tag, $0) })

        #expect(bsByTag["Assets"]?.value == 499_221_000_000)
        #expect(bsByTag["Liabilities"]?.value == 223_255_000_000)
        #expect(bsByTag["NetAssets"]?.value == 275_966_000_000)
        #expect(bsByTag["Assets"]?.section == .assets)
        #expect(bsByTag["Liabilities"]?.section == .liabilities)
        #expect(bsByTag["NetAssets"]?.section == .netAssets)
        Self.expectBalanceSheetIdentity(year.balanceSheet)

        #expect(year.incomeStatement.first { $0.tag == "NetSales" }?.value == 702_080_000_000)

        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInOperatingActivities" })?.value == 53_194_000_000)
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInOperatingActivities" })?.section == .operating)
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInInvestmentActivities" })?.value == -32_403_000_000)
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInInvestmentActivities" })?.section == .investing)
    }

    // MARK: - AZplanning S100VU4O（小規模企業。純資産合計の構成要素が株主資本のみの単純ケース）

    @Test
    func azPlanningStatementMatchesSmokeFixture() async throws {
        guard await Self.ensureAvailable("S100VU4O") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(
                docID: "S100VU4O", statementTypes: [.balanceSheet, .incomeStatement, .cashFlow]))
        let bsByTag = Dictionary(uniqueKeysWithValues: year.balanceSheet.map { ($0.tag, $0) })

        #expect(bsByTag["Assets"]?.value == 13_239_919_000)
        #expect(bsByTag["Liabilities"]?.value == 10_281_752_000)
        #expect(bsByTag["NetAssets"]?.value == 2_958_166_000)
        #expect(bsByTag["Assets"]?.section == .assets)
        #expect(bsByTag["Liabilities"]?.section == .liabilities)
        #expect(bsByTag["NetAssets"]?.section == .netAssets)
        #expect(Set(bsByTag["NetAssets"]?.components?.map(\.tag) ?? []) == ["ShareholdersEquity"])
        Self.expectBalanceSheetIdentity(year.balanceSheet)

        #expect(year.incomeStatement.first { $0.tag == "NetSales" }?.value == 12_430_301_000)

        // 回帰対象: CFO がマイナスの小規模企業ケース。
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInOperatingActivities" })?.value == -2_014_514_000)
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInOperatingActivities" })?.section == .operating)
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInInvestmentActivities" })?.value == -68_814_000)
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInInvestmentActivities" })?.section == .investing)
    }

    // MARK: - オークマ S100W043

    @Test
    func okumaStatementMatchesSmokeFixture() async throws {
        guard await Self.ensureAvailable("S100W043") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(
                docID: "S100W043", statementTypes: [.balanceSheet, .incomeStatement, .cashFlow]))
        let bsByTag = Dictionary(uniqueKeysWithValues: year.balanceSheet.map { ($0.tag, $0) })

        #expect(bsByTag["Assets"]?.value == 298_168_000_000)
        #expect(bsByTag["Liabilities"]?.value == 60_103_000_000)
        #expect(bsByTag["NetAssets"]?.value == 238_065_000_000)
        #expect(bsByTag["Assets"]?.section == .assets)
        #expect(bsByTag["Liabilities"]?.section == .liabilities)
        #expect(bsByTag["NetAssets"]?.section == .netAssets)
        Self.expectBalanceSheetIdentity(year.balanceSheet)

        #expect(year.incomeStatement.first { $0.tag == "NetSales" }?.value == 206_822_000_000)

        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInOperatingActivities" })?.value == 17_802_000_000)
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInInvestmentActivities" })?.value == -15_257_000_000)
    }

    // MARK: - クボタ S100XR0M

    @Test
    func kubotaStatementMatchesSmokeFixture() async throws {
        guard await Self.ensureAvailable("S100XR0M") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(
                docID: "S100XR0M", statementTypes: [.balanceSheet, .incomeStatement, .cashFlow]))
        let bsByTag = Dictionary(uniqueKeysWithValues: year.balanceSheet.map { ($0.tag, $0) })

        #expect(bsByTag["AssetsIFRS"]?.value == 6_204_909_000_000)
        #expect(bsByTag["LiabilitiesIFRS"]?.value == 3_331_885_000_000)
        #expect(bsByTag["EquityIFRS"]?.value == 2_873_024_000_000)
        #expect(bsByTag["AssetsIFRS"]?.section == .assets)
        #expect(bsByTag["LiabilitiesIFRS"]?.section == .liabilities)
        #expect(bsByTag["EquityIFRS"]?.section == .netAssets)
        Self.expectBalanceSheetIdentity(year.balanceSheet)

        #expect(year.incomeStatement.first { $0.tag == "NetSalesIFRS" }?.value == 3_018_891_000_000)

        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInOperatingActivitiesIFRS" })?.value == 327_901_000_000)
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInInvestingActivitiesIFRS" })?.value == -163_726_000_000)
    }

    // MARK: - スズキ S100W4MT

    @Test
    func suzukiStatementMatchesSmokeFixture() async throws {
        guard await Self.ensureAvailable("S100W4MT") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(
                docID: "S100W4MT", statementTypes: [.balanceSheet, .incomeStatement, .cashFlow]))
        let bsByTag = Dictionary(uniqueKeysWithValues: year.balanceSheet.map { ($0.tag, $0) })

        #expect(bsByTag["AssetsIFRS"]?.value == 5_993_657_000_000)
        #expect(bsByTag["LiabilitiesIFRS"]?.value == 2_305_586_000_000)
        #expect(bsByTag["EquityIFRS"]?.value == 3_688_070_000_000)
        #expect(bsByTag["AssetsIFRS"]?.section == .assets)
        #expect(bsByTag["LiabilitiesIFRS"]?.section == .liabilities)
        #expect(bsByTag["EquityIFRS"]?.section == .netAssets)
        Self.expectBalanceSheetIdentity(year.balanceSheet)

        #expect(year.incomeStatement.first { $0.tag == "RevenueIFRS" }?.value == 5_825_161_000_000)

        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInOperatingActivitiesIFRS" })?.value == 669_784_000_000)
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInInvestingActivitiesIFRS" })?.value == -475_605_000_000)
    }

    // MARK: - 東邦レマック S100XRD8（小規模企業・決算期末が月中）

    @Test
    func tohoRemacStatementMatchesSmokeFixture() async throws {
        guard await Self.ensureAvailable("S100XRD8") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(
                docID: "S100XRD8", statementTypes: [.balanceSheet, .incomeStatement, .cashFlow]))
        let bsByTag = Dictionary(uniqueKeysWithValues: year.balanceSheet.map { ($0.tag, $0) })

        #expect(bsByTag["Assets"]?.value == 6_705_070_000)
        #expect(bsByTag["Liabilities"]?.value == 2_183_375_000)
        #expect(bsByTag["NetAssets"]?.value == 4_521_695_000)
        #expect(bsByTag["Assets"]?.section == .assets)
        #expect(bsByTag["Liabilities"]?.section == .liabilities)
        #expect(bsByTag["NetAssets"]?.section == .netAssets)
        Self.expectBalanceSheetIdentity(year.balanceSheet)

        #expect(year.incomeStatement.first { $0.tag == "NetSales" }?.value == 4_547_599_000)

        // 回帰対象: CFO/CFI ともにマイナスの小規模企業ケース。
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInOperatingActivities" })?.value == -482_098_000)
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInInvestmentActivities" })?.value == -306_697_000)
    }

    // MARK: - 三菱UFJフィナンシャル・グループ S100W4FB（銀行。流動/非流動の区分を持たないBS構造）

    @Test
    func mufgStatementMatchesSmokeFixture() async throws {
        guard await Self.ensureAvailable("S100W4FB") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(
                docID: "S100W4FB", statementTypes: [.balanceSheet, .incomeStatement, .cashFlow]))
        let bsByTag = Dictionary(uniqueKeysWithValues: year.balanceSheet.map { ($0.tag, $0) })

        #expect(bsByTag["Assets"]?.value == 413_113_501_000_000)
        #expect(bsByTag["Liabilities"]?.value == 391_385_368_000_000)
        #expect(bsByTag["NetAssets"]?.value == 21_728_132_000_000)
        // 回帰対象: 流動/非流動の区分を持たない銀行特有のBS構造でも section 判定が正しいこと。
        #expect(bsByTag["Assets"]?.section == .assets)
        #expect(bsByTag["Liabilities"]?.section == .liabilities)
        #expect(bsByTag["NetAssets"]?.section == .netAssets)
        #expect(
            Set(bsByTag["NetAssets"]?.components?.map(\.tag) ?? [])
                == ["ShareholdersEquity", "ValuationAndTranslationAdjustments", "SubscriptionRightsToShares", "NonControllingInterests"])
        Self.expectBalanceSheetIdentity(year.balanceSheet)

        // 銀行は「売上高」の代わりに経常収益（OrdinaryIncomeBNK）が損益計算書内で最大値の行になる。
        #expect(year.incomeStatement.first { $0.tag == "OrdinaryIncomeBNK" }?.value == 13_629_997_000_000)
        #expect(year.incomeStatement.first { $0.tag == "OrdinaryIncomeBNK" }?.isTotal == true)

        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInOperatingActivities" })?.value == 6_415_000_000)
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInInvestmentActivities" })?.value == -186_948_000_000)
    }

    // MARK: - 三井住友フィナンシャルグループ S100W0S7（銀行）

    @Test
    func smfgStatementMatchesSmokeFixture() async throws {
        guard await Self.ensureAvailable("S100W0S7") else { return }
        let year = try Self.requireResolved(
            await Self.analyzer().extract(
                docID: "S100W0S7", statementTypes: [.balanceSheet, .incomeStatement, .cashFlow]))
        let bsByTag = Dictionary(uniqueKeysWithValues: year.balanceSheet.map { ($0.tag, $0) })

        #expect(bsByTag["Assets"]?.value == 306_282_015_000_000)
        #expect(bsByTag["Liabilities"]?.value == 291_440_506_000_000)
        #expect(bsByTag["NetAssets"]?.value == 14_841_509_000_000)
        #expect(bsByTag["Assets"]?.section == .assets)
        #expect(bsByTag["Liabilities"]?.section == .liabilities)
        #expect(bsByTag["NetAssets"]?.section == .netAssets)
        #expect(
            Set(bsByTag["NetAssets"]?.components?.map(\.tag) ?? [])
                == ["ShareholdersEquity", "ValuationAndTranslationAdjustments", "SubscriptionRightsToShares", "NonControllingInterests"])
        Self.expectBalanceSheetIdentity(year.balanceSheet)

        #expect(year.incomeStatement.first { $0.tag == "OrdinaryIncomeBNK" }?.value == 10_174_894_000_000)

        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInOperatingActivities" })?.value == 4_848_464_000_000)
        #expect(year.cashFlow.first(where: { $0.tag == "NetCashProvidedByUsedInInvestmentActivities" })?.value == -4_512_943_000_000)
    }

    // MARK: - US-GAAP（明示 notApplicable）

    @Test(.enabled(if: cacheAvailable("S100W3XJ"), "XBRL cache S100W3XJ not available"))
    func fujifilmUSGAAPStatementIsNotApplicable() async {
        let result = await Self.analyzer().extract(
            docID: "S100W3XJ", statementTypes: [.balanceSheet, .incomeStatement, .cashFlow])
        guard case .notApplicable(let reason) = result else {
            Issue.record("expected .notApplicable(us_gaap_unsupported), got \(result)")
            return
        }
        #expect(reason == statementNotApplicableUSGAAP)
    }

    @Test(.enabled(if: cacheAvailable("S100XTLJ"), "XBRL cache S100XTLJ not available"))
    func canonUSGAAPStatementIsNotApplicable() async {
        let result = await Self.analyzer().extract(
            docID: "S100XTLJ", statementTypes: [.balanceSheet])
        guard case .notApplicable(let reason) = result else {
            Issue.record("expected .notApplicable(us_gaap_unsupported), got \(result)")
            return
        }
        #expect(reason == statementNotApplicableUSGAAP)
    }
}
