// 連結財務諸表注記からセグメント・地域別情報を抽出する
//
//   extractSegmentInfo()   → 事業別（報告セグメント別）
//   extractGeographyInfo() → 地域別（所在地別）
//
// 優先: XBRLのTextBlock内のHTML表をそのまま構造化
// フォールバック: XBRLのcontextのdimension付きfact

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import SwiftSoup

struct BreakdownTable: Equatable {
    var heading: String
    var markdown: String
    var period: String?  // "当期" | "前期" | "比較"
}

struct BreakdownFact: Equatable {
    var tag: String
    var contextRef: String
    var dimensions: [String: String]
    var value: Double
    var label: String?
    var unitRef: String?
    var decimals: String?
}

struct ExtractedBreakdown: Equatable {
    var method: String  // "html_table" | "xbrl_facts" | "not_found"
    var tables: [BreakdownTable]
    var facts: [BreakdownFact]

    /// JSONSerialization 互換の辞書に変換する（Python 出力と同じキー構造）。
    func toDictionary() -> [String: Any] {
        let tablesArr: [[String: Any]] = tables.map { t in
            var d: [String: Any] = ["heading": t.heading, "markdown": t.markdown]
            if let p = t.period { d["period"] = p }
            return d
        }
        let factsArr: [[String: Any]] = facts.map { f in
            var d: [String: Any] = [
                "tag": f.tag,
                "contextRef": f.contextRef,
                "dimensions": f.dimensions,
                "value": f.value,
            ]
            if let l = f.label { d["label"] = l }
            if let u = f.unitRef { d["unitRef"] = u }
            if let dec = f.decimals { d["decimals"] = dec }
            return d
        }
        return ["method": method, "tables": tablesArr, "facts": factsArr]
    }
}

extension ExtractedBreakdown {
    /// toDictionary() の逆変換。
    init(dictionary: [String: Any]) {
        method = dictionary["method"] as? String ?? "not_found"
        tables = (dictionary["tables"] as? [[String: Any]] ?? []).map { t in
            BreakdownTable(
                heading: t["heading"] as? String ?? "",
                markdown: t["markdown"] as? String ?? "",
                period: t["period"] as? String
            )
        }
        facts = (dictionary["facts"] as? [[String: Any]] ?? []).map { f in
            BreakdownFact(
                tag: f["tag"] as? String ?? "",
                contextRef: f["contextRef"] as? String ?? "",
                dimensions: f["dimensions"] as? [String: String] ?? [:],
                value: f["value"] as? Double ?? 0,
                label: f["label"] as? String,
                unitRef: f["unitRef"] as? String,
                decimals: f["decimals"] as? String
            )
        }
    }
}

/// business breakdown が解決できなかった理由（診断用、issue #130）。
/// rawValue は `breakdownNotApplicable*`（`Models/BreakdownContract.swift`、公開文字列定数）と揃える
/// （`BusinessBreakdownSource` と `breakdownSource*` の関係と同じパターン）。
enum BusinessBreakdownNotApplicableReason: String, Equatable {
    /// E: 報告セグメントが地域別のみで、business 軸への swap が見つからなかった（良品計画型）。
    /// マツダは地域別セグメントを持つが、単一セグメント開示省略の文言（F）も併せ持つため
    /// singleSegmentDisclosed が優先される（2026-07-26、資生堂型対応）。
    case geographyOnly = "geography_only"
    /// F: 単一セグメントのため報告セグメント開示自体が省略されていた。
    case singleSegmentDisclosed = "single_segment_disclosed"
    /// 上記いずれにも該当しない・原因未特定（要調査）。
    case unknown
}

enum BreakdownExtractor {

    private static let currentPeriodKeywords = ["当連結会計年度", "当期"]
    private static let priorPeriodKeywords = ["前連結会計年度", "前期"]

    // MARK: - 公開 API

    /// filing コマンド・REST API の sections で使う特殊セクション名（XBRLSectionDef 非経由）。
    static let specialSectionKeys = ["segments", "geography", "revenue_recognition"]

    /// 収益認識関係注記の見出し文字列。`extractRevenueRecognitionInfo` の dedicatedHeading と
    /// `specialSectionTitles` の双方、および `BusinessBreakdownResolver` の見出し判定
    /// （swap 済み segments かどうかの振り分け）が同じ文字列を参照する単一の真実源。
    static let revenueRecognitionHeading = "収益認識関係"

    /// 特殊セクションの表示タイトル。
    static let specialSectionTitles: [String: String] = [
        "segments": "セグメント情報",
        "geography": "地域別情報",
        "revenue_recognition": revenueRecognitionHeading,
    ]

    /// 特殊セクション名に対応する抽出を実行する。未対応の名前は nil。
    static func extractSpecialSection(_ section: String, xbrlDir: URL) -> ExtractedBreakdown? {
        switch section {
        case "segments": return extractSegmentInfo(xbrlDir: xbrlDir)
        case "geography": return extractGeographyInfo(xbrlDir: xbrlDir)
        case "revenue_recognition": return extractRevenueRecognitionInfo(xbrlDir: xbrlDir)
        default: return nil
        }
    }

    /// 製品・サービス別テキストブロックの表示見出し（あおぞら銀行「サービス毎の情報」等）。
    /// `SegmentInfoLLMNormalizer` に回す（収益認識見出しには揃えない）。
    static let productOrServiceHeading = "製品・サービス別情報"

    /// 連結財務諸表注記から事業別（報告セグメント別）情報を抽出する。
    ///
    /// 報告セグメント（xbrl_facts 経路）のメンバーが全て地域名の場合（オークマ型:
    /// docs/breakdown.md 学び10）、その内容は「事業別」ではなく
    /// 「地域別」であるため、収益認識関係注記（`extractRevenueRecognitionInfo`）に本当の
    /// 事業別（製品別）データがあればそちらを優先する。見つからない場合は元の地域別
    /// xbrl_facts をそのまま返す（未検証企業での誤判定時に表示が消える regression を避けるため）。
    ///
    /// 単一セグメントで報告セグメント開示が省略される場合（東京エレクトロン型）も
    /// `not_found` のままでは製品別が取れないため、収益認識関係注記に製品・サービス別の
    /// 分解表があればそちらへフォールバックする。
    ///
    /// 三菱商事型: セグメント注記は売上総利益・資産のみで、事業別の「顧客との契約から認識した収益」
    /// が IFRS Revenue2 注記側にある → 売上相当行が無いセグメント表なら収益認識へ swap。
    /// あおぞら銀行型: `InformationForEachProductOrServiceTextBlock`（サービス毎の経常収益）を
    /// セグメント表の前に結合し、後段 LLM が選べるようにする。
    static func extractSegmentInfo(xbrlDir: URL) -> ExtractedBreakdown {
        var tables = extractFromTextBlocks(
            xbrlDir: xbrlDir,
            dedicatedTags: Xbrl.businessSegmentTextBlockTags,
            mixedTags: Xbrl.businessSegmentMixedTextBlockTags,
            dedicatedHeading: "セグメント情報",
            mixedKeywords: Xbrl.businessSegmentHeadingKeywords,
            mixedHeadingExclusionKeywords: Xbrl.businessSegmentHeadingExclusionKeywords,
            // US-GAAP 巨大注記内のクロスリファレンス文・基準書名引用（「…」内）や句点付き
            // 散文を見出しと誤認しない（富士フイルム S100W3XJ）。「〜は以下のとおりです。」等の
            // 表導入文は残す（オリックス S100YG5L）。geography は散文見出しに依存するため
            // opt-in は business のみ。
            mixedHeadingLikeOnly: true
        )
        let productOrServiceTables = extractFromTextBlocks(
            xbrlDir: xbrlDir,
            dedicatedTags: Xbrl.productOrServiceTextBlockTags,
            mixedTags: [],
            dedicatedHeading: productOrServiceHeading,
            mixedKeywords: []
        )
        // サービス毎・製品別を先頭に置き、報告セグメントの粗利/利益表より優先して LLM に見せる
        if !productOrServiceTables.isEmpty {
            tables = productOrServiceTables + tables
        }
        // 三井住友トラスト型: 通常のセグメント専用タグでは表が取れず、Etc 注記に実質業務粗利益がある
        if !tablesContainSalesEquivalent(tables) {
            let etcTables = extractFromTextBlocks(
                xbrlDir: xbrlDir,
                dedicatedTags: Xbrl.businessSegmentEtcTextBlockTags,
                mixedTags: [],
                dedicatedHeading: "セグメント情報",
                mixedKeywords: []
            )
            if !etcTables.isEmpty {
                tables = tables + etcTables
            }
        }
        let result = buildResult(xbrlDir: xbrlDir, tables: tables, dimensionKeywords: Xbrl.businessSegmentDimensionKeywords)

        if shouldPreferRevenueRecognition(over: result)
            || (detectSingleSegmentDisclosure(xbrlDir: xbrlDir) != nil && result.method != "xbrl_facts")
        {
            let revenueRecognition = extractRevenueRecognitionInfo(xbrlDir: xbrlDir)
            if revenueRecognition.method == "html_table",
                !isRevenueTypeOnlyDecomposition(revenueRecognition.tables)
            {
                // メルカリ型: セグメント注記に Marketplace/Fintech の売上マトリクスがある一方、
                // IFRS 売上収益注記は「分解はセグメント情報に記載」のポインタ＋契約負債表のみ。
                // 無条件 swap すると製品表を失う（実データ検証: S100WQDW、2026-07-25）。
                // セグメント側に売上相当があり、かつ RR 側に実質的な売上分解が無いときだけ
                // swap を抑止する。売上マーカー語の有無だけでは、デンソー型（事業名＋合計のみ
                // で実分解あり）をメルカリ型スタブと誤判定する（issue #157、S100Y9T1）。
                //
                // 電通型（issue #163）: 製品・サービス別表の売上語がキャプション側（「外部顧客からの収益」）
                // にあり markdown セルに出ないため `tablesContainSalesEquivalent` だけでは守れない。
                // さらに RR の契約債権残高が売上と同規模だと scale 判定が実質分解と誤認する
                // （S100XS0O: 受取手形及び売掛金 ≈ 1.8兆 vs 製品別合計 ≈ 1.4兆）。
                // 製品・サービス別見出しがあり RR が契約残高スタブならセグメント側を残す。
                // オークマは RR に売上マーカー付き製品分解があり、従来どおり RR へ swap する。
                let rrSubstantive = tablesContainSubstantiveRevenueBreakdown(
                    revenueRecognition.tables, relativeTo: result.tables)
                let rrContractStub = tablesLookLikeContractBalanceStub(revenueRecognition.tables)
                let hasProductTables = result.tables.contains {
                    $0.heading == productOrServiceHeading
                }
                let keepSegmentSide =
                    (tablesContainSalesEquivalent(result.tables) && !rrSubstantive)
                    || (hasProductTables && (rrContractStub || !rrSubstantive))
                if !keepSegmentSide {
                    return revenueRecognition
                }
            }
        }

        return result
    }

