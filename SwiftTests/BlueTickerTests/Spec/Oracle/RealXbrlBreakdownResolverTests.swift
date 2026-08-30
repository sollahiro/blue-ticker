// 実 EDINET XBRL キャッシュ（analysis_cache）での内訳回帰（SPEC_ORACLE の L1 実行器）。
// 対象企業は各 @Test にハードコード。共有モックは RealXbrlBreakdownSupport.swift。
// 成功時 SKIP ログは BLT_TEST_VERBOSE=1 のときだけ（TestVerboseLog）。

import Testing
import Foundation
@testable import BlueTickerCore

@Suite struct RealXbrlBreakdownResolverTests {

    private static let xbrlRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/blue-ticker/analysis_cache/external/edinet/xbrl")
    }()

    private static func xbrlDir(_ docID: String) -> URL {
        xbrlRoot.appendingPathComponent("\(docID)_xbrl")
    }

    private static func cacheAvailable(_ docID: String) -> Bool {
        FileManager.default.fileExists(atPath: xbrlDir(docID).path)
    }

    /// `BLT_EDINET_API_KEY` があれば不足キャッシュを取得し、それでも無ければ SKIP する。
    private static func ensureAvailable(_ docID: String) async -> Bool {
        await SmokeCacheSupport.ensureCached([docID], cacheDir: xbrlRoot)
        guard cacheAvailable(docID) else {
            TestVerboseLog.print("SKIP   \(docID): XBRL キャッシュなし（BLT_EDINET_API_KEY 未設定または取得失敗）")
            return false
        }
        return true
    }

    /// 実抽出結果の当期表インデックス（タイヤ/サーマルを含む最初の当期表）。無ければ 0。
    private static func preferredTableIndex(_ tables: [BreakdownTable], containing needle: String) -> Int {
        if let i = tables.firstIndex(where: { $0.period == "当期" && $0.markdown.contains(needle) }) {
            return i
        }
        if let i = tables.firstIndex(where: { $0.markdown.contains(needle) }) {
            return i
        }
        return 0
    }

    @Test func bridgestoneResolvesViaRevenueRecognitionLLM() async throws {
        guard await Self.ensureAvailable("S100XRPR") else { return }
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100XRPR"))
        #expect(segments.tables.first?.heading == BreakdownExtractor.revenueRecognitionHeading)

        let tableIndex = Self.preferredTableIndex(segments.tables, containing: "タイヤ")
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": tableIndex,
            "period_column": "当期",
            "profit_disclosed": false,
            "rows": [
                ["label": "タイヤ", "amount": 4_146_337, "profit": NSNull(), "row_kind": "segment"],
                ["label": "その他", "amount": 283_115, "profit": NSNull(), "row_kind": "segment"],
                ["label": "外部収益 合計", "amount": 4_429_452, "profit": NSNull(), "row_kind": "subtotal"],
            ],
            "notes": "注1タイヤ＝ソリューション、注2その他＝化工品・多角化",
        ]
        let client = RealXbrlMockChat(responseJSON: response)
        let sales = 4_429_452_000_000.0

        let (snapshot, source, audit) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, client: client
        )

        #expect(source == .revenueRecognitionLLM)
        #expect(await client.schemaName() == "revenue_recognition_breakdown")
        #expect(snapshot?.axis == "business")
        let labels = Set(snapshot?.rows.map(\.labelRaw) ?? [])
        #expect(labels.contains("タイヤ"))
        #expect(labels.contains("その他"))
        #expect(audit?.notes.contains("化工品") == true || audit?.notes.contains("ソリューション") == true)
        #expect(await client.timesCalled() == 1)
    }

    @Test func densoResolvesViaRevenueRecognitionLLM() async throws {
        guard await Self.ensureAvailable("S100Y9T1") else { return }
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100Y9T1"))
        #expect(segments.tables.first?.heading == BreakdownExtractor.revenueRecognitionHeading)

        let tableIndex = Self.preferredTableIndex(segments.tables, containing: "サーマル")
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": tableIndex,
            "period_column": "当期",
            "profit_disclosed": false,
            // segment 合計が連結売上と整合するよう実額を全行入れる（分母チェック 0.90–1.10）
            "rows": [
                ["label": "サーマルシステム", "amount": 1_780_351, "profit": NSNull(), "row_kind": "segment"],
                ["label": "パワトレインシステム", "amount": 1_479_737, "profit": NSNull(), "row_kind": "segment"],
                ["label": "モビリティエレクトロニクス", "amount": 2_198_663, "profit": NSNull(), "row_kind": "segment"],
                ["label": "エレクトリフィケーションシステム", "amount": 1_433_456, "profit": NSNull(), "row_kind": "segment"],
                ["label": "先進デバイス", "amount": 390_274, "profit": NSNull(), "row_kind": "segment"],
                ["label": "その他", "amount": 108_587, "profit": NSNull(), "row_kind": "segment"],
                ["label": "非車載事業分野", "amount": 148_907, "profit": NSNull(), "row_kind": "segment"],
                ["label": "合計", "amount": 7_539_975, "profit": NSNull(), "row_kind": "subtotal"],
            ],
            "notes": "製品系統別分解表を採用",
        ]
        let client = RealXbrlMockChat(responseJSON: response)
        let sales = 7_539_975_000_000.0

        let (snapshot, source, _) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, client: client
        )

        #expect(source == .revenueRecognitionLLM)
        #expect(snapshot?.axis == "business")
        let labels = Set(snapshot?.rows.map(\.labelRaw) ?? [])
        #expect(labels.contains("サーマルシステム"))
        #expect(labels.contains("パワトレインシステム"))
        #expect(labels.contains("モビリティエレクトロニクス"))
        #expect(await client.timesCalled() == 1)
    }

    @Test func discoResolvesViaRevenueRecognitionLLM() async throws {
        guard await Self.ensureAvailable("S100YC6I") else { return }
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100YC6I"))
        #expect(segments.tables.first?.heading == BreakdownExtractor.revenueRecognitionHeading)

        let tableIndex = Self.preferredTableIndex(segments.tables, containing: "精密加工装置")
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": tableIndex,
            "period_column": "当期",
            "profit_disclosed": false,
            "rows": [
                ["label": "精密加工装置", "amount": 273_957, "profit": NSNull(), "row_kind": "segment"],
                ["label": "精密加工ツール", "amount": 94_976, "profit": NSNull(), "row_kind": "segment"],
                ["label": "その他", "amount": 67_955, "profit": NSNull(), "row_kind": "segment"],
                ["label": "売上高合計", "amount": 436_889, "profit": NSNull(), "row_kind": "subtotal"],
            ],
            "notes": "製品群別",
        ]
        let client = RealXbrlMockChat(responseJSON: response)
        let sales = 436_889_000_000.0
        let (snapshot, source, _) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, client: client
        )
        #expect(source == .revenueRecognitionLLM)
        #expect(snapshot?.axis == "business")
        let labels = Set(snapshot?.rows.map(\.labelRaw) ?? [])
        #expect(labels.contains("精密加工装置"))
        #expect(labels.contains("精密加工ツール"))
        #expect(snapshot?.rows.contains { $0.labelRaw == "精密加工装置" && $0.amount == 273_957_000_000 } == true)
        #expect(await client.timesCalled() == 1)
    }

    @Test func tokyoElectronResolvesViaRevenueRecognitionLLM() async throws {
        guard await Self.ensureAvailable("S100YEOO") else { return }
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100YEOO"))
        #expect(segments.tables.first?.heading == BreakdownExtractor.revenueRecognitionHeading)

        let tableIndex = Self.preferredTableIndex(segments.tables, containing: "新規装置")
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": tableIndex,
            "period_column": "当期",
            "profit_disclosed": false,
            "rows": [
                ["label": "新規装置", "amount": 1_817_250, "profit": NSNull(), "row_kind": "segment"],
                ["label": "フィールドソリューション他", "amount": 626_282, "profit": NSNull(), "row_kind": "segment"],
                ["label": "合計", "amount": 2_443_533, "profit": NSNull(), "row_kind": "subtotal"],
            ],
            "notes": "製品別",
        ]
        let client = RealXbrlMockChat(responseJSON: response)
        let sales = 2_443_533_000_000.0
        let (snapshot, source, _) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, client: client
        )
        #expect(source == .revenueRecognitionLLM)
        #expect(snapshot?.axis == "business")
        let labels = Set(snapshot?.rows.map(\.labelRaw) ?? [])
        #expect(labels.contains("新規装置"))
        #expect(labels.contains("フィールドソリューション他"))
        #expect(snapshot?.rows.contains { $0.labelRaw == "新規装置" && $0.amount == 1_817_250_000_000 } == true)
        #expect(await client.timesCalled() == 1)
    }

    @Test func mitsubishiResolvesViaRevenueRecognitionLLM() async throws {
        guard await Self.ensureAvailable("S100YB25") else { return }
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100YB25"))
        #expect(segments.tables.first?.heading == BreakdownExtractor.revenueRecognitionHeading)

        let tableIndex = Self.preferredTableIndex(segments.tables, containing: "地球環境エネルギー")
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": tableIndex,
            "period_column": "当期",
            "profit_disclosed": false,
            "rows": [
                ["label": "地球環境エネルギー", "amount": 3_267_295, "profit": NSNull(), "row_kind": "segment"],
                ["label": "マテリアルソリューション", "amount": 3_631_197, "profit": NSNull(), "row_kind": "segment"],
                ["label": "金属資源", "amount": 4_083_329, "profit": NSNull(), "row_kind": "segment"],
                ["label": "社会インフラ", "amount": 930_638, "profit": NSNull(), "row_kind": "segment"],
                ["label": "モビリティ", "amount": 837_375, "profit": NSNull(), "row_kind": "segment"],
                ["label": "食品産業", "amount": 2_324_535, "profit": NSNull(), "row_kind": "segment"],
                ["label": "S.L.C.", "amount": 2_514_143, "profit": NSNull(), "row_kind": "segment"],
                ["label": "電力ソリューション", "amount": 1_318_984, "profit": NSNull(), "row_kind": "segment"],
                ["label": "その他", "amount": 8_539, "profit": NSNull(), "row_kind": "segment"],
                ["label": "調整・消去", "amount": -40, "profit": NSNull(), "row_kind": "reconciling"],
                ["label": "連結金額", "amount": 18_915_995, "profit": NSNull(), "row_kind": "subtotal"],
            ],
            "notes": "当期の横結合表の合計行",
        ]
        let client = RealXbrlMockChat(responseJSON: response)
        let sales = 18_915_995_000_000.0
        let (snapshot, source, _) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, client: client
        )
        #expect(source == .revenueRecognitionLLM)
        #expect(snapshot?.axis == "business")
        let labels = Set(snapshot?.rows.map(\.labelRaw) ?? [])
        #expect(labels.contains("地球環境エネルギー"))
        #expect(labels.contains("S.L.C."))
        #expect(labels.contains("電力ソリューション"))
        #expect(snapshot?.rows.contains { $0.labelRaw == "金属資源" && $0.amount == 4_083_329_000_000 } == true)
        #expect(snapshot?.rows.contains { $0.rowKind == "subtotal" && $0.amount == 18_915_995_000_000 } == true)
        #expect(snapshot?.needsReview == false)
        #expect(await client.timesCalled() == 1)
    }

    @Test func sumitomoResolvesViaSegmentInfoLLMFromProductTable() async throws {
        guard await Self.ensureAvailable("S100YH3M") else { return }
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100YH3M"))
        #expect(segments.method == "xbrl_facts")
        #expect(!segments.tables.isEmpty)

        let tableIndex = Self.preferredTableIndex(segments.tables, containing: "ラツーダ")
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": tableIndex,
            "period_column": "当連結会計年度",
            "profit_disclosed": false,
            // 分母整合性のため segment 合計≈連結売上。ラベル存在だけを実XBRL回帰で見る。
            "rows": [
                ["label": "ラツーダ（非定型抗精神病薬）", "amount": 13_694, "profit": NSNull(), "row_kind": "segment"],
                ["label": "オルゴビクス（進行性前立腺がん治療剤）", "amount": 155_017, "profit": NSNull(), "row_kind": "segment"],
                ["label": "ジェムテサ（過活動膀胱治療剤）", "amount": 95_986, "profit": NSNull(), "row_kind": "segment"],
                ["label": "その他製品等", "amount": 188_597, "profit": NSNull(), "row_kind": "segment"],
                ["label": "合計", "amount": 453_294, "profit": NSNull(), "row_kind": "subtotal"],
            ],
            "notes": "製品及びサービスごとの情報を採用",
        ]
        let client = RealXbrlMockChat(responseJSON: response)
        let sales = 453_294_000_000.0

        let (snapshot, source, _) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, client: client
        )

        #expect(source == .segmentInfoLLM)
        #expect(await client.schemaName() == "segment_info_breakdown")
        #expect(snapshot?.axis == "business")
        let labels = snapshot?.rows.map(\.labelRaw).joined(separator: " ") ?? ""
        #expect(labels.contains("ラツーダ"))
        #expect(labels.contains("オルゴビクス"))
        #expect(await client.timesCalled() == 1)
    }

    @Test func eisaiResolvesViaSegmentInfoLLMFromNeurologyOncologyTable() async throws {
        guard await Self.ensureAvailable("S100YB05") else { return }
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100YB05"))
        #expect(segments.method == "xbrl_facts")
        #expect(segments.tables.contains(where: { $0.heading == BreakdownExtractor.productOrServiceHeading }))

        let tableIndex = Self.preferredTableIndex(segments.tables, containing: "ニューロロジー")
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": tableIndex,
            "period_column": "当連結会計年度",
            "profit_disclosed": false,
            "rows": [
                ["label": "ニューロロジー領域製品", "amount": 260_568, "profit": NSNull(), "row_kind": "segment"],
                ["label": "オンコロジー領域製品", "amount": 362_668, "profit": NSNull(), "row_kind": "segment"],
                ["label": "その他", "amount": 202_142, "profit": NSNull(), "row_kind": "segment"],
                ["label": "合計", "amount": 825_378, "profit": NSNull(), "row_kind": "subtotal"],
            ],
            "notes": "主要な製品に関する情報を採用",
        ]
        let client = RealXbrlMockChat(responseJSON: response)
        let sales = 825_378_000_000.0

        let (snapshot, source, _) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, client: client
        )

        #expect(source == .segmentInfoLLM)
        #expect(await client.schemaName() == "segment_info_breakdown")
        #expect(snapshot?.axis == "business")
        #expect(snapshot?.needsReview == false)
        let labels = Set(snapshot?.rows.map(\.labelRaw) ?? [])
        #expect(labels.contains("ニューロロジー領域製品"))
        #expect(labels.contains("オンコロジー領域製品"))
        #expect(labels.contains("その他"))
        #expect(await client.timesCalled() == 1)
    }

    // MARK: - 資生堂 S100XSCU（2026-08-14）

    @Test func shiseidoResolvesGeographicBusinessSegmentsViaSegmentInfoLLM() async throws {
        guard await Self.ensureAvailable("S100XSCU") else { return }
        // 報告セグメント名が「日本事業」「米州事業」等の地域事業ユニット。金額はユーザー確認済み
        // （分母 969,992 百万円と一致）。ラベルが地名に見えるため needs_review は立つが、
        // 中身は事業軸として採用する（本番 segment_info_llm / S100XSCU）。
        let segments = BreakdownExtractor.extractSegmentInfo(xbrlDir: Self.xbrlDir("S100XSCU"))
        let joined = segments.tables.map(\.markdown).joined(separator: "\n")
        #expect(joined.contains("日本事業"))

        let tableIndex = Self.preferredTableIndex(segments.tables, containing: "日本事業")
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": tableIndex,
            "period_column": "当期",
            "profit_disclosed": true,
            "rows": [
                ["label": "日本事業", "amount": 295_343, "profit": 38_972, "row_kind": "segment"],
                ["label": "中国・トラベルリテール事業", "amount": 342_244, "profit": 64_525, "row_kind": "segment"],
                ["label": "アジアパシフィック事業", "amount": 73_290, "profit": 5_079, "row_kind": "segment"],
                ["label": "米州事業", "amount": 106_584, "profit": -11_566, "row_kind": "segment"],
                ["label": "欧州事業", "amount": 141_129, "profit": 3_949, "row_kind": "segment"],
                ["label": "その他", "amount": 11_399, "profit": -1_259, "row_kind": "segment"],
                ["label": "合計", "amount": 969_992, "profit": 99_700, "row_kind": "subtotal"],
                ["label": "調整額", "amount": 0, "profit": -55_179, "row_kind": "reconciling"],
                ["label": "連結", "amount": 969_992, "profit": 44_520, "row_kind": "subtotal"],
            ],
            "notes": "報告セグメント表を採用。事業が列見出しのため転置。",
        ]
        let client = RealXbrlMockChat(responseJSON: response)
        let sales = 969_992_000_000.0

        let (snapshot, source, _) = await BusinessBreakdownResolver.resolve(
            segments: segments, consolidatedSales: sales, client: client
        )

        #expect(source == .segmentInfoLLM)
        #expect(snapshot?.axis == "business")
        #expect(snapshot?.needsReview == true)
        #expect(snapshot?.warnings.contains("business_label_looks_like_geography") == true)
        #expect(snapshot?.denominator == sales)
        let japan = try #require(snapshot?.rows.first { $0.labelRaw == "日本事業" })
        #expect(japan.amount == 295_343_000_000)
        #expect(japan.profit == 38_972_000_000)
        let china = try #require(snapshot?.rows.first { $0.labelRaw.contains("トラベルリテール") })
        #expect(china.amount == 342_244_000_000)
        #expect(await client.timesCalled() == 1)
    }

    @Test func asahi2023ResolvesJapanOverseasGeographyViaLLM() async throws {
        guard await Self.ensureAvailable("S100QG09") else { return }
        let geography = BreakdownExtractor.extractGeographyInfo(xbrlDir: Self.xbrlDir("S100QG09"))
        #expect(geography.method == "html_table")

        let tableIndex = Self.preferredTableIndex(geography.tables, containing: "1,281,768")
        let response: [String: Any] = [
            "applicable": true,
            "unit": "million_yen",
            "source_table_index": tableIndex,
            "period_column": "当年度",
            "rows": [
                ["label": "日本", "amount": 1_281_768, "row_kind": "segment"],
                ["label": "海外", "amount": 1_229_340, "row_kind": "segment"],
                ["label": "合計", "amount": 2_511_108, "row_kind": "subtotal"],
            ],
            "notes": "対外部売上収益の日本/海外表。うちオーストラリアは内数のため出さない。",
        ]
        let client = RealXbrlMockChat(responseJSON: response)
        let sales = 2_511_108_000_000.0

        let (snapshot, source, _) = await GeographyBreakdownResolver.resolve(
            geography: geography, consolidatedSales: sales, client: client
        )

        #expect(source == .geographyLLM)
        #expect(snapshot?.axis == "geography")
        #expect(snapshot?.needsReview == false)
        #expect(snapshot?.denominator == sales)
        let japan = try #require(snapshot?.rows.first { $0.labelRaw == "日本" })
        #expect(japan.amount == 1_281_768_000_000)
        let overseas = try #require(snapshot?.rows.first { $0.labelRaw == "海外" })
        #expect(overseas.amount == 1_229_340_000_000)
        #expect(await client.timesCalled() == 1)
    }
}

