// 実 EDINET XBRL キャッシュ（analysis_cache）での Statement 取り込み Statement 抽出の golden 回帰テスト。
//
// 対象（2026-07-31 実データ検証で確定した値）:
// - 7203 トヨタ自動車 S100VWVY（IFRS連結、2025-03期）
// - 6902 デンソー S100VWHL（IFRS連結、2025-03期。デンソーは `LiabilitiesIFRS` の直接の親が
//   負債・純資産を束ねる `LiabilitiesAndEquityIFRSAbstract` であり、区分判定バグの回帰対象）
// - 7974 任天堂 S100W73A（J-GAAP連結、2025-03期）
//
// キャッシュが無い環境では `.enabled(if:)` で自動 SKIP（`swift test` は鍵なしでも緑）。
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

    private static func analyzer() -> StatementAnalyzer {
        let cacheDir = defaultUserDataPath().appendingPathComponent("analysis_cache", isDirectory: true)
        return StatementAnalyzer(edinetClient: EdinetAPIClient(cacheDir: cacheDir))
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
        let year = try #require(
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
        let year = try #require(
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
        let year = try #require(
            await Self.analyzer().extract(docID: "S100VWVY", statementTypes: [.cashFlow]))
        let cashRows = year.cashFlow.filter { $0.tag == "CashAndCashEquivalentsIFRS" }

        #expect(cashRows.count == 2)
        #expect(Set(cashRows.map(\.value)) == [8_982_404_000_000, 9_412_060_000_000])
        // 期首・期末で異なるラベルが選ばれ、同じラベルに収束していない。
        #expect(Set(cashRows.compactMap(\.label)).count == 2)

        // 回帰テスト: 出力順が実行のたびに入れ替わらないこと（Opus 監査で発見・修正、
        // 2026-07-31。期首/期末残高は同一タグ・同一 order のため、fact の contextRef を
        // 決定的なタイブレークキーに使う前は入力の走査順に依存していた）。
        let secondRun = try #require(
            await Self.analyzer().extract(docID: "S100VWVY", statementTypes: [.cashFlow]))
        let secondCashRows = secondRun.cashFlow.filter { $0.tag == "CashAndCashEquivalentsIFRS" }
        #expect(cashRows.map(\.value) == secondCashRows.map(\.value))
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
        let year = try #require(
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
        let year = try #require(
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
        let year = try #require(
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
        let year = try #require(
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
        let year = try #require(
            await Self.analyzer().extract(docID: "S100W73A", statementTypes: [.balanceSheet]))
        let byTag = Dictionary(uniqueKeysWithValues: year.balanceSheet.map { ($0.tag, $0) })
        #expect(byTag["ValuationAndTranslationAdjustments"]?.label?.contains("合計") == true)
    }

    @Test(.enabled(if: cacheAvailable("S100W73A"), "XBRL cache S100W73A not available"))
    func nintendoIncomeStatementMatchesPublicFigures() async throws {
        let year = try #require(
            await Self.analyzer().extract(docID: "S100W73A", statementTypes: [.incomeStatement]))
        let byTag = Dictionary(uniqueKeysWithValues: year.incomeStatement.map { ($0.tag, $0) })

        #expect(byTag["NetSales"]?.value == 1_164_922_000_000)
        #expect(byTag["ProfitLossAttributableToOwnersOfParent"]?.value == 278_806_000_000)
    }
}