    /// RR 表が契約債権・契約資産・契約負債の残高推移だけで、売上分解を含まないか
    /// （電通 NotesRevenue2 / メルカリ IFRS 売上収益スタブ）。
    static func tablesLookLikeContractBalanceStub(_ tables: [BreakdownTable]) -> Bool {
        guard !tables.isEmpty else { return false }
        let joined = tables.map(\.markdown).joined(separator: "\n")
        let contractMarkers = ["契約資産", "契約負債", "顧客との契約から生じた債権"]
        guard contractMarkers.contains(where: joined.contains) else { return false }
        if tablesContainSalesEquivalent(tables) { return false }
        if revenueBreakdownBusinessHints.contains(where: { joined.contains($0) }) { return false }
        return true
    }

    /// 収益認識/IFRS売上（Revenue2 含む）へ axis-aware に寄せるべきか。
    static func shouldPreferRevenueRecognition(over result: ExtractedBreakdown) -> Bool {
        // オークマ / ブリヂストン・デンソー型: 報告セグメントが地域別
        if result.method == "xbrl_facts", isGeographyAxis(result.facts) { return true }
        // 東京エレクトロン型: セグメント開示なし
        if result.method == "not_found" { return true }
        // 東京エレクトロン / ディスコ実データ: 単一セグメント省略の文言はあるが、
        // セグメント注記に地域別・主要顧客の売上表が残るため method は html_table。
        // 製品別は収益認識注記側。xbrl_facts で事業 member が取れている会社
        // （S100XUDW 等）は単一セグメント検出があっても swap しない。
        // 三菱商事型: セグメント表に売上相当行が無く、利益・資産だけ
        // （製品・サービス別表が既にあればそちらを残すので swap しない。
        // 　facts に既に売上相当タグ（buildResult と同じ判定、`factsContainRecognizedAmountTag`）が
        // 　あれば、表側の文言一致に失敗していても swap しない。実データ検証: 三菱UFJ「粗利益」ラベルが
        // 　tablesContainSalesEquivalent のマーカーに一致せず誤って swap していた、2026-07-24）
        if !result.tables.isEmpty,
            !tablesContainSalesEquivalent(result.tables),
            !factsContainRecognizedAmountTag(result.facts),
            !result.tables.contains(where: { $0.heading == productOrServiceHeading })
        {
            return true
        }
        return false
    }

    /// 表群に外部売上・経常収益・実質業務粗利益など「売上相当」の行があるか。
    /// 売上総利益・純利益・資産だけのセグメント表は false（三菱商事のセグメント注記）。
    static func tablesContainSalesEquivalent(_ tables: [BreakdownTable]) -> Bool {
        guard !tables.isEmpty else { return false }
        let joined = tables.map(\.markdown).joined(separator: "\n")
        let markers = [
            "顧客との契約から認識した収益",
            "顧客との契約から生じる収益",
            "外部顧客に対する経常収益",
            "外部顧客への売上",
            "外部顧客からの収益",  // 電通等 IFRS（issue #163）。「への売上」だけでは一致しない
            "外部収益",
            "売上収益",
            "売上高",
            "経常収益",
            "実質業務粗利益",
            "連結粗利益",
            "業務粗利益",
        ]
        return markers.contains(where: { joined.contains($0) })
    }

    /// RR 表群が「実質的な売上分解」を持つか（メルカリ型スタブとの区別、issue #157）。
    ///
    /// `tablesContainSalesEquivalent` だけでは区別できない:
    /// - メルカリ: RR は契約債権・契約負債の残高表のみ（売上分解はセグメント注記へポインタ）
    /// - デンソー: RR にサーマル等の事業別内訳があるが、行ラベルが「自動車分野計」「合計」のみで
    ///   売上マーカー語を含まない
    ///
    /// 判定順:
    /// 1. 売上マーカー語（ブリヂストン等）
    /// 2. 事業・製品ヒント（デンソー: サーマル…。`isRevenueTypeOnlyDecomposition` と同じリスト）
    /// 3. RR 最大絶対値 / セグメント最大絶対値 ≥ `substantiveRevenueScaleRatio`
    ///    （売上オーダー vs 契約残高オーダー。実データ: デンソー≈0.82 / メルカリ≈0.04）
    static func tablesContainSubstantiveRevenueBreakdown(
        _ rrTables: [BreakdownTable], relativeTo segmentTables: [BreakdownTable]
    ) -> Bool {
        guard !rrTables.isEmpty else { return false }
        if tablesContainSalesEquivalent(rrTables) { return true }
        let joined = rrTables.map(\.markdown).joined(separator: "\n")
        if revenueBreakdownBusinessHints.contains(where: { joined.contains($0) }) { return true }
        let rrMax = maxAbsoluteNumericValue(in: rrTables)
        let segmentMax = maxAbsoluteNumericValue(in: segmentTables)
        guard rrMax > 0, segmentMax > 0 else { return false }
        return rrMax / segmentMax >= substantiveRevenueScaleRatio
    }

    /// RR 最大値 / セグメント最大値がこの比率以上なら売上オーダーの分解とみなす。
    /// メルカリ型契約残高（≈0.04）を切り、デンソー型売上合計（≈0.82）を通す（実データ 2026-07-30）。
    static let substantiveRevenueScaleRatio: Double = 0.2

    /// markdown 表セルから絶対値の最大を取る（抽出層に consolidatedSales が無いための代理指標）。
    static func maxAbsoluteNumericValue(in tables: [BreakdownTable]) -> Double {
        var maxValue = 0.0
        for table in tables {
            for line in table.markdown.split(separator: "\n", omittingEmptySubsequences: false) {
                for part in line.split(separator: "|", omittingEmptySubsequences: false) {
                    let cell = part.trimmingCharacters(in: .whitespaces)
                    guard let value = XBRLUtils.parseHtmlNumber(cell) else { continue }
                    maxValue = max(maxValue, abs(value))
                }
            }
        }
        return maxValue
    }

    /// 事業・製品の粒度ヒント。種類分解判定の除外と、RR 実質分解判定の両方で使う。
    /// 売上マーカーが無い事業別表（デンソー）を種類分解／スタブと誤判定しないため。
    static let revenueBreakdownBusinessHints = [
        "タイヤ", "サーマル", "パワトレイン", "モビリティ", "エレクトリ", "ソリューション",
        "化工品", "多角化", "スペシャリティ",
    ]

    /// EDINET/JPCRP タクソノミの専用タグ。単一セグメント企業がセグメント情報の記載を省略する旨を
    /// 開示する箇所（実データ確認: 千葉銀行「当行グループは、銀行業の単一セグメントであるため、
    /// 記載を省略しております。」、ユーザー確認2026-07-21）。IFRS版はサフィックスが異なる
    /// （実データ確認: ベイカレント6532・日本取引所グループ8697、issue #137調査2026-07-26）。
    static let singleSegmentDisclosureTags: Set<String> = [
        "DescriptionOfFactThatCompanysBusinessComprisesSingleSegment",
        "DescriptionOfFactThatCompanysBusinessComprisesSingleSegmentIFRS",
    ]

    /// 専用タグを使わず、IFRS方式のセグメント注記「(4) 製品及びサービスに関する情報」
    /// （`Xbrl.productOrServiceTextBlockTags`）内の説明文だけで記載省略を述べるケースがある
    /// （実データ確認: 資生堂4911「化粧品事業の外部顧客への売上高が連結損益計算書上の「売上高」の
    /// ほとんどを占めているため、記載を省略します。」、issue調査2026-07-26）。
    ///
    /// 「記載を省略」単独では、報告セグメントと内容が重複するため省略する**多セグメント企業**の
    /// 定型文まで拾ってしまう（実データ検証2026-07-26、EDINETキャッシュ157社: パナソニックHD
    /// 「セグメント情報に同様の情報を開示しているため、記載を省略しています。」、富士通「製品及び
    /// サービスの類型は各報告セグメントと同一となるため、記載を省略しております。」等、194ブロック中
    /// 145件・59社中51社が誤検出）。したがって単一セグメント・集中度を示す語との併記を必須にし
    /// （`singleSegmentConcentrationMarkers`）、「報告セグメントと同一」型の定型句は明示的に除外する
    /// （`singleSegmentDisclosureExclusionMarkers`）。この2条件で実データ59社中8社（資生堂含む）を
    /// 誤検出ゼロで検出できることを確認済み。
    static let singleSegmentDisclosureMarker = "記載を省略"
    static let singleSegmentConcentrationMarkers = [
        "単一の", "ほとんどを占め", "90％を超える", "90%を超える", "区分することが困難",
    ]
    static let singleSegmentDisclosureExclusionMarkers = ["報告セグメントと同一", "同様の情報を開示"]

    /// セグメント注記が「単一セグメントのため記載を省略」である旨を明示しているかを診断する。
    /// `classifyNotApplicableReason`（company_breakdowns への永続化に使う本番判定）から呼ばれる
    /// ほか、診断表示にも使う。専用タグは即採用、非専用（製品・サービス別情報）タグは
    /// 表を持たず・マーカー＋集中度語を含み・同一セグメント定型句を含まない場合のみ採用する。
    static func detectSingleSegmentDisclosure(xbrlDir: URL) -> String? {
        let targetTags = singleSegmentDisclosureTags.union(Xbrl.productOrServiceTextBlockTags)
        for file in XBRLUtils.findXbrlFiles(in: xbrlDir) {
            guard let data = try? Data(contentsOf: file) else { continue }
            let collector = TextBlockSAXCollector(targetTags: targetTags)
            let parser = XMLParser(data: data)
            parser.delegate = collector
            parser.parse()
            for block in collector.blocks {
                let isDedicatedTag = singleSegmentDisclosureTags.contains(block.tag)
                if !isDedicatedTag, block.content.contains("<table") { continue }
                let text = (try? SwiftSoup.parse(block.content))
                    .map { bs4Text($0, strip: true) } ?? block.content
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if isDedicatedTag {
                    return trimmed
                }
                guard trimmed.contains(singleSegmentDisclosureMarker),
                    !singleSegmentDisclosureExclusionMarkers.contains(where: trimmed.contains),
                    singleSegmentConcentrationMarkers.contains(where: trimmed.contains)
                else { continue }
                return trimmed
            }
        }
        return nil
    }

    /// `BusinessBreakdownResolver.resolve` が business 軸を解決できなかった（snapshot == nil）ときの
    /// 理由を推定する（診断用、issue #130）。単一セグメント開示（F）は表が無いときだけ確定する
    /// （製品別 html_table がある東京エレクトロン型を F にすると再試行されない）。表が無い資生堂型は
    /// 地域軸 facts（E）より F を優先する。
    /// `llmHint` は html_table 経由（`RevenueRecognitionLLMNormalizer`/`SegmentInfoLLMNormalizer`）で
    /// LLM が `applicable=false` と判定したときの `LLMBreakdownAudit.notApplicableReason`
    /// （issue #135）。xbrl_facts 経路の判定は method=="xbrl_facts" のときしか効かないため、
    /// LLM 自身が「地域別のみ」と申告したケースを拾う目的で追加した。
    static func classifyNotApplicableReason(
        segments: ExtractedBreakdown, consolidatedSales: Double?, xbrlDir: URL, llmHint: String? = nil
    ) -> BusinessBreakdownNotApplicableReason {
        // 単一セグメント開示（F）は、製品別・収益認識の表が無いときだけ確定する。
        // 表がある東京エレクトロン型を F にすると needs_review=false の not_applicable になり
        // 再試行されない（新規上場の同型が欠測のまま残る）。
        if detectSingleSegmentDisclosure(xbrlDir: xbrlDir) != nil, segments.tables.isEmpty {
            return .singleSegmentDisclosed
        }
        if segments.method == "xbrl_facts",
            BreakdownNormalizer.normalize(segments, consolidatedSales: consolidatedSales)?.axis == "geography"
        {
            return .geographyOnly
        }
        if llmHint == BusinessBreakdownNotApplicableReason.geographyOnly.rawValue {
            return .geographyOnly
        }
        return .unknown
    }

    /// 連結財務諸表注記から地域別（所在地別）の**外部売上**情報を抽出する。
    ///
    /// IFRS「地域別の情報」で外部顧客売上を省略し非流動資産だけを載せる会社（日本精工型）では、
    /// 資産表を候補から外し、注記「売上高」の収益の分解（地域×事業マトリクス）へフォールバックする。
    ///
    /// 電通型（issue #163）: 地域専用注記は重要国の文章開示＋非流動資産表のみで売上表が残らず、
    /// GeographicArea dimension も無い。報告セグメント自体が日本/Americas/EMEA/APAC の地域軸なら
    /// OperatingSegments の売上 facts を geography として採用する（business 軸は既に
    /// `shouldPreferRevenueRecognition` で製品・サービス表へ swap する相補関係）。
    static func extractGeographyInfo(xbrlDir: URL) -> ExtractedBreakdown {
        let dedicated = Xbrl.geographyTextBlockTags.subtracting(Xbrl.geographyMixedTextBlockTags)
        var tables = extractFromTextBlocks(
            xbrlDir: xbrlDir,
            dedicatedTags: dedicated,
            mixedTags: Xbrl.geographyMixedTextBlockTags,
            dedicatedHeading: "地域ごとの情報",
            mixedKeywords: Xbrl.geographyHeadingKeywords,
            skipGeographyAssetMetricTables: true
        )
        // 地域注記側に売上表が残らない（売上省略＋資産表除外）ときだけ、
        // 収益の分解（NotesNetSales）から地域行のある表を拾う。
        // 単に tables.isEmpty だけでは不十分（地域専用 TextBlock 無しの誤発火を防ぐ）。
        if tables.isEmpty,
            hasDedicatedGeographyTextBlock(xbrlDir: xbrlDir)
                || hasGeographyRevenueOmissionMarker(xbrlDir: xbrlDir)
        {
            let revenueDecomp = extractFromTextBlocks(
                xbrlDir: xbrlDir,
                dedicatedTags: Xbrl.geographyRevenueDecompositionTextBlockTags,
                mixedTags: [],
                dedicatedHeading: Xbrl.geographyRevenueDecompositionHeading,
                mixedKeywords: [],
                skipGeographyAssetMetricTables: true
            ).filter(tableHasGeographyRegionLabels)
            if !revenueDecomp.isEmpty {
                tables = revenueDecomp
            }
        }
        let result = buildResult(
            xbrlDir: xbrlDir, tables: tables, dimensionKeywords: Xbrl.geographyDimensionKeywords)
        if result.method == "not_found",
            let segmentGeography = extractGeographyFromReportableSegments(xbrlDir: xbrlDir)
        {
            return segmentGeography
        }
        return result
    }

    /// 報告セグメント（OperatingSegments 系）の売上 facts が全て地域軸相当なら geography として返す。
    /// 事業名セグメントや国内海外×事業クロス（キッコーマン型）は `isGeographyAxis` が false。
    private static func extractGeographyFromReportableSegments(xbrlDir: URL) -> ExtractedBreakdown? {
        let contextMap = loadDimensionContextMap(xbrlDir: xbrlDir)
        let facts = extractFactsByDimension(
            xbrlDir: xbrlDir,
            dimensionKeywords: Xbrl.businessSegmentDimensionKeywords,
            contextMap: contextMap
        )
        guard !facts.isEmpty,
            factsContainRecognizedAmountTag(facts),
            isGeographyAxis(facts)
        else { return nil }
        return ExtractedBreakdown(method: "xbrl_facts", tables: [], facts: facts)
    }

    /// markdown 表のデータ行先頭セル（行ラベル）に地域名キーワードが十分あるか。
    /// 列が地域・行が事業の表（収益分解の転置形）は落とす。
    static func tableHasGeographyRegionLabels(_ table: BreakdownTable) -> Bool {
        let labels = rowLabelsFromMarkdown(table.markdown)
        let hits = labels.filter { label in
            Xbrl.segmentSpecificGeographyLabelKeywordsJa.contains(where: label.contains)
        }
        return hits.count >= 2
    }

    private static let dedicatedGeographyTextBlockTags: Set<String> =
        Xbrl.geographyTextBlockTags.subtracting(Xbrl.geographyMixedTextBlockTags)

    private static func hasDedicatedGeographyTextBlock(xbrlDir: URL) -> Bool {
        for file in XBRLUtils.findXbrlFiles(in: xbrlDir) {
            guard let data = try? Data(contentsOf: file) else { continue }
            let collector = TextBlockSAXCollector(targetTags: dedicatedGeographyTextBlockTags)
            let parser = XMLParser(data: data)
            parser.delegate = collector
            parser.parse()
            if !collector.blocks.isEmpty { return true }
        }
        return false
    }

    /// 地域専用 TextBlock 本文に売上省略マーカー（日本精工型）があるか。
    private static func hasGeographyRevenueOmissionMarker(xbrlDir: URL) -> Bool {
        for file in XBRLUtils.findXbrlFiles(in: xbrlDir) {
            guard let data = try? Data(contentsOf: file) else { continue }
            let collector = TextBlockSAXCollector(targetTags: dedicatedGeographyTextBlockTags)
            let parser = XMLParser(data: data)
            parser.delegate = collector
            parser.parse()
            for block in collector.blocks where geographyRevenueOmissionMarker(in: block.content) {
                return true
            }
        }
        return false
    }

    private static func geographyRevenueOmissionMarker(in html: String) -> Bool {
        let text = (try? SwiftSoup.parse(html)).map { bs4Text($0, strip: true) } ?? html
        let hasOmission = text.contains("記載を省略")
            || (text.contains("注記") && (text.contains("売上") || text.contains("収益")))
        guard hasOmission else { return false }
        return text.contains("売上") || text.contains("収益")
    }

    /// Markdown 表のデータ行（ヘッダー区切り線の後）から先頭セル＝行ラベルを取り出す。
    private static func rowLabelsFromMarkdown(_ markdown: String) -> [String] {
        var labels: [String] = []
        var pastSeparator = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|") else { continue }
            if trimmed.contains("---") {
                pastSeparator = true
                continue
            }
            if !pastSeparator { continue }
            let parts = trimmed.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            let label = parts[1].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, XBRLUtils.parseHtmlNumber(label) == nil else { continue }
            labels.append(label)
        }
        return labels
    }

    /// 連結財務諸表注記（収益認識関係 / IFRS 売上収益）から「顧客との契約から生じる収益を
    /// 分解した情報」を抽出する。オークマ型（J-GAAP 収益認識関係）とブリヂストン・デンソー型
    /// （IFRS 売上収益注記）の両方を `revenueRecognitionTextBlockTags` で拾い、見出しは
    /// `revenueRecognitionHeading` に揃えて後段の LLM 振り分けを共通化する。
    static func extractRevenueRecognitionInfo(xbrlDir: URL) -> ExtractedBreakdown {
        let tables = extractFromTextBlocks(
            xbrlDir: xbrlDir,
            dedicatedTags: Xbrl.revenueRecognitionTextBlockTags,
            mixedTags: [],
            dedicatedHeading: revenueRecognitionHeading,
            mixedKeywords: []
        )
        return buildResult(xbrlDir: xbrlDir, tables: tables, dimensionKeywords: [])
    }

    /// 収益の「種類」（製商品の販売 / 知的財産権収入 等）だけに分解した表か。
    /// 住友ファーマの IFRS 売上収益注記はこの形で、製品別（ラツーダ等）はセグメント注記の
    /// 「製品及びサービスごとの情報」側にある。種類分解へ swap すると製品別を取り逃す。
    /// 契約負債残高など無関係な表が混ざっていても、連結 markdown に収益種類マーカーがあれば
    /// 種類分解とみなし、事業・製品の粒度ヒントが併存すれば種類分解ではないとみなす。
    static func isRevenueTypeOnlyDecomposition(_ tables: [BreakdownTable]) -> Bool {
        guard !tables.isEmpty else { return false }
        let joined = tables.map(\.markdown).joined(separator: "\n")
        let revenueTypeMarkers = [
            "製商品の販売", "物品の販売", "知的財産権収入", "知的財産収益", "ライセンス収入",
            // エーザイ等: 列が「医薬品販売による収益」「ライセンス供与による収益」。脚注の
            // 「ライセンス収入」だけに頼ると表本文だけの抽出時に種類分解と判定できず、
            // 製品別表（ニューロロジー/オンコロジー）を失う（実データ検証: S100YB05、2026-07-25）。
            "医薬品販売による収益", "ライセンス供与による収益",
        ]
        guard revenueTypeMarkers.contains(where: { joined.contains($0) }) else { return false }
        // 事業・製品の具体名が併記されていれば種類分解ではない（ブリヂストン: タイヤ、デンソー: サーマル…）
        if revenueBreakdownBusinessHints.contains(where: { joined.contains($0) }) { return false }
        return true
    }

    /// segment 行（小計・調整行を除く）の member ラベルが全て地域名キーワードに一致するか。
    /// `BreakdownNormalizer.classifyAxis` と同じ「全一致 → geography」判定だが、数値による
    /// 小計判定（consolidatedSales が要る2次判定）は使わず、標準タクソノミの小計・調整
    /// member 名（1次判定）のみで segment 行を絞る。raw 抽出層では sales を持たないため。
    ///
    /// 軸判定に使う facts は売上/銀行粗利/保険収益の認識タグに限定する。`NumberOfEmployees` 等の
    /// 非金額ファクトに付く `OtherOperatingSegmentsAxisMember` が混ざると、報告セグメント自体は
    /// 地域別なのに geography 判定が壊れ、IFRS 売上収益注記への swap が起きなくなる
    /// （ブリヂストン S100XRPR 実データ検証 2026-07-24）。
    private static func isGeographyAxis(_ facts: [BreakdownFact]) -> Bool {
        let segmentMembers = facts.compactMap { fact -> String? in
            guard factsContainRecognizedAmountTag([fact]),
                  let member = primaryMember(fact.dimensions),
                  !Xbrl.segmentSubtotalMemberNames.contains(member),
                  !Xbrl.segmentReconcilingMemberNames.contains(member),
                  !Xbrl.segmentOtherBusinessMemberNames.contains(member)
            else { return nil }
            return member
        }
        // `BreakdownNormalizer.classifyAxis` と同じ基準を使う（重複ロジック回避。以前は本関数だけ
        // 独立した簡易版チェックを持っており、キッコーマン型「国内食品製造販売」等の事業区分×
        // 国内海外クロス集計を誤って地域軸と判定し、classifyAxis 側の修正が反映されなかった）。
        return BreakdownNormalizer.allMembersAreGeography(Array(Set(segmentMembers)))
    }

    /// dimensions のうち ConsolidatedOrNonConsolidatedAxis 以外の member を行ラベルとする。
    /// `BreakdownNormalizer.primaryMember` と同じ規約（dimension キー名の辞書順で先頭を採用）。
    private static func primaryMember(_ dimensions: [String: String]) -> String? {
        dimensions
            .filter { $0.key != "ConsolidatedOrNonConsolidatedAxis" }
            .sorted { $0.key < $1.key }
            .first?.value
    }

    // MARK: - HTML 表の構造化

    /// rowspan / colspan を展開してセル文字列の二次元グリッドにする。
    static func expandTable(_ table: Element) -> [[String]] {
        var grid: [Int: [Int: String]] = [:]
        var rowIdx = 0
        guard let trs = try? table.select("tr") else { return [] }
        for tr in trs {
            var colIdx = 0
            let cells = (try? tr.select("td, th"))?.array() ?? []
            for cell in cells {
                while grid[rowIdx]?[colIdx] != nil { colIdx += 1 }
                let text = bs4Text(cell, strip: true)
                let rowspan = XBRLUtils.parseHtmlIntAttribute(cell, "rowspan")
                let colspan = XBRLUtils.parseHtmlIntAttribute(cell, "colspan")
                for r in 0..<max(rowspan, 0) {
                    for c in 0..<max(colspan, 0) {
                        grid[rowIdx + r, default: [:]][colIdx + c] = text
                    }
                }
                colIdx += colspan
            }
            rowIdx += 1
        }
        guard !grid.isEmpty else { return [] }
        let maxRow = grid.keys.max()! + 1
        let maxCol = grid.values.compactMap { $0.keys.max() }.max()! + 1
        return (0..<maxRow).map { r in (0..<maxCol).map { c in grid[r]?[c] ?? "" } }
    }

    /// グリッドを列幅揃えの Markdown テーブル文字列にする。
    static func gridToMarkdown(_ grid: [[String]]) -> String {
        guard !grid.isEmpty else { return "" }
        let colCount = grid.map(\.count).max()!
        let colWidths = (0..<colCount).map { c in
            grid.map { row in c < row.count ? row[c].unicodeScalars.count : 0 }.max()!
        }
        var lines: [String] = []
        for (i, row) in grid.enumerated() {
            let cells = (0..<colCount).map { c -> String in
                let text = c < row.count ? row[c] : ""
                return text + String(repeating: " ", count: max(0, colWidths[c] - text.unicodeScalars.count))
            }
            lines.append("| " + cells.joined(separator: " | ") + " |")
            if i == 0 {
                lines.append("|" + colWidths.map { String(repeating: "-", count: $0 + 2) }.joined(separator: "|") + "|")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 当期/前期判定

    /// グリッド先頭3行のテキストから当期/前期を判定する。
    static func detectPeriodFromGrid(_ grid: [[String]]) -> String? {
        for row in grid.prefix(3) {
            let joined = row.joined()
            let hasCurrent = currentPeriodKeywords.contains(where: joined.contains)
            let hasPrior = priorPeriodKeywords.contains(where: joined.contains)
            if hasCurrent && hasPrior { return "比較" }
            if hasCurrent { return "当期" }
            if hasPrior { return "前期" }
        }
        return nil
    }

    /// XBRL TextBlock の contextRef から当期/前期を判定する。
    /// 専用地域売上・製品サービス別 TextBlock が Prior1YearDuration / CurrentYearDuration
    /// の2要素に分かれる会社（地域: ニチレイ・三菱UFJ・三井住友・オークマ、
    /// 製品: ファナック・任天堂・太陽誘電）では HTML 内に期間見出しが無く、
    /// ブロック単位の `applyPeriodOrdering` だと両方「前期」になるため、contextRef を正とする。
    static func periodLabel(fromContextRef contextRef: String?) -> String? {
        guard let contextRef, !contextRef.isEmpty else { return nil }
        if Xbrl.priorDurationContextPatterns.contains(where: contextRef.contains)
            || Xbrl.priorInstantContextPatterns.contains(where: contextRef.contains)
        {
            return "前期"
        }
        if Xbrl.durationContextPatterns.contains(where: contextRef.contains)
            || Xbrl.instantContextPatterns.contains(where: contextRef.contains)
        {
            return "当期"
        }
        return nil
    }

    /// テーブル前の兄弟要素（短いもの）から当期/前期を判定する。
    /// 同じ親の下に複数テーブルが並ぶ場合、テーブルに最も近い（最後に見つかった）
    /// 見出しを採用する（先頭の見出しに固定されるとテーブルが増えるほど誤判定が広がるため）。
    private static func detectPeriodFromPreceding(_ table: Element) -> String? {
        guard let parent = table.parent() else { return nil }
        var result: String?
        for node in parent.getChildNodes() {
            guard node.siblingIndex < table.siblingIndex else { break }
            let text: String
            if let el = node as? Element {
                text = bs4Text(el, strip: true)
            } else if let tn = node as? TextNode {
                text = tn.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                continue
            }
            if text.isEmpty || text.unicodeScalars.count > Xbrl.noteShortCaptionMaxLength { continue }
            if currentPeriodKeywords.contains(where: text.contains) {
                result = "当期"
            } else if priorPeriodKeywords.contains(where: text.contains) {
                result = "前期"
            }
        }
        return result
    }

    /// 見出し行に埋め込まれた西暦年度ラベル（例:「2024年度」「2025年度」）を除去した正規化文字列。
    /// 年度が変わるたびに個別のタグ・表現を追加する Whac-A-Mole を避けるための一般化ルール。
    private static let fiscalYearLabelPattern = "[0-9０-９]{4}年度?"

    private static func stripFiscalYearLabel(_ text: String) -> String {
        text.replacingOccurrences(of: fiscalYearLabelPattern, with: "", options: .regularExpression)
    }

    /// 2つの見出し行が「同一開示（前期・当期を並べた表）の続き」とみなせるか。
    /// 完全一致に加え、西暦年度ラベルのみが異なる場合も同一とみなす（学び参照、実データ検証:
    /// 小松製作所の US-GAAP セグメント注記）。どちらも空/nil の場合は判定材料が無いため false。
    private static func headerRowsMatch(_ a: [String]?, _ b: [String]?) -> Bool {
        guard let a, let b, !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        return a.map(stripFiscalYearLabel) == b.map(stripFiscalYearLabel)
    }

    /// grid の1行目（見出し/期間行）を除く各行から、行ラベル（先頭セルが非数値かつ同じ行に
    /// 数値セルが1つ以上ある場合の先頭セル文字列）の集合を作る。カテゴリ名だけが並ぶ見出し行
    /// （例:「建設機械・車両｜リテールファイナンス」のような列見出し行）は、その行に数値セルが
    /// 無いため行ラベルとみなさない。
    ///
    /// 地域名（日本・米州・欧州等）は行ラベルの候補から除外する。地域名は同一注記内で
    /// 「売上高の地域別内訳」「有形固定資産の地域別内訳」のように**別々の指標の開示**で
    /// 使い回されるため、一致しても「同じ開示の続き」の根拠にならない（実データ検証:
    /// 富士フイルム S100W3XJ。売上高地域別表と有形固定資産地域別表が同一の地域名
    /// 「日本・米州・欧州・アジア及びその他」を行ラベルに持ち、Jaccard 1.0 で誤ってチェーン
    /// されていた。golden parity 回帰、CI 発覚 2026-07-25）。
    private static func rowLabelSet(_ grid: [[String]]) -> Set<String> {
        var labels: Set<String> = []
        for row in grid.dropFirst() {
            guard let first = row.first, !first.isEmpty, XBRLUtils.parseHtmlNumber(first) == nil else { continue }
            guard !Xbrl.segmentGeographyLabelKeywordsJa.contains(where: first.contains) else { continue }
            let hasNumericSibling = row.dropFirst().contains { XBRLUtils.parseHtmlNumber($0) != nil }
            if hasNumericSibling { labels.insert(first) }
        }
        return labels
    }

    /// 2つの表が「同じ財務項目行を異なる列構成（事業別／地域別など）または期間で開示した続き」
    /// とみなせるか。列見出しの完全一致を要求する `headerRowsMatch` では、同一注記内で
    /// 事業別 view → 地域別 view のように列構成が変わる開示（オリックス型 US-GAAP 巨大注記、
    /// issue #103）を取りこぼす。行ラベル集合の Jaccard 類似度が閾値以上なら「同じ開示の続き」
    /// とみなす（`headerRowsMatch` の代替条件。実データ検証: S100YG5L、事業別/地域別いずれも
    /// 22項目中22項目一致=Jaccard 1.0、資産注記との境界では一致0件=Jaccard 0.0）。
    /// カテゴリ名だけが並ぶ見出し行（行ラベルを持たない表）はどちらも空集合になるため、
    /// 空集合同士は非該当として扱う（誤って一致とみなさない）。
    private static func rowLabelSetsOverlapEnough(_ a: [[String]], _ b: [[String]]) -> Bool {
        let labelsA = rowLabelSet(a)
        let labelsB = rowLabelSet(b)
        guard !labelsA.isEmpty, !labelsB.isEmpty else { return false }
        let intersection = labelsA.intersection(labelsB)
        guard intersection.count >= Xbrl.noteRowLabelMinOverlapCount else { return false }
        let union = labelsA.union(labelsB)
        return Double(intersection.count) / Double(union.count) >= Xbrl.noteRowLabelJaccardThreshold
    }

    /// 改ページで割れた同一表の行ラベル。製品名が第2列に来る表（武田: 空セル｜ENTYVIO｜金額）
    /// では `rowLabelSet` が空になるため、先頭の非空・非数値セルを使う。
    /// チェーン判定（小松・オリックス・富士フイルム）の Jaccard は `rowLabelSet` のまま変えない。
    private static func continuationRowLabelSet(_ grid: [[String]]) -> Set<String> {
        var labels: Set<String> = []
        for row in grid.dropFirst() {
            guard let label = row.first(where: { !$0.isEmpty && XBRLUtils.parseHtmlNumber($0) == nil }) else {
                continue
            }
            guard !Xbrl.segmentGeographyLabelKeywordsJa.contains(where: label.contains) else { continue }
            let hasNumeric = row.contains { XBRLUtils.parseHtmlNumber($0) != nil }
            if hasNumeric { labels.insert(label) }
        }
        return labels
    }

    /// 列見出しとして使う期間行（「前年度／当年度」「前連結会計年度」等）。単位行だけの
    /// 1行目一致では別開示まで結合してしまうため、期間行があればそちらを優先する。
    private static func periodHeaderRow(_ grid: [[String]]) -> [String]? {
        let markers = ["前年度", "当年度", "前連結会計年度", "当連結会計年度", "前期", "当期"]
        return grid.prefix(4).first { row in
            let joined = row.joined()
            return markers.contains(where: joined.contains)
        }
    }

    /// 隣接する2表が縦または横の続きなら結合後の grid を返す。
    /// 縦（武田: 同じ列・行が続く）を先に試し、該当しなければ横（三菱商事: 同じ行・列が続く）。
    private static func mergedContinuationGrid(
        leading: [[String]],
        trailing: [[String]],
        leadingPeriod: String?,
        trailingPeriod: String?
    ) -> [[String]]? {
        if isVerticalTableContinuation(
            leading: leading, trailing: trailing,
            leadingPeriod: leadingPeriod, trailingPeriod: trailingPeriod)
        {
            return mergeContinuationGrids(leading, trailing)
        }
        if isHorizontalTableContinuation(leading: leading, trailing: trailing) {
            return mergeHorizontalGrids(leading, trailing)
        }
        return nil
    }

    /// 同一表が紙面の改ページで `<table>` 分割された続きか。
    /// 列構成が一致し、行ラベルがほぼ互いに素で、期間が同じ（または両方未判定）ときだけ true。
    /// 小松（年度ラベル違いの前期/当期）・オリックス（列は違うが行ラベル高一致）・
    /// キヤノン（見出し一致だが前期→当期、または地域名のみ）は false。
    private static func isVerticalTableContinuation(
        leading: [[String]],
        trailing: [[String]],
        leadingPeriod: String?,
        trailingPeriod: String?
    ) -> Bool {
        guard leading.count >= 2, trailing.count >= 2 else { return false }
        guard leading[0].count == trailing[0].count, leading[0].count >= 2 else { return false }
        // 単位行（「（単位：百万円）」）だけの一致では別開示まで結合する。期間列（前年度/当年度）
        // が両方の表に同じ文言で載っていることだけを列構成の根拠にする。
        guard let pa = periodHeaderRow(leading), let pb = periodHeaderRow(trailing), pa == pb else {
            return false
        }
        switch (leadingPeriod, trailingPeriod) {
        case ("前期", "当期"), ("当期", "前期"):
            return false
        default:
            break
        }
        let labelsA = continuationRowLabelSet(leading)
        let labelsB = continuationRowLabelSet(trailing)
        guard !labelsA.isEmpty, !labelsB.isEmpty else { return false }
        let union = labelsA.union(labelsB)
        guard !union.isEmpty else { return false }
        let jaccard = Double(labelsA.intersection(labelsB).count) / Double(union.count)
        return jaccard < Xbrl.noteVerticalContinuationJaccardMax
    }

    /// 続き表の単位行・期間見出しを落として行方向に結合する。
    private static func mergeContinuationGrids(_ leading: [[String]], _ trailing: [[String]]) -> [[String]] {
        var skip = 0
        while skip < trailing.count, skip < leading.count, leading[skip] == trailing[skip] {
            skip += 1
        }
        if skip == 0 {
            while skip < trailing.count, isRepeatedContinuationHeaderRow(trailing[skip]) {
                skip += 1
            }
        }
        return leading + Array(trailing.dropFirst(skip))
    }

    private static func isRepeatedContinuationHeaderRow(_ row: [String]) -> Bool {
        let joined = row.joined()
        if joined.contains("単位") { return true }
        let periodMarkers = ["前年度", "当年度", "前連結会計年度", "当連結会計年度"]
        if periodMarkers.contains(where: joined.contains) { return true }
        return row.allSatisfy(\.isEmpty)
    }

    /// 同一表が改ページで列方向に割れた続きか（三菱商事の事業グループ別収益）。
    /// 行ラベル（先頭列）が一致し、列見出しは互いに素、右表だけが合計/連結金額列を持ち、
    /// 左の数値合計＋右の事業列が右の合計列に一致するときだけ true。
    /// オリックス（事業 view と地域 view、合計列が無いか数値が一致しない）や
    /// 小松（列見出しが同じ前期/当期）は false。期間ラベルは使わない（HTML に期間が無く
    /// applyPeriodOrdering が左右を前期/当期と誤ることがあるため）。
    private static func isHorizontalTableContinuation(leading: [[String]], trailing: [[String]]) -> Bool {
        guard leading.count >= 2, trailing.count >= 2, leading.count == trailing.count else {
            return false
        }
        guard leading[0].count >= 2, trailing[0].count >= 3 else { return false }
        for (leftRow, rightRow) in zip(leading, trailing) {
            let leftStub = leftRow.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rightStub = rightRow.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard leftStub == rightStub else { return false }
        }
        let leftHeaders = horizontalHeaderLabels(leading[0])
        let rightHeaders = horizontalHeaderLabels(trailing[0])
        guard !leftHeaders.isEmpty, !rightHeaders.isEmpty else { return false }
        guard leftHeaders.isDisjoint(with: rightHeaders) else { return false }
        let leftTotals = leftHeaders.filter(isHorizontalTotalColumnHeader)
        let rightTotals = rightHeaders.filter(isHorizontalTotalColumnHeader)
        let rightSegments = rightHeaders.subtracting(rightTotals)
        guard leftTotals.isEmpty, !rightTotals.isEmpty, !rightSegments.isEmpty else { return false }
        return horizontalNumericRowsAlign(leading: leading, trailing: trailing)
    }

    /// 右表の合計列を落として、左表の各行に右表の列を足す。
    private static func mergeHorizontalGrids(_ leading: [[String]], _ trailing: [[String]]) -> [[String]] {
        zip(leading, trailing).map { left, right in
            left + Array(right.dropFirst())
        }
    }

    private static func horizontalHeaderLabels(_ headerRow: [String]) -> Set<String> {
        Set(
            headerRow.dropFirst().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private static func isHorizontalTotalColumnHeader(_ text: String) -> Bool {
        Xbrl.noteHorizontalTotalColumnHeaders.contains(
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// データ行について、左の数値合計＋右の非合計列 ≈ 右のいずれかの合計列、が
    /// 1行以上成立し、合計列の値が読める行ではすべて成立すること。
    private static func horizontalNumericRowsAlign(leading: [[String]], trailing: [[String]]) -> Bool {
        let rightHeaders = trailing[0].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var matched = 0
        for rowIndex in 1..<leading.count {
            let leftRow = leading[rowIndex]
            let rightRow = trailing[rowIndex]
            let leftSum = leftRow.dropFirst().compactMap(XBRLUtils.parseHtmlNumber).reduce(0, +)
            var segmentSum = 0.0
            var totalValues: [Double] = []
            for col in 1..<rightHeaders.count {
                let header = col < rightHeaders.count ? rightHeaders[col] : ""
                let raw = col < rightRow.count ? rightRow[col] : ""
                guard let value = XBRLUtils.parseHtmlNumber(raw) else { continue }
                if isHorizontalTotalColumnHeader(header) {
                    totalValues.append(value)
                } else {
                    segmentSum += value
                }
            }
            guard !totalValues.isEmpty else { continue }
            let combined = leftSum + segmentSum
            let rowMatches = totalValues.contains { total in
                horizontalAmountsMatch(combined, total)
            }
            if !rowMatches { return false }
            matched += 1
        }
        return matched >= 1
    }

    private static func horizontalAmountsMatch(_ lhs: Double, _ rhs: Double) -> Bool {
        let scale = max(1.0, abs(rhs), abs(lhs))
        return abs(lhs - rhs) <= max(1.0, scale * Xbrl.noteHorizontalContinuationRelativeTolerance)
    }

    /// 当期/前期が未ラベルのテーブルに順序ルール（前期→当期の繰り返し）を適用する。
    static func applyPeriodOrdering(_ tables: inout [BreakdownTable]) {
        var i = 0
        for idx in tables.indices where tables[idx].period == nil {
            tables[idx].period = i % 2 == 0 ? "前期" : "当期"
            i += 1
        }
    }

    // MARK: - TextBlock → テーブル抽出

    private static func findNextTable(after element: Element) -> Element? {
        var sibling = try? element.nextElementSibling()
        while let s = sibling {
            if s.tagName() == "table" { return s }
            if let found = (try? s.select("table"))?.first() { return found }
            sibling = try? s.nextElementSibling()
        }
        return nil
    }

    /// table の直後に、短いラベル（例:「第125期」）だけを挟んで次の表が続いていないかを調べる。
    /// 「第n期及び第n+1期における...は以下のとおりであります」のように前期・当期を1つの見出しで
    /// まとめて紹介し、表ごとに個別の <div> でラップされているケースで必要（実データ: キヤノン
    /// 地域別注記）。table 自身の nextElementSibling だけでは辿れない（table が div の唯一の
    /// 子だと兄弟が無い）ため、table 自身の兄弟 → 1段親（ラッパー div 等）の兄弟の順に探す。
    /// 挟まる要素のテキストが長ければ無関係な話題への移行とみなし nil を返す。
    private static func findImmediatelyChainedTable(after table: Element) -> Element? {
        let startPoints: [Element] = [table, table.parent()].compactMap { $0 }
        for start in startPoints {
            var sibling = try? start.nextElementSibling()
            var hops = 0
            while let s = sibling, hops < Xbrl.noteTableChainMaxGapElements {
                hops += 1
                if s.tagName() == "table" { return s }
                if let found = (try? s.select("table"))?.first() { return found }
                let text = bs4Text(s, strip: true)
                // この起点（table 自身 or 1段親）での探索を打ち切るだけで、次の起点は引き続き試す
                // （1段目で長文に当たっても、2段目（親の兄弟）側は無関係とは限らないため）。
                if text.unicodeScalars.count > Xbrl.noteShortCaptionMaxLength { break }
                sibling = try? s.nextElementSibling()
            }
        }
        return nil
    }

    /// HTML内の全 <table> を Markdown 化して返す。
    /// `includeFootnotes`: 表の外にある「(注1) …」形式の脚注段落も同じ見出しの末尾候補に残す。
    /// 収益認識/IFRS 売上収益向け（ブリヂストン: タイヤ(注1)＝ソリューション、その他(注2)＝化工品・多角化。
    /// 表セルには注番号しか無く細目本文は段落側。実データ検証 2026-07-24）。
    /// セグメント情報の golden parity を壊さないよう、既定は false。
    /// `skipGeographyAssetMetricTables`: 直前キャプションが非流動資産・有形固定資産の表を除外
    /// （日本精工型: 地域別の情報①売上省略・②非流動資産のみ表あり）。
    /// `defaultPeriod`: TextBlock の contextRef 由来の期間。HTML 側で判定できないときのフォールバック
    /// （dedicated 地域売上・製品サービスの Prior/Current 分離 TextBlock 用。mixed 見出し経路では渡さない）。
    static func allTablesFromHtml(
        _ html: String, defaultHeading: String, includeFootnotes: Bool = false,
        skipGeographyAssetMetricTables: Bool = false,
        defaultPeriod: String? = nil
    ) -> [BreakdownTable] {
        guard let soup = try? SwiftSoup.parse(html),
              let tableEls = try? soup.select("table") else { return [] }
        var tables: [BreakdownTable] = []
        var pendingElement: Element?
        var pendingGrid: [[String]]?
        var pendingPeriod: String?

        func flushPending() {
            guard let grid = pendingGrid else { return }
            tables.append(BreakdownTable(
                heading: defaultHeading, markdown: gridToMarkdown(grid), period: pendingPeriod))
            pendingElement = nil
            pendingGrid = nil
            pendingPeriod = nil
        }

        for table in tableEls {
            if skipGeographyAssetMetricTables,
                let metricCaption = nearestGeographyMetricCaption(before: table),
                isGeographyAssetMetricCaption(metricCaption)
            {
                continue
            }
            let grid = expandTable(table)
            let md = gridToMarkdown(grid)
            if md.isEmpty { continue }
            // 地域売上向け: 有形固定資産合計行など資産専用表を markdown でも落とす
            // （富士フイルム型。セグメント専用経路の golden を変えないよう geography 時のみ）。
            let mdExclusionKeywords = skipGeographyAssetMetricTables
                ? Xbrl.noteTableExclusionKeywords + Xbrl.geographyAssetTableMarkdownExclusionKeywords
                : Xbrl.noteTableExclusionKeywords
            if mdExclusionKeywords.contains(where: md.contains) {
                continue
            }
            let period = detectPeriodFromPreceding(table) ?? detectPeriodFromGrid(grid)
            if let prevEl = pendingElement, let prevGrid = pendingGrid,
               let chained = findImmediatelyChainedTable(after: prevEl),
               ObjectIdentifier(chained) == ObjectIdentifier(table),
               let merged = mergedContinuationGrid(
                leading: prevGrid, trailing: grid,
                leadingPeriod: pendingPeriod, trailingPeriod: period)
            {
                pendingGrid = merged
                pendingElement = table
                continue
            }
            flushPending()
            pendingElement = table
            pendingGrid = grid
            pendingPeriod = period
        }
        flushPending()
        // contextRef フォールバックは「このブロック内の未ラベル表がちょうど1つ」のときだけ。
        // Prior/Current に分かれた専用地域売上 TextBlock（表1枚ずつ）を救いつつ、
        // 単一 CurrentYearDuration 配下に前期・当期表が同居する会社（味の素・クボタ）では
        // 両方を当期で上書きせず applyPeriodOrdering に委ねる。
        if let defaultPeriod {
            let nilIndices = tables.indices.filter { tables[$0].period == nil }
            if nilIndices.count == 1 {
                tables[nilIndices[0]].period = defaultPeriod
            }
        }
        applyPeriodOrdering(&tables)
        if includeFootnotes, let footnotes = footnoteMarkdown(from: soup) {
            tables.append(BreakdownTable(heading: defaultHeading, markdown: footnotes, period: nil))
        }
        return tables
    }

    /// 表の直前（親を遡った兄弟要素含む）の短いキャプション候補（文書順: 遠い→直近）。
    /// 「所在地別の非流動資産…」のあと `(単位：百万円)` だけの表が挟まると、
    /// 末尾キャプションだけ見ると資産判定を外す（実データ: S100XR0M）。
    /// table 要素および table を含む要素の全文は候補にしない。
    private static func precedingShortCaptions(before table: Element) -> [String] {
        var current: Element? = table
        var captions: [String] = []
        while let node = current {
            guard let parent = node.parent() else { break }
            var levelCaptions: [String] = []
            for child in parent.getChildNodes() {
                guard child.siblingIndex < node.siblingIndex else { break }
                if let el = child as? Element {
                    if el.tagName() == "table" { continue }
                    if (try? el.select("table").first()) != nil { continue }
                }
                let text: String
                if let el = child as? Element {
                    text = bs4Text(el, strip: true)
                } else if let tn = child as? TextNode {
                    text = tn.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    continue
                }
                if text.isEmpty || text.unicodeScalars.count > Xbrl.noteShortCaptionMaxLength { continue }
                levelCaptions.append(text)
            }
            captions = levelCaptions + captions
            current = parent
            // body / html まで上がると無関係な見出しが混ざるので数段で止める
            if parent.tagName() == "body" || parent.tagName() == "html" { break }
        }
        return captions
    }

    /// 単位表記などを飛ばし、直近の「指標セクション」キャプションを返す。
    /// 資産表のあとに売上表が続く開示では、全先行キャプションに非流動資産が残るため
    /// 単純な any-match だと売上表まで落とす（S100W4MT）。
    /// `precedingShortCaptions` は文書順（末尾＝直近）なので末尾から探索する。
    private static func nearestGeographyMetricCaption(before table: Element) -> String? {
        let captions = precedingShortCaptions(before: table)
        for text in captions.reversed() {
            if isGeographyAssetMetricCaption(text) { return text }
            if text.contains("売上") || text.contains("収益") || text.contains("外部顧客") {
                return text
            }
        }
        return captions.last
    }

    private static func isGeographyAssetMetricCaption(_ text: String) -> Bool {
        let isAsset = Xbrl.geographyAssetMetricCaptionKeywords.contains(where: text.contains)
        guard isAsset else { return false }
        // 「売上高と非流動資産」のような併記は売上側として残す
        if text.contains("売上") || text.contains("収益") { return false }
        return true
    }

    /// 注記本文（表の外の `(注１) …` / `（注2）…` 段落）を箇条書き Markdown にする。
    /// 行ラベル側の「タイヤ(注１)」や、オークマ型の会計脚注「(注)１．連結会社間の…」は対象外。
    /// 製品・事業の細目説明（「…には、…事業が含まれております」）だけを拾う。
    static func footnoteMarkdown(from soup: Element) -> String? {
        guard let paragraphs = try? soup.select("p") else { return nil }
        var lines: [String] = []
        var seen = Set<String>()
        for p in paragraphs {
            let text = bs4Text(p, strip: true)
            guard text.unicodeScalars.count <= 400 else { continue }
            // `(注１)` / `（注2）` のように注番号が括弧内にある行だけ（`(注)１．` は除外）
            let startsWithNumberedNote =
                text.hasPrefix("(注1)") || text.hasPrefix("(注2)") || text.hasPrefix("(注3)")
                || text.hasPrefix("（注1）") || text.hasPrefix("（注2）") || text.hasPrefix("（注3）")
                || text.hasPrefix("(注１)") || text.hasPrefix("(注２)") || text.hasPrefix("(注３)")
                || text.hasPrefix("（注１）") || text.hasPrefix("（注２）") || text.hasPrefix("（注３）")
            guard startsWithNumberedNote else { continue }
            // 細目の定義文だけ（会計上の一般注記を避ける）
            guard text.contains("には") || text.contains("含まれ") else { continue }
            if seen.insert(text).inserted {
                lines.append("- \(text)")
            }
        }
        guard !lines.isEmpty else { return nil }
        return (["脚注:"] + lines).joined(separator: "\n")
    }

    /// 見出しキーワードに続く <table> を Markdown 化して返す。
    ///
    /// headingExclusionKeywords: 見出し候補の文字列がこれらを含む場合はスキップする
    /// （例: 事業別セグメント用の検索で「地域別セグメント情報」という地域注記の見出しを誤って拾わないようにする）。
    /// headingLikeOnly: true のとき、句点を含む散文と「…」引用内のキーワード一致を見出し候補から外す
    /// （business の mixed 経路専用。geography の散文見出し回帰を壊さないため既定は false）。
    /// 「〜は以下のとおりです。」等の表導入文は句点があっても残す。
    static func keywordTablesFromHtml(
        _ html: String,
        keywords: [String],
        headingExclusionKeywords: [String] = [],
        headingLikeOnly: Bool = false
    ) -> [BreakdownTable] {
        guard let soup = try? SwiftSoup.parse(html) else { return [] }
        var tables: [BreakdownTable] = []
        var seen = Set<ObjectIdentifier>()
        for keyword in keywords {
            guard let elems = try? soup.select("*") else { continue }
            for elem in elems {
                let text = bs4Text(elem, strip: false)
                guard text.unicodeScalars.count <= 300 else { continue }
                // 句点付き散文は原則見出しではないが、「〜は以下のとおりです。」等の表導入文は残す
                // （オリックス S100YG5L: 注記番号見出しの直後は定義表で、本表は導入文の直後）。
                if headingLikeOnly, text.contains("。"), !isTableIntroCaption(text) { continue }
                // 「…」内は他注記・基準書名の引用なので除いてから判定（【…】は見出し自体に使う）
                let matchText = headingLikeOnly ? stripQuotedSpans(text) : text
                guard matchText.contains(keyword) else { continue }
                if headingExclusionKeywords.contains(where: text.contains) { continue }
                // 直後の表が除外対象（ノイズ）だった場合、同じ見出しの下にある次の表を
                // 一定回数まで探す（見出し直後にノイズ表→本表と並ぶ構成を取りこぼさないため）。
                var candidate = findNextTable(after: elem)
                var attempts = 0
                while let table = candidate, attempts < Xbrl.noteTableLookaheadLimit {
                    attempts += 1
                    guard !seen.contains(ObjectIdentifier(table)) else {
                        candidate = findNextTable(after: table)
                        continue
                    }
                    seen.insert(ObjectIdentifier(table))
                    let grid = expandTable(table)
                    let md = gridToMarkdown(grid)
                    if md.isEmpty || Xbrl.noteTableExclusionKeywords.contains(where: md.contains) {
                        candidate = findNextTable(after: table)
                        continue
                    }
                    let period = detectPeriodFromPreceding(table) ?? detectPeriodFromGrid(grid)
                    var workingGrid = grid
                    var workingTable = table
                    var workingPeriod = period
                    // 改ページで割れた同一表は markdown を結合して1候補にする
                    // （縦: 武田製品別売上 / 横: 三菱商事の事業グループ別収益）。
                    // 小松・オリックスは mergedContinuationGrid が nil のため従来どおり
                    // 別候補として拾い続ける。
                    while let chained = findImmediatelyChainedTable(after: workingTable),
                          !seen.contains(ObjectIdentifier(chained))
                    {
                        let chainedGrid = expandTable(chained)
                        let chainedPeriod =
                            detectPeriodFromPreceding(chained) ?? detectPeriodFromGrid(chainedGrid)
                        guard let merged = mergedContinuationGrid(
                            leading: workingGrid, trailing: chainedGrid,
                            leadingPeriod: workingPeriod, trailingPeriod: chainedPeriod)
                        else { break }
                        seen.insert(ObjectIdentifier(chained))
                        workingGrid = merged
                        workingTable = chained
                    }
                    tables.append(BreakdownTable(
                        heading: keyword, markdown: gridToMarkdown(workingGrid), period: workingPeriod))

                    // 同じ開示が前期・当期の表を1つの見出しでまとめて紹介しているケース
                    // （学び参照）: 直後に短いラベルだけを挟んで続く表があり、かつ次のいずれかを
                    // 満たすなら「同じ表の続き」とみなして拾い続ける。どちらも満たさなければ
                    // 別の開示とみなし打ち切る。
                    // (a) 見出し行（grid 先頭行）が完全一致するか、西暦年度ラベルだけが異なる
                    //     （実データ検証: 小松製作所の US-GAAP セグメント注記。「2024年度」
                    //     「2025年度」のように見出し行自体に年度が埋め込まれ、前期・当期表で
                    //     完全一致しないため見逃していた）
                    // (b) 見出し行（列構成）自体は一致しないが、行ラベル集合（財務項目名）が
                    //     Jaccard で高一致する（実データ検証: オリックスの US-GAAP セグメント
                    //     注記、issue #103。事業別 view→地域別 view のように列構成が変わる
                    //     開示は (a) では拾えず当期表を取りこぼしていた）
                    if let chained = findImmediatelyChainedTable(after: workingTable),
                       !seen.contains(ObjectIdentifier(chained)) {
                        let chainedGrid = expandTable(chained)
                        if headerRowsMatch(chainedGrid.first, workingGrid.first)
                            || rowLabelSetsOverlapEnough(workingGrid, chainedGrid) {
                            candidate = chained
                            continue
                        }
                    }
                    break
                }
            }
        }
        applyPeriodOrdering(&tables)
        return tables
    }

    /// TextBlock要素からHTML表を抽出する汎用ロジック。
    ///
    /// dedicatedTags に一致するブロックは全 table を返す。
    /// mixedTags に一致するブロックは mixedKeywords で見出しを絞る。
    private static func extractFromTextBlocks(
        xbrlDir: URL,
        dedicatedTags: Set<String>,
        mixedTags: Set<String>,
        dedicatedHeading: String,
        mixedKeywords: [String],
        mixedHeadingExclusionKeywords: [String] = [],
        skipGeographyAssetMetricTables: Bool = false,
        mixedHeadingLikeOnly: Bool = false
    ) -> [BreakdownTable] {
        var tables: [BreakdownTable] = []
        let targets = dedicatedTags.union(mixedTags)
        for file in XBRLUtils.findXbrlFiles(in: xbrlDir) {
            guard let data = try? Data(contentsOf: file) else { continue }
            let collector = TextBlockSAXCollector(targetTags: targets)
            let parser = XMLParser(data: data)
            parser.delegate = collector
            parser.parse()
            for block in collector.blocks {
                guard !block.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      block.content.lowercased().contains("<table") else { continue }
                if dedicatedTags.contains(block.tag) {
                    // 収益認識関係だけ脚注段落を候補に含める（セグメント情報の表件数 golden を変えない）
                    let includeFootnotes = dedicatedHeading == revenueRecognitionHeading
                    // contextRef→period は HTML に期間見出しが無い dedicated 分割ブロック向け。
                    // 地域（ニチレイ等）と製品・サービス別（ファナック・任天堂・太陽誘電）。
                    // 事業セグメント dedicated は HTML 見出し判定＋既存 golden（スズキ等）を変えない。
                    let contextPeriod =
                        dedicatedHeading == "地域ごとの情報"
                        || dedicatedHeading == productOrServiceHeading
                        ? periodLabel(fromContextRef: block.contextRef) : nil
                    tables.append(contentsOf: allTablesFromHtml(
                        block.content, defaultHeading: dedicatedHeading,
                        includeFootnotes: includeFootnotes,
                        skipGeographyAssetMetricTables: skipGeographyAssetMetricTables,
                        defaultPeriod: contextPeriod
                    ))
                } else if mixedTags.contains(block.tag) {
                    // mixed は1つの contextRef 配下に前期・当期 HTML が同居しうるため
                    // contextRef フォールバックは付けず、見出し直前テキストで判定する。
                    tables.append(contentsOf: keywordTablesFromHtml(
                        block.content,
                        keywords: mixedKeywords,
                        headingExclusionKeywords: mixedHeadingExclusionKeywords
                            + (skipGeographyAssetMetricTables
                                ? Xbrl.geographyAssetMetricCaptionKeywords : []),
                        headingLikeOnly: mixedHeadingLikeOnly
                    ))
                }
            }
        }
        return tables
    }

    /// 『…』で囲まれた部分は他注記・基準書名の引用であり見出しではない
    /// （例: 注記23「セグメント情報」に記載…、基準書2023-07「セグメント情報開示の改善」）。
    /// 【…】は見出し自体に使われる（実データ: 【事業別セグメント情報】）ため対象外。
    private static func stripQuotedSpans(_ text: String) -> String {
        text.replacingOccurrences(of: "「[^」]*」", with: "", options: .regularExpression)
    }

    /// 句点付きでも表の直前キャプションとして使う定型導入文か。
    /// 「前連結会計年度および当連結会計年度のセグメント情報は以下のとおりです。」等。
    private static func isTableIntroCaption(_ text: String) -> Bool {
        text.contains("以下のとおり") || text.contains("次のとおり") || text.contains("下記のとおり")
    }

    // MARK: - dimension 付き fact 抽出（フォールバック）

    /// contextRef → {dimension局所名: member局所名} のマップを作る。
    static func loadDimensionContextMap(xbrlDir: URL) -> [String: [String: String]] {
        var contextMap: [String: [String: String]] = [:]
        for file in XBRLUtils.findXbrlFiles(in: xbrlDir) {
            guard let data = try? Data(contentsOf: file) else { continue }
            let collector = ContextDimensionSAXCollector()
            let parser = XMLParser(data: data)
            parser.shouldProcessNamespaces = true
            parser.delegate = collector
            parser.parse()
            contextMap.merge(collector.contextMap) { _, new in new }
        }
        return contextMap
    }

    /// dimension 付き fact を抽出する（売上等への意味づけはしない汎用処理）。
    /// `BltServerContext.resolveEmployeesBreakdown`/`resolveResearchAndDevelopmentBreakdown`
    /// （`Server/BltServerFacade.swift`、内訳取り込み employees / research_and_development 軸）
    /// からも再利用するため internal のまま公開する。
    ///
    /// 対象 dimension 付き fact があるタグについては、同じタグの dimension なし
    /// （または連結/非連結軸だけ）の fact も拾う。セグメント表の「連結財務諸表計上額」列に相当し、
    /// 報告セグメント計とは別値になり得る（第一生命: 計 11,373,330 ≠ 連結 9,873,251）。
    static func extractFactsByDimension(
        xbrlDir: URL,
        dimensionKeywords: [String],
        contextMap: [String: [String: String]]
    ) -> [BreakdownFact] {
        let allFacts = XBRLUtils.collectAllNumericFacts(in: xbrlDir)
        var results: [BreakdownFact] = []
        for (tag, ctxMap) in allFacts {
            for (ctxID, fact) in ctxMap {
                guard let dims = contextMap[ctxID], !dims.isEmpty else { continue }
                guard dims.keys.contains(where: { dim in dimensionKeywords.contains(where: dim.contains) }) else { continue }
                results.append(BreakdownFact(
                    tag: tag,
                    contextRef: ctxID,
                    dimensions: dims,
                    value: fact.value,
                    label: fact.label,
                    unitRef: fact.unitRef,
                    decimals: fact.decimals
                ))
            }
        }
        let dimensionedTags = Set(results.map(\.tag))
        if !dimensionedTags.isEmpty {
            for (tag, ctxMap) in allFacts {
                guard dimensionedTags.contains(tag) else { continue }
                for (ctxID, fact) in ctxMap {
                    let dims = contextMap[ctxID] ?? [:]
                    let hasTargetDim = dims.keys.contains { dim in
                        dimensionKeywords.contains { dim.contains($0) }
                    }
                    guard !hasTargetDim else { continue }
                    // contextMap が欠けると dimension 付き context がここに落ちる。
                    // 連結/非連結以外の Member が contextRef にあれば全社合計ではない。
                    guard isEntityLevelContext(ctxID, dims: dims) else { continue }
                    results.append(BreakdownFact(
                        tag: tag,
                        contextRef: ctxID,
                        dimensions: dims,
                        value: fact.value,
                        label: fact.label,
                        unitRef: fact.unitRef,
                        decimals: fact.decimals
                    ))
                }
            }
        }
        // Swift Dictionary は走査順が不定のため、出力を決定的にする
        return results.sorted { ($0.tag, $0.contextRef) < ($1.tag, $1.contextRef) }
    }

    /// セグメント表の「連結財務諸表計上額」列。dimension が空、または連結/非連結軸のみ。
    /// contextRef に他の Member が残っていれば contextMap 欠落の dimension 付き fact。
    private static func isEntityLevelContext(_ contextRef: String, dims: [String: String]) -> Bool {
        let extraDims = dims.keys.filter { $0 != "ConsolidatedOrNonConsolidatedAxis" }
        guard extraDims.isEmpty else { return false }
        let members = contextRef.split(separator: "_").filter { $0.hasSuffix("Member") }
        return members.allSatisfy { $0 == "NonConsolidatedMember" || $0 == "ConsolidatedMember" }
    }

    /// facts に売上高/銀行/保険いずれかの認識可能なタグが含まれる場合に限り、
    /// xbrl_facts（構造化・決定的）を html_table（表スクレイピング）より優先する。実データ検証:
    /// 東京海上・第一三共・キッコーマン等は専用 TextBlock タグ（`NotesSegmentInformation
    /// ConsolidatedFinancialStatementsIFRSTextBlock`）と `OperatingSegmentsAxis` 付き facts の
    /// 両方を持ち、facts の方が決定的に解決できる（銀行・保険基準等）ため優先すべき
    /// （issue調査 2026-07-21）。
    ///
    /// 「facts が非空なら無条件で優先」だと壊れる実例（CI で発覚、golden parity 回帰）:
    /// キヤノン・富士フイルムは `NumberOfEmployees`/`CapitalExpendituresOverviewOf...`等
    /// `OperatingSegmentsAxis` 付きだが売上に無関係な facts を持ち、無条件優先だと正しい
    /// html_table（US-GAAP注記の事業別セグメント表）を差し置いて解決不能な facts を選んでしまう。
    /// 認識可能なタグの有無で判定することで、この2社は従来どおり html_table のまま。
    ///
    /// facts 優先時も tables は破棄せず保持する（Grok 4.5 レビュー指摘: 破棄すると、facts が
    /// 何らかの理由で正規化に失敗した会社が LLM フォールバックの手段を永久に失う）。
    /// 呼び出し側（`BusinessBreakdownResolver` 等）は `method == "xbrl_facts"` を
    /// 優先しつつ、正規化失敗時は `tables` が非空なら LLM 経路へフォールバックする。
    private static func buildResult(
        xbrlDir: URL,
        tables: [BreakdownTable],
        dimensionKeywords: [String]
    ) -> ExtractedBreakdown {
        let contextMap = loadDimensionContextMap(xbrlDir: xbrlDir)
        let facts = extractFactsByDimension(xbrlDir: xbrlDir, dimensionKeywords: dimensionKeywords, contextMap: contextMap)
        if !facts.isEmpty, factsContainRecognizedAmountTag(facts) {
            return ExtractedBreakdown(method: "xbrl_facts", tables: tables, facts: facts)
        }
        if !tables.isEmpty {
            return ExtractedBreakdown(method: "html_table", tables: tables, facts: [])
        }
        // facts はあっても売上相当タグを1つも含まない場合（例: 従業員数・設備投資額のみ）は
        // 「見つかった」とみなさず not_found にする。ZOZO・ベイカレント型（実データ検証: issue #137、
        // 2026-07-26）: OperatingSegmentsAxis 付きの非売上系 fact（CapEx・R&D・従業員数）だけが
        // 存在する単一セグメント企業で、ここを xbrl_facts のまま返すと shouldPreferRevenueRecognition の
        // swap 判定（not_found 必須）に到達できなくなる。`classifyNotApplicableReason` の単一セグメント
        // 診断（`detectSingleSegmentDisclosure`）は method を問わず先に判定するため、この分岐には
        // 依存しない（2026-07-26、資生堂型対応）。
        return ExtractedBreakdown(method: "not_found", tables: [], facts: [])
    }

    /// facts が `BreakdownNormalizer` の売上高ホワイトリスト・銀行・保険いずれかの基準タグを
    /// 1つでも含むか。含まなければ `NumberOfEmployees`/`CapitalExpendituresOverviewOf...`等の
    /// 売上に無関係な facts（キヤノン・富士フイルム型）とみなし、html_table を優先させる。
    /// 上記いずれにも一致しない場合でも、タグ名に "Sales" / "Revenue" を含めば売上相当とみなす
    /// （建設業の完成工事高等、会計基準ごとにタグ名が細かく割れるため個別列挙し切れない。
    /// 実データ検証: 三菱UFJ NetRevenue／建設業 NetSalesOfCompletedConstructionContracts、2026-07-24）。
    static func factsContainRecognizedAmountTag(_ facts: [BreakdownFact]) -> Bool {
        let tags = Set(facts.map(\.tag))
        if tags.contains(where: Xbrl.segmentExternalRevenueTags.contains) { return true }
        if tags.contains(where: Xbrl.segmentBankGrossProfitTags.contains) { return true }
        if tags.contains(where: Xbrl.segmentInsuranceRevenueTags.contains) { return true }
        return tags.contains { $0.contains("Sales") || $0.contains("Revenue") }
    }

    // MARK: - bs4 互換テキスト抽出

    /// BeautifulSoup の get_text() 互換: 子孫テキストノードを区切りなしで連結する。
    /// strip=true は各テキストノードを個別に trim して空を除く（全体 trim ではない）。
    static func bs4Text(_ node: Node, strip: Bool) -> String {
        var parts: [String] = []
        collectTextNodes(node, into: &parts)
        if strip {
            return parts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined()
        }
        return parts.joined()
    }

    private static func collectTextNodes(_ node: Node, into parts: inout [String]) {
        if let textNode = node as? TextNode {
            parts.append(textNode.getWholeText())
            return
        }
        for child in node.getChildNodes() {
            collectTextNodes(child, into: &parts)
        }
    }
}

// MARK: - SAX コレクター (private)

/// 指定 local tag の TextBlock 要素のインナーコンテンツを全件収集する。
/// EDINET の TextBlock はエスケープ済み HTML がテキストとして埋め込まれているため、
/// foundCharacters の連結でデコード済み HTML 文字列が得られる。
private final class TextBlockSAXCollector: NSObject, XMLParserDelegate {
    private let targetTags: Set<String>
    private(set) var blocks: [(tag: String, content: String, contextRef: String?)] = []
    private var capturingTag: String?
    private var capturingContextRef: String?
    private var buffer = ""
    private var depth = 0

    init(targetTags: Set<String>) {
        self.targetTags = targetTags
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        if capturingTag != nil {
            depth += 1
            let attrs = attributeDict.map { " \($0.key)=\"\($0.value)\"" }.joined()
            buffer += "<\(elementName)\(attrs)>"
            return
        }
        if targetTags.contains(XBRLUtils.localName(of: elementName)) {
            capturingTag = XBRLUtils.localName(of: elementName)
            capturingContextRef = attributeDict["contextRef"]
            buffer = ""
            depth = 0
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard let tag = capturingTag else { return }
        if depth == 0 {
            blocks.append((tag: tag, content: buffer, contextRef: capturingContextRef))
            capturingTag = nil
            capturingContextRef = nil
            buffer = ""
        } else {
            depth -= 1
            buffer += "</\(elementName)>"
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturingTag != nil { buffer += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if capturingTag != nil {
            buffer += String(decoding: CDATABlock, as: UTF8.self)
        }
    }
}

/// xbrli:context の xbrldi:explicitMember から dimension マップを収集する。
/// shouldProcessNamespaces = true で使うこと（elementName が local name になる）。
private final class ContextDimensionSAXCollector: NSObject, XMLParserDelegate {
    private static let xbrldiNS = "http://xbrl.org/2006/xbrldi"

    private(set) var contextMap: [String: [String: String]] = [:]
    private var currentContextID: String?
    private var currentDims: [String: String] = [:]
    private var contextDepth = 0
    private var memberDimension: String?
    private var memberText = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        if currentContextID != nil {
            contextDepth += 1
            if elementName == "explicitMember", namespaceURI == Self.xbrldiNS {
                memberDimension = attributeDict["dimension"]
                memberText = ""
            }
        } else if elementName == "context", let id = attributeDict["id"] {
            currentContextID = id
            currentDims = [:]
            contextDepth = 0
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if memberDimension != nil { memberText += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if let dim = memberDimension, elementName == "explicitMember", namespaceURI == Self.xbrldiNS {
            let dimLocal = localPart(dim)
            let valLocal = localPart(memberText.trimmingCharacters(in: .whitespacesAndNewlines))
            if !dimLocal.isEmpty && !valLocal.isEmpty {
                currentDims[dimLocal] = valLocal
            }
            memberDimension = nil
            memberText = ""
        }
        guard currentContextID != nil else { return }
        if contextDepth == 0 {
            if !currentDims.isEmpty {
                contextMap[currentContextID!] = currentDims
            }
            currentContextID = nil
        } else {
            contextDepth -= 1
        }
    }

    private func localPart(_ qname: String) -> String {
        guard let idx = qname.lastIndex(of: ":") else { return qname }
        return String(qname[qname.index(after: idx)...])
    }
}
