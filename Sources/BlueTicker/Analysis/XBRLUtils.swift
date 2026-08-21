// XBRL 解析共通ユーティリティ

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import SwiftSoup
import ZIPFoundation

// MARK: - Module-level label/role cache

// キャッシュキーは document 固有の XBRL 展開ディレクトリ URL であり、document を跨いだ再利用は
// 発生しない（doc ごとに distinct な新規 dir が積み上がるだけ）。上限を設けないと ingest 1 プロセス内で
// 処理 document 数に比例してメモリが純増し OOM する。同一社の並列 doc 処理数は最大 6 のため、
// 16 あれば doc 内再利用（同一 dir への複数回アクセス）の効能を潰さずに頭打ちにできる。
// 数値 fact 索引も同じ容量・同じ前提（展開 dir は不変。ジョブ跨ぎの永続化はしない）。
private let _labelRoleCacheCapacity = 16

/// 挿入順 FIFO で evict する固定容量キャッシュ。スレッド安全性は呼び出し側の _cacheLock が担保する
/// （このstruct自体はロックしない）。
private struct BoundedFIFOCache<Key: Hashable, Value> {
    private var storage: [Key: Value] = [:]
    private var insertionOrder: [Key] = []
    let capacity: Int

    init(capacity: Int) { self.capacity = capacity }

    subscript(key: Key) -> Value? {
        storage[key]
    }

    mutating func insert(_ value: Value, forKey key: Key) {
        if storage[key] == nil {
            insertionOrder.append(key)
        }
        storage[key] = value
        while insertionOrder.count > capacity {
            let oldest = insertionOrder.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }
}

// nonisolated(unsafe): access is serialized by _cacheLock
nonisolated(unsafe) private var _labelCache = BoundedFIFOCache<URL, [String: String]>(capacity: _labelRoleCacheCapacity)
nonisolated(unsafe) private var _labelRoleVariantsCache = BoundedFIFOCache<URL, [String: [String: String]]>(
    capacity: _labelRoleCacheCapacity)
nonisolated(unsafe) private var _roleCache = BoundedFIFOCache<URL, [String: [String]]>(capacity: _labelRoleCacheCapacity)
nonisolated(unsafe) private var _presentationOrderCache = BoundedFIFOCache<URL, [String: [String: Int]]>(capacity: _labelRoleCacheCapacity)
/// 期首残高（`periodStartLabel`）用の表示順。CF/SS の PriorInstant fact に使う。
nonisolated(unsafe) private var _presentationPeriodStartOrderCache = BoundedFIFOCache<
    URL, [String: [String: Int]]
>(capacity: _labelRoleCacheCapacity)
/// 期末残高（`periodEndLabel`）用の表示順。CF/SS の（当期）Instant fact に使う。
nonisolated(unsafe) private var _presentationPeriodEndOrderCache = BoundedFIFOCache<
    URL, [String: [String: Int]]
>(capacity: _labelRoleCacheCapacity)
nonisolated(unsafe) private var _presentationParentsCache = BoundedFIFOCache<URL, [String: [String: Set<String>]]>(capacity: _labelRoleCacheCapacity)
nonisolated(unsafe) private var _preferredLabelRolesCache = BoundedFIFOCache<URL, [String: [String: String]]>(capacity: _labelRoleCacheCapacity)
nonisolated(unsafe) private var _calculationComponentsCache = BoundedFIFOCache<URL, [String: [String: [CalcComponent]]]>(
    capacity: _labelRoleCacheCapacity)

private struct NumericFactCacheKey: Hashable {
    let dir: URL
    let nilAsZero: Bool
}

nonisolated(unsafe) private var _numericFactCache = BoundedFIFOCache<NumericFactCacheKey, XbrlFactIndex>(
    capacity: _labelRoleCacheCapacity)
private let _cacheLock = NSLock()

/// 計算リンクベース（`_cal.xml`、`summation-item` arc）由来の合計項目の構成要素。
/// `StatementLineItem.components` 用（`weight` は実データ上 ±1 のみ確認）。
struct CalcComponent {
    let tag: String
    let weight: Int
}

// 標準タクソノミ（GAAP/IFRS）のラベルは `assets/taxonomy` 配下の zip 群という単一の入力から
// プロセス生涯不変で決まるため、doc 単位キャッシュとは別に一度だけ計算しメモ化する。
nonisolated(unsafe) private var _standardTaxonomyLabelsCache: (
    collapsed: [String: String], variants: [String: [String: String]]
)?
private let _standardTaxonomyLock = NSLock()

// MARK: - Core Utilities

enum XBRLUtils {

    // MARK: Value Parsers

    /// XBRL数値テキストを Double に変換。nil・空文字は nil を返す。
    static func parseXbrlValue(_ text: String?) -> Double? {
        guard let t = text, !t.isEmpty else { return nil }
        let trimmed = t.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "nil" { return nil }
        return Double(trimmed)
    }

    /// HTML表セルの数値テキストを Double に変換（百万円単位のまま）。
    /// "22,548" → 22548.0 / "△8,752" → -8752.0 / "－" → nil
    static func parseHtmlNumber(_ text: String) -> Double? {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        let unitSuffixes = ["百万円", "十万円", "億円", "兆円", "千円", "百円", "万円", "円"]
        for suffix in unitSuffixes {
            if s.hasSuffix(suffix) {
                s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        s = s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "，", with: "")
        if s.hasPrefix("△") || s.hasPrefix("▲") { s = "-" + s.dropFirst() }
        if ["－", "-", "―", "—", ""].contains(s) { return nil }
        return Double(s)
    }

    /// HTML 表行から財務金額らしい値を選ぶ。閾値未満のみの場合は全数値へフォールバックする。
    static func filterFinancialTableAmounts(_ values: [Double]) -> [Double] {
        let financial = values.filter { abs($0) >= Financial.htmlTableMinAbsMillionYen }
        return financial.isEmpty ? values : financial
    }

    /// HTML要素の整数属性を安全に読む。
    static func parseHtmlIntAttribute(_ element: Element, _ attr: String, default defaultValue: Int = 1) -> Int {
        guard let value = try? element.attr(attr) else { return defaultValue }
        return Int(value) ?? defaultValue
    }

    // MARK: Name Utilities

    /// XML タグから local name を取り出す。"{URI}Name" → "Name" / "prefix:Name" → "Name"
    static func localName(of name: String) -> String {
        if let range = name.range(of: "}") {
            return String(name[range.upperBound...])
        }
        if let idx = name.lastIndex(of: ":") {
            return String(name[name.index(after: idx)...])
        }
        return name
    }

    /// linkbase の href フラグメントから XBRL 要素の local name を取り出す。
    static func conceptLocalName(from href: String) -> String {
        let fragment = href.split(separator: "#").last.map(String.init) ?? href
        if fragment.contains(":") {
            return String(fragment.split(separator: ":").last ?? Substring(fragment))
        }
        let parts = fragment.split(separator: "_").map(String.init)
        for part in parts.reversed() where !part.isEmpty && part.first!.isUppercase {
            return part
        }
        return fragment
    }

    /// role URI から section 名を取り出す。"rol_" プレフィックスは除去。
    static func sectionNameFromRole(_ role: String) -> String {
        var s = role
        while s.hasSuffix("/") { s.removeLast() }
        if let idx = s.lastIndex(of: "/") {
            s = String(s[s.index(after: idx)...])
        }
        return s.hasPrefix("rol_") ? String(s.dropFirst(4)) : s
    }

    /// contextRef と role リストから連結/個別を推論する。
    static func inferConsolidation(contextRef: String, roles: [String]) -> String {
        let roleText = roles.map { sectionNameFromRole($0) }.joined(separator: " ")
        if contextRef.contains("_NonConsolidated") || roleText.contains("ReportingCompany") {
            return "non_consolidated"
        }
        if roleText.contains("Consolidated") { return "consolidated" }
        return "unknown"
    }

    // MARK: File Discovery

    /// xbrlDir 内で指定プレフィックス（0105010 等）で始まる HTML ファイルを返す。
    /// PublicDoc 直下と XBRL/PublicDoc の両方を探索する。
    static func findHtmlByPrefix(in dir: URL, prefix: String) -> URL? {
        let fm = FileManager.default
        let candidates = [dir, dir.appendingPathComponent("XBRL/PublicDoc")]
        for searchDir in candidates {
            guard let entries = try? fm.contentsOfDirectory(at: searchDir, includingPropertiesForKeys: nil) else { continue }
            let files = entries
                .filter {
                    ["htm", "html"].contains($0.pathExtension.lowercased())
                        && $0.lastPathComponent.hasPrefix(prefix)
                }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if let f = files.first { return f }
        }
        return nil
    }

    /// US-GAAP連結の財務諸表本表 HTML。年次(asr)は 0105010＝第５経理の状況、
    /// 半期(q2r)は 0104010＝第４経理の状況（`USGAAPHtmlFields`・`USGAAPStatementHtml` 共用）。
    static func findUSGAAPStatementHtml(in xbrlDir: URL) -> URL? {
        findHtmlByPrefix(in: xbrlDir, prefix: "0105010")
            ?? findHtmlByPrefix(in: xbrlDir, prefix: "0104010")
    }

    /// XBRL ディレクトリからインスタンス文書（.xml / .xbrl）を返す。
    /// ラベル・プレゼンテーション・計算・定義リンクベースは除外する。
    static func findXbrlFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        let excludeSuffixes = ["_lab", "_pre", "_cal", "_def"]
        var result: [URL] = []
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            if ext == "xml" {
                if !excludeSuffixes.contains(where: { name.contains($0) }) {
                    result.append(url)
                }
            } else if ext == "xbrl" {
                result.append(url)
            }
        }
        return result
    }

    private static func linkbaseXmlFiles(in dir: URL, suffix: String) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if url.pathExtension.lowercased() == "xml" && name.contains(suffix) {
                result.append(url)
            }
        }
        return result
    }

    // MARK: Linkbase Loaders

    /// ラベルリンクベースから {local_tag: Japanese label} を作る。同一ディレクトリはキャッシュを返す。
    static func loadLabelsByTag(in dir: URL) -> [String: String] {
        _cacheLock.lock()
        if let cached = _labelCache[dir] { _cacheLock.unlock(); return cached }
        _cacheLock.unlock()

        var labelsByTag: [String: String] = [:]
        for xmlFile in linkbaseXmlFiles(in: dir, suffix: "_lab") {
            guard let data = try? Data(contentsOf: xmlFile) else { continue }
            let parser = LabelLinkbaseParser()
            let xmlParser = XMLParser(data: data)
            xmlParser.delegate = parser
            xmlParser.parse()
            for (tag, text) in parser.labelsByTag {
                labelsByTag[tag] = text
            }
        }
        // 提出書類自身のラベルリンクベースには拡張タグの分しか同梱されない（標準タクソノミ側は
        // 外部参照のみでファイル自体は含まれない）。標準タグは `loadStandardTaxonomyLabels()` で
        // 補完する（提出書類側のラベルを優先し、無い場合のみ埋める）。
        for (tag, label) in loadStandardTaxonomyLabels() where labelsByTag[tag] == nil {
            labelsByTag[tag] = label
        }

        _cacheLock.lock()
        _labelCache.insert(labelsByTag, forKey: dir)
        _cacheLock.unlock()
        return labelsByTag
    }

    /// 内訳取り込み（employees / RD / goodwill）向けラベル。`ReportableSegmentsMember` の
    /// プレゼンテーション直下がただ1つの報告セグメント member なら、その日本語ラベルで親を上書きする。
    /// 実データ: エーザイ S100YB05 は親 fact に医薬品事業 9,832 人が載る。
    static func breakdownMemberLabels(in dir: URL) -> [String: String] {
        var labels = loadLabelsByTag(in: dir)
        if let sole = soleReportableSegmentChildLabel(in: dir, labelsByTag: labels) {
            labels["ReportableSegmentsMember"] = sole
        }
        return labels
    }

    static func soleReportableSegmentChildLabel(in dir: URL, labelsByTag: [String: String]) -> String? {
        var children = Set<String>()
        for roleParents in loadPresentationParents(in: dir).values {
            for (tag, parents) in roleParents where parents.contains("ReportableSegmentsMember") {
                children.insert(tag)
            }
        }
        children.remove("ReportableSegmentsMember")
        guard children.count == 1, let child = children.first else { return nil }
        return labelsByTag[child]
    }

    /// ラベルリンクベースから {local_tag: {ラベルロールURI: テキスト}} を作る（`loadLabelsByTag` の
    /// ロール別・非収束版）。`preferredLabel`（presentation linkbase の presentationArc 属性。合計行・
    /// 期首/期末残高等でどのロールのラベルを使うべきかを示す）に応じて Statement 取り込み Statement が正しい
    /// バリアントを選ぶために使う。同一ディレクトリはキャッシュを返す。
    static func loadLabelRoleVariants(in dir: URL) -> [String: [String: String]] {
        _cacheLock.lock()
        if let cached = _labelRoleVariantsCache[dir] { _cacheLock.unlock(); return cached }
        _cacheLock.unlock()

        var variants: [String: [String: String]] = [:]
        for xmlFile in linkbaseXmlFiles(in: dir, suffix: "_lab") {
            guard let data = try? Data(contentsOf: xmlFile) else { continue }
            let parser = LabelLinkbaseParser()
            let xmlParser = XMLParser(data: data)
            xmlParser.delegate = parser
            xmlParser.parse()
            for (tag, roleMap) in parser.labelsByTagAndRole {
                for (role, text) in roleMap {
                    variants[tag, default: [:]][role] = text
                }
            }
        }
        for (tag, roleMap) in loadStandardTaxonomyLabelRoleVariants() {
            for (role, text) in roleMap where variants[tag]?[role] == nil {
                variants[tag, default: [:]][role] = text
            }
        }

        _cacheLock.lock()
        _labelRoleVariantsCache.insert(variants, forKey: dir)
        _cacheLock.unlock()
        return variants
    }

    /// 標準タクソノミ（EDINET が公開する GAAP/IFRS）のラベルリンクベースから {tag: 日本語標準ラベル} を作る。
    /// `assets/taxonomy/{GAAP,IFRS}/*.zip`（ユーザーが EDINET から取得し配置する。git 管理外・
    /// `.gitignore` 参照）の最新版（ファイル名の日付が最大のもの）のみを使う。各 zip には現行版と
    /// 廃止済み要素の両方のラベルリンクベースが含まれるため、最新版1本で実データ上ほぼ全タグを
    /// カバーできる（実データ検証: トヨタ・デンソー・任天堂で拡張タグ以外の未解決ゼロ）。
    /// `assets/taxonomy` が存在しない環境（CI・本番等）では空辞書を返し、既存の「ラベル未解決」表示に
    /// フォールバックする（クラッシュしない）。プロセス内でメモ化する。
    static func loadStandardTaxonomyLabels() -> [String: String] {
        standardTaxonomyLabels().collapsed
    }

    /// 標準タクソノミのラベルを {tag: {ラベルロールURI: テキスト}} の形（ロール別）で返す。
    /// `preferredLabel`（合計行・期首/期末残高等）に応じたラベル選択に使う（Statement 取り込み Statement 専用、
    /// `loadLabelRoleVariants` 参照）。
    static func loadStandardTaxonomyLabelRoleVariants() -> [String: [String: String]] {
        standardTaxonomyLabels().variants
    }

    private static func standardTaxonomyLabels() -> (
        collapsed: [String: String], variants: [String: [String: String]]
    ) {
        _standardTaxonomyLock.lock()
        if let cached = _standardTaxonomyLabelsCache { _standardTaxonomyLock.unlock(); return cached }
        _standardTaxonomyLock.unlock()

        let result = buildStandardTaxonomyLabels()
        _standardTaxonomyLock.lock()
        _standardTaxonomyLabelsCache = result
        _standardTaxonomyLock.unlock()
        return result
    }

    private static func buildStandardTaxonomyLabels() -> (
        collapsed: [String: String], variants: [String: [String: String]]
    ) {
        guard let taxonomyDir = resolveAssetFileURL(filename: "taxonomy") else { return ([:], [:]) }

        var collapsed: [String: String] = [:]
        var variants: [String: [String: String]] = [:]
        for subdir in ["GAAP", "IFRS"] {
            guard let zipURL = latestTaxonomyZip(
                in: taxonomyDir.appendingPathComponent(subdir, isDirectory: true))
            else { continue }
            guard let extracted = try? extractTaxonomyZip(zipURL) else { continue }
            defer { try? FileManager.default.removeItem(at: extracted) }
            let (fileCollapsed, fileVariants) = parseTaxonomyLabels(in: extracted)
            for (tag, label) in fileCollapsed where collapsed[tag] == nil {
                collapsed[tag] = label
            }
            for (tag, roleMap) in fileVariants {
                for (role, text) in roleMap where variants[tag]?[role] == nil {
                    variants[tag, default: [:]][role] = text
                }
            }
        }
        return (collapsed, variants)
    }

    /// ファイル名末尾の日付（例: `JPPFS_20251101.zip`）が最大の zip を選ぶ。文字列比較で十分
    /// （8桁数字の日付は辞書順=数値順）。
    private static func latestTaxonomyZip(in dir: URL) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        else { return nil }
        return entries
            .filter { $0.pathExtension.lowercased() == "zip" }
            .max { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func extractTaxonomyZip(_ zipURL: URL) throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("blt-taxonomy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: zipURL, to: dest)
        return dest
    }

    /// 展開済みタクソノミディレクトリ配下の全 `*_lab.xml`（英語版 `-en` は除く）を走査する。
    /// 現行版・廃止済み版（`deprecated/`）双方のラベルリンクベースが対象。
    private static func parseTaxonomyLabels(
        in dir: URL
    ) -> (collapsed: [String: String], variants: [String: [String: String]]) {
        var collapsed: [String: String] = [:]
        var variants: [String: [String: String]] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil)
        else { return (collapsed, variants) }
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            guard name.hasSuffix("_lab.xml"), !name.contains("-en") else { continue }
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            let parser = LabelLinkbaseParser()
            let xmlParser = XMLParser(data: data)
            xmlParser.delegate = parser
            xmlParser.parse()
            for (tag, text) in parser.labelsByTag where collapsed[tag] == nil {
                collapsed[tag] = text
            }
            for (tag, roleMap) in parser.labelsByTagAndRole {
                for (role, text) in roleMap where variants[tag]?[role] == nil {
                    variants[tag, default: [:]][role] = text
                }
            }
        }
        return (collapsed, variants)
    }

    /// プレゼンテーションリンクベースから {local_tag: roleURI list} を作る。同一ディレクトリはキャッシュを返す。
    static func loadRolesByTag(in dir: URL) -> [String: [String]] {
        _cacheLock.lock()
        if let cached = _roleCache[dir] { _cacheLock.unlock(); return cached }
        _cacheLock.unlock()

        var roleSetsByTag: [String: Set<String>] = [:]
        for xmlFile in linkbaseXmlFiles(in: dir, suffix: "_pre") {
            guard let data = try? Data(contentsOf: xmlFile) else { continue }
            let parser = PresentationLinkbaseParser()
            let xmlParser = XMLParser(data: data)
            xmlParser.delegate = parser
            xmlParser.parse()
            for (tag, roles) in parser.roleSetsByTag {
                roleSetsByTag[tag, default: []].formUnion(roles)
            }
        }

        let result = roleSetsByTag.mapValues { Array($0).sorted() }
        _cacheLock.lock()
        _roleCache.insert(result, forKey: dir)
        _cacheLock.unlock()
        return result
    }

    /// プレゼンテーションリンクベースから {roleURI: {local_tag: 表示順}} を作る。
    /// 表示順は role 内の presentationArc（`order` 属性）を深さ優先で辿った 0 始まりの通し番号。
    /// 同一ディレクトリはキャッシュを返す。role が複数ファイルに跨って定義されることは実データ上
    /// 想定していないため、同一 role が複数ファイルに現れた場合は最初に見つかったファイルの木を採用する。
    static func loadPresentationOrder(in dir: URL) -> [String: [String: Int]] {
        loadPresentationOrders(in: dir).defaultOrder
    }

    /// 期首残高行（`preferredLabel=periodStartLabel`）の表示順。無いタグは空。
    static func loadPresentationPeriodStartOrder(in dir: URL) -> [String: [String: Int]] {
        loadPresentationOrders(in: dir).periodStartOrder
    }

    /// 期末残高行（`preferredLabel=periodEndLabel`）の表示順。無いタグは空。
    static func loadPresentationPeriodEndOrder(in dir: URL) -> [String: [String: Int]] {
        loadPresentationOrders(in: dir).periodEndOrder
    }

    private static func loadPresentationOrders(in dir: URL) -> (
        defaultOrder: [String: [String: Int]],
        periodStartOrder: [String: [String: Int]],
        periodEndOrder: [String: [String: Int]]
    ) {
        _cacheLock.lock()
        if let cached = _presentationOrderCache[dir],
            let periodStart = _presentationPeriodStartOrderCache[dir],
            let periodEnd = _presentationPeriodEndOrderCache[dir]
        {
            _cacheLock.unlock()
            return (cached, periodStart, periodEnd)
        }
        _cacheLock.unlock()

        var orderByRoleTag: [String: [String: Int]] = [:]
        var periodStartByRoleTag: [String: [String: Int]] = [:]
        var periodEndByRoleTag: [String: [String: Int]] = [:]
        for xmlFile in linkbaseXmlFiles(in: dir, suffix: "_pre") {
            guard let data = try? Data(contentsOf: xmlFile) else { continue }
            let parser = PresentationLinkbaseParser()
            let xmlParser = XMLParser(data: data)
            xmlParser.delegate = parser
            xmlParser.parse()
            for (role, tagOrder) in parser.orderByRoleTag where orderByRoleTag[role] == nil {
                orderByRoleTag[role] = tagOrder
            }
            for (role, tagOrder) in parser.periodStartOrderByRoleTag
            where periodStartByRoleTag[role] == nil {
                periodStartByRoleTag[role] = tagOrder
            }
            for (role, tagOrder) in parser.periodEndOrderByRoleTag where periodEndByRoleTag[role] == nil {
                periodEndByRoleTag[role] = tagOrder
            }
        }

        _cacheLock.lock()
        _presentationOrderCache.insert(orderByRoleTag, forKey: dir)
        _presentationPeriodStartOrderCache.insert(periodStartByRoleTag, forKey: dir)
        _presentationPeriodEndOrderCache.insert(periodEndByRoleTag, forKey: dir)
        _cacheLock.unlock()
        return (orderByRoleTag, periodStartByRoleTag, periodEndByRoleTag)
    }

    /// プレゼンテーションリンクベースから {roleURI: {local_tag: 直接の親タグ集合}} を作る。
    /// `loadPresentationOrder` と同じ presentationArc からタグ単位の親を辿れるように構築する
    /// （`StatementClassifier` の BS/CF セクション判定 [資産/負債/純資産、営業/投資/財務] で使用）。
    /// 同一タグが役割内で複数回 `<loc>` される場合（明細の見出しとして root に立つ出現と、上位ツリーから
    /// 参照される出現が両方あるケース、実データ検証: ソニー6758 IFRS の
    /// `ChangesInWorkingCapitalOpeCFIFRSAbstract`）は、双方の出現から見つかった親タグを集合として
    /// 保持する（タグ単位の集合で親を持たせることで、真の親を持つ出現側の情報を失わない）。
    /// 同一ディレクトリはキャッシュを返す。
    static func loadPresentationParents(in dir: URL) -> [String: [String: Set<String>]] {
        _cacheLock.lock()
        if let cached = _presentationParentsCache[dir] { _cacheLock.unlock(); return cached }
        _cacheLock.unlock()

        var parentTagsByRoleTag: [String: [String: Set<String>]] = [:]
        for xmlFile in linkbaseXmlFiles(in: dir, suffix: "_pre") {
            guard let data = try? Data(contentsOf: xmlFile) else { continue }
            let parser = PresentationLinkbaseParser()
            let xmlParser = XMLParser(data: data)
            xmlParser.delegate = parser
            xmlParser.parse()
            for (role, parents) in parser.parentTagsByRoleTag where parentTagsByRoleTag[role] == nil {
                parentTagsByRoleTag[role] = parents
            }
        }

        _cacheLock.lock()
        _presentationParentsCache.insert(parentTagsByRoleTag, forKey: dir)
        _cacheLock.unlock()
        return parentTagsByRoleTag
    }

    /// プレゼンテーションリンクベースから {roleURI: {local_tag: preferredLabel のロールURI}} を作る。
    /// 合計行・期首/期末残高等でどのラベルロールを使うべきかの指示（`loadLabelRoleVariants` と
    /// 組み合わせて使う）。同一ディレクトリはキャッシュを返す。
    static func loadPreferredLabelRoles(in dir: URL) -> [String: [String: String]] {
        _cacheLock.lock()
        if let cached = _preferredLabelRolesCache[dir] { _cacheLock.unlock(); return cached }
        _cacheLock.unlock()

        var preferredLabelByRoleTag: [String: [String: String]] = [:]
        for xmlFile in linkbaseXmlFiles(in: dir, suffix: "_pre") {
            guard let data = try? Data(contentsOf: xmlFile) else { continue }
            let parser = PresentationLinkbaseParser()
            let xmlParser = XMLParser(data: data)
            xmlParser.delegate = parser
            xmlParser.parse()
            for (role, labels) in parser.preferredLabelByRoleTag where preferredLabelByRoleTag[role] == nil {
                preferredLabelByRoleTag[role] = labels
            }
        }

        _cacheLock.lock()
        _preferredLabelRolesCache.insert(preferredLabelByRoleTag, forKey: dir)
        _cacheLock.unlock()
        return preferredLabelByRoleTag
    }

    /// 計算リンクベース（`_cal.xml`）から {roleURI: {local_tag（合計行）: 構成要素}} を作る。
    /// `summation-item` arc の `weight`（±1）付きで、presentation linkbase とは独立に
    /// 「二重計上せず合計を検算・再構成できる」ことを保証する（presentation の親子関係は表示上の
    /// ネストでしかなく計算の正しさを保証しない。`docs/statement.md`
    /// docs/statement.md 参照）。presentation と同じく、同じ sectionType に複数 role（IFRS連結用・
    /// J-GAAP個別用等）が対応することがあるため role ごとに分けて持ち、`StatementClassifier` が
    /// `primaryRole`（presentation のカバレッジ基準で選んだのと同じ role）で1つに絞って使う。
    /// 同一ディレクトリはキャッシュを返す。
    static func loadCalculationComponents(in dir: URL) -> [String: [String: [CalcComponent]]] {
        _cacheLock.lock()
        if let cached = _calculationComponentsCache[dir] { _cacheLock.unlock(); return cached }
        _cacheLock.unlock()

        var componentsByRoleTag: [String: [String: [CalcComponent]]] = [:]
        for xmlFile in linkbaseXmlFiles(in: dir, suffix: "_cal") {
            guard let data = try? Data(contentsOf: xmlFile) else { continue }
            let parser = CalculationLinkbaseParser()
            let xmlParser = XMLParser(data: data)
            xmlParser.delegate = parser
            xmlParser.parse()
            for (role, components) in parser.componentsByRoleTag where componentsByRoleTag[role] == nil {
                componentsByRoleTag[role] = components
            }
        }

        _cacheLock.lock()
        _calculationComponentsCache.insert(componentsByRoleTag, forKey: dir)
        _cacheLock.unlock()
        return componentsByRoleTag
    }

    // MARK: Fact Collection

    /// XMLファイルから {local_tag: {contextRef: XbrlFact}} の辞書を返す。
    static func collectNumericFacts(
        in file: URL,
        allowedTags: Set<String>? = nil,
        nilAsZero: Bool = false,
        labelsByTag: [String: String] = [:],
        rolesByTag: [String: [String]] = [:],
        orderByRoleTag: [String: [String: Int]] = [:],
        periodStartOrderByRoleTag: [String: [String: Int]] = [:],
        periodEndOrderByRoleTag: [String: [String: Int]] = [:]
    ) -> XbrlFactIndex {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        let delegate = XBRLNumericsParser(
            allowedTags: allowedTags,
            nilAsZero: nilAsZero,
            labelsByTag: labelsByTag,
            rolesByTag: rolesByTag,
            orderByRoleTag: orderByRoleTag,
            periodStartOrderByRoleTag: periodStartOrderByRoleTag,
            periodEndOrderByRoleTag: periodEndOrderByRoleTag,
            sourceFile: file.lastPathComponent
        )
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.results
    }

    /// XMLファイルから {local_tag: {contextRef: value}} の辞書を返す。
    static func collectNumericElements(
        in file: URL,
        allowedTags: Set<String>? = nil,
        nilAsZero: Bool = false
    ) -> XbrlTagElements {
        factIndexToNumericElements(collectNumericFacts(in: file, allowedTags: allowedTags, nilAsZero: nilAsZero))
    }

    /// XBRLディレクトリ内の全数値 fact をメタ情報付きで返す。
    /// 同一 `dir` × `nilAsZero` はプロセス内 FIFO に載せる（financials 組立や notes が
    /// 同じ展開パスへ何度も収集するため。ラベルキャッシュと同容量・同前提）。
    static func collectAllNumericFacts(in dir: URL, nilAsZero: Bool = true) -> XbrlFactIndex {
        let key = NumericFactCacheKey(dir: dir, nilAsZero: nilAsZero)
        _cacheLock.lock()
        if let hit = _numericFactCache[key] {
            _cacheLock.unlock()
            return hit
        }
        _cacheLock.unlock()

        var allFacts: XbrlFactIndex = [:]
        let labelsByTag = loadLabelsByTag(in: dir)
        let rolesByTag = loadRolesByTag(in: dir)
        let orders = loadPresentationOrders(in: dir)
        for file in findXbrlFiles(in: dir) {
            for (tag, ctxMap) in collectNumericFacts(
                in: file,
                allowedTags: nil,
                nilAsZero: nilAsZero,
                labelsByTag: labelsByTag,
                rolesByTag: rolesByTag,
                orderByRoleTag: orders.defaultOrder,
                periodStartOrderByRoleTag: orders.periodStartOrder,
                periodEndOrderByRoleTag: orders.periodEndOrder
            ) {
                for (ctx, fact) in ctxMap {
                    allFacts[tag, default: [:]][ctx] = fact
                }
            }
        }
        _cacheLock.lock()
        _numericFactCache.insert(allFacts, forKey: key)
        _cacheLock.unlock()
        return allFacts
    }

    /// XBRLディレクトリ内の全ファイルを一括パースし、全タグの数値要素を返す。
    static func collectAllNumericElements(in dir: URL, nilAsZero: Bool = true) -> XbrlTagElements {
        factIndexToNumericElements(collectAllNumericFacts(in: dir, nilAsZero: nilAsZero))
    }

    // MARK: Index Transforms

    /// fact index を既存抽出器互換の {tag: {contextRef: value}} に変換する。
    static func factIndexToNumericElements(_ facts: XbrlFactIndex) -> XbrlTagElements {
        facts.mapValues { ctxMap in ctxMap.mapValues { $0.value } }
    }

    /// statement/role section を優先して fact index を絞り込む。
    static func filterFactIndexBySections(
        _ facts: XbrlFactIndex,
        preferred: [String],
        fallback: [String] = []
    ) -> XbrlFactIndex {
        func filter(sections: [String]) -> XbrlFactIndex {
            let sectionSet = Set(sections)
            var result: XbrlFactIndex = [:]
            for (tag, ctxMap) in facts {
                for (ctx, fact) in ctxMap {
                    let factSections = factSectionSet(fact)
                    guard !factSections.isDisjoint(with: sectionSet) else { continue }
                    result[tag, default: [:]][ctx] = fact
                }
            }
            return result
        }
        let pref = filter(sections: preferred)
        if !pref.isEmpty { return pref }
        if !fallback.isEmpty { return filter(sections: fallback) }
        return [:]
    }

    private static func factSectionSet(_ fact: XbrlFact) -> Set<String> {
        var result = Set<String>()
        if let s = fact.section { result.insert(s) }
        if let ss = fact.sections { result.formUnion(ss) }
        return result
    }

    // MARK: IFRS TextBlock

    /// IFRS Summary型XBRLのTextBlock HTMLテーブルをパースする。
    /// ラベル → (当期値, 前期値) を返す。値は百万円単位。
    static func extractIfrsTextblockTable(
        in dir: URL,
        textblockTag: String
    ) -> [String: (current: Double?, prior: Double?)] {
        guard let htmlContent = extractTextblockHtml(in: dir, textblockTag: textblockTag),
              let soup = try? SwiftSoup.parse(htmlContent),
              let rows = try? soup.select("tr") else { return [:] }

        var result: [String: (current: Double?, prior: Double?)] = [:]
        for row in rows {
            guard let cells = try? row.select("td"), cells.count >= 3 else { continue }
            guard let label = try? cells.first()?.text(trimAndNormaliseWhitespace: true),
                  !label.isEmpty else { continue }
            let dataCells = Array(cells.dropFirst())
            guard dataCells.count >= 2 else { continue }
            let currentV = parseTextblockCellValue(try? dataCells.last?.text())
            let priorV = parseTextblockCellValue(try? dataCells[dataCells.count - 2].text())
            if currentV != nil || priorV != nil {
                result[label] = (currentV, priorV)
            }
        }
        return result
    }

    /// 指定タグの TextBlock 要素内のHTML（エンティティ復号済み）を最初に一致したファイルから返す。
    static func extractTextblockHtml(in dir: URL, textblockTag: String) -> String? {
        let pattern = try? NSRegularExpression(
            pattern: "<[^>]*:" + NSRegularExpression.escapedPattern(for: textblockTag) + "(?:\\s|>|/)[^>]*>(.*?)</[^>]*:" + NSRegularExpression.escapedPattern(for: textblockTag) + "[^>]*>",
            options: [.dotMatchesLineSeparators]
        )
        for xbrlFile in findXbrlFiles(in: dir) {
            guard let raw = try? String(contentsOf: xbrlFile, encoding: .utf8) else { continue }
            guard let match = pattern?.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                  let range = Range(match.range(at: 1), in: raw) else { continue }
            return String(raw[range]).htmlEntityDecoded
        }
        return nil
    }

    /// TextBlock 内 HTML 表セルの数値テキスト → Double（百万円単位の生値）。△/▲ は負、－ は nil。
    /// 末尾の "%"／"％" は除去する（実データ検証2026-08-03、メルカリ S100RX8V の平均利率列は
    /// "0.39%" のように単位付きで書かれる会社があり、付けたまま `Double()` に渡すと nil になる）。
    static func parseTextblockCellValue(_ text: String?) -> Double? {
        guard let t = text else { return nil }
        var s = t.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "　", with: "")
            .replacingOccurrences(of: " ", with: "")
        if s.hasSuffix("%") || s.hasSuffix("％") { s.removeLast() }
        if s.isEmpty || ["－", "-", "—", "―"].contains(s) { return nil }
        let negative = s.hasPrefix("△") || s.hasPrefix("▲")
        s = s.replacingOccurrences(of: "△", with: "").replacingOccurrences(of: "▲", with: "")
        s = s.replacingOccurrences(of: ",", with: "")
        guard let val = Double(s) else { return nil }
        return negative ? -val : val
    }

    // MARK: HTML Label Extraction

    /// soup の全 <tr> を走査し label_map に一致する行の当期/前期値を返す。
    static func extractHtmlLabels(
        from element: Element,
        labelMap: [String: String]
    ) -> FieldSet {
        var fieldSet: FieldSet = [:]
        var remaining = Set(labelMap.keys)

        // 仮想タグ → 対応ラベルの集合（一括除去用）
        var tagToLabels: [String: Set<String>] = [:]
        for (lbl, vtag) in labelMap {
            tagToLabels[vtag, default: []].insert(lbl)
        }

        guard let rows = try? element.select("tr") else { return fieldSet }
        for row in rows {
            guard !remaining.isEmpty else { break }
            guard let cells = try? row.select("td, th"), !cells.isEmpty else { continue }
            let texts = cells.array().compactMap { try? $0.text(trimAndNormaliseWhitespace: true) }
                .map { $0.replacingOccurrences(of: "\u{00A0}", with: " ") }
            guard !texts.isEmpty else { continue }

            var matched: String?
            for label in remaining where texts[0] == label { matched = label; break }
            if matched == nil {
                for label in remaining.sorted(by: { $0.count > $1.count }) {
                    if texts[0].contains(label) { matched = label; break }
                }
            }
            guard let lbl = matched else { continue }

            let numbers = texts.map { parseHtmlNumber($0) }
            let allNums = numbers.compactMap { $0 }
            guard !allNums.isEmpty else { continue }
            let found = filterFinancialTableAmounts(allNums)
            let current = found.last! * Financial.millionYen
            let prior: Double? = found.count >= 2 ? found[found.count - 2] * Financial.millionYen : nil
            let vtag = labelMap[lbl]!
            fieldSet[vtag] = FieldValue(current: current, prior: prior)
            remaining.subtract(tagToLabels[vtag] ?? [])
        }
        return fieldSet
    }
}

// MARK: - SAX Parsers (private)

private final class XBRLNumericsParser: NSObject, XMLParserDelegate {
    var results: XbrlFactIndex = [:]

    private let allowedTags: Set<String>?
    private let nilAsZero: Bool
    private let labelsByTag: [String: String]
    private let rolesByTag: [String: [String]]
    private let orderByRoleTag: [String: [String: Int]]
    private let periodStartOrderByRoleTag: [String: [String: Int]]
    private let periodEndOrderByRoleTag: [String: [String: Int]]
    private let sourceFile: String

    private var currentLocalTag = ""
    private var currentCtx = ""
    private var currentText = ""
    private var currentAttrs: [String: String] = [:]
    private var capturing = false

    init(
        allowedTags: Set<String>?,
        nilAsZero: Bool,
        labelsByTag: [String: String],
        rolesByTag: [String: [String]],
        orderByRoleTag: [String: [String: Int]] = [:],
        periodStartOrderByRoleTag: [String: [String: Int]] = [:],
        periodEndOrderByRoleTag: [String: [String: Int]] = [:],
        sourceFile: String
    ) {
        self.allowedTags = allowedTags
        self.nilAsZero = nilAsZero
        self.labelsByTag = labelsByTag
        self.rolesByTag = rolesByTag
        self.orderByRoleTag = orderByRoleTag
        self.periodStartOrderByRoleTag = periodStartOrderByRoleTag
        self.periodEndOrderByRoleTag = periodEndOrderByRoleTag
        self.sourceFile = sourceFile
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
        if let allowed = allowedTags, !allowed.contains(localTag) { return }
        guard let ctx = attributeDict["contextRef"], !ctx.isEmpty else { return }
        currentLocalTag = localTag
        currentCtx = ctx
        currentText = ""
        currentAttrs = attributeDict
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

        var value = XBRLUtils.parseXbrlValue(currentText)
        if value == nil && nilAsZero {
            let nilVal = currentAttrs["xsi:nil"] ?? currentAttrs["nil"]
            if nilVal?.lowercased() == "true" { value = 0.0 }
        }
        guard let v = value else { return }

        let roles = rolesByTag[currentLocalTag] ?? []
        let sections = roles.map { XBRLUtils.sectionNameFromRole($0) }

        var fact = XbrlFact(
            tag: currentLocalTag,
            contextRef: currentCtx,
            value: v,
            consolidation: XBRLUtils.inferConsolidation(contextRef: currentCtx, roles: roles)
        )
        fact.unitRef = currentAttrs["unitRef"]
        fact.decimals = currentAttrs["decimals"]
        if !roles.isEmpty { fact.role = roles[0]; fact.roles = roles }
        if !sections.isEmpty { fact.section = sections[0]; fact.sections = sections }
        fact.label = labelsByTag[currentLocalTag]
        fact.sourceFile = sourceFile

        var orderByRole: [String: Int] = [:]
        let usePeriodStart =
            ContextHelpers.isConsolidatedPriorInstant(currentCtx)
            || ContextHelpers.isNonConsolidatedPriorInstant(currentCtx)
        let usePeriodEnd =
            ContextHelpers.isConsolidatedInstant(currentCtx)
            || ContextHelpers.isNonConsolidatedInstant(currentCtx)
        for r in roles {
            let resolved: Int?
            if usePeriodStart {
                resolved =
                    periodStartOrderByRoleTag[r]?[currentLocalTag]
                    ?? orderByRoleTag[r]?[currentLocalTag]
            } else if usePeriodEnd {
                resolved =
                    periodEndOrderByRoleTag[r]?[currentLocalTag]
                    ?? orderByRoleTag[r]?[currentLocalTag]
            } else {
                resolved = orderByRoleTag[r]?[currentLocalTag]
            }
            if let o = resolved { orderByRole[r] = o }
        }
        if !orderByRole.isEmpty { fact.orderByRole = orderByRole }

        results[currentLocalTag, default: [:]][currentCtx] = fact
    }
}

private final class LabelLinkbaseParser: NSObject, XMLParserDelegate {
    var labelsByTag: [String: String] = [:]
    /// {tag: {ラベルロールURI: テキスト}}。`labelsByTag`（標準ラベル1つに収束させたもの）とは別に
    /// 全ロールを保持する。`preferredLabel`（合計行・期首/期末残高等）でロール別に異なるラベルを
    /// 選ぶ必要がある Statement 取り込み Statement 専用（`loadLabelRoleVariants` 参照）。
    var labelsByTagAndRole: [String: [String: String]] = [:]

    private var locByLabel: [String: String] = [:]
    private var labelTextByResource: [String: (role: String, text: String)] = [:]
    private var arcs: [(from: String, to: String)] = []

    private var capturingLabel = false
    private var currentXlinkLabel = ""
    private var currentRole = ""
    private var currentText = ""

    private let roleLabel = "http://www.xbrl.org/2003/role/label"

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        capturingLabel = false
        currentText = ""
        let local = XBRLUtils.localName(of: elementName)

        switch local {
        case "loc":
            if let xlinkLabel = attributeDict["xlink:label"], let href = attributeDict["xlink:href"] {
                locByLabel[xlinkLabel] = XBRLUtils.conceptLocalName(from: href)
            }
        case "label":
            let lang = attributeDict["xml:lang"]
            if let l = lang, l != "ja" { return }
            currentXlinkLabel = attributeDict["xlink:label"] ?? ""
            currentRole = attributeDict["xlink:role"] ?? ""
            capturingLabel = true
        case "labelArc":
            if let from = attributeDict["xlink:from"], let to = attributeDict["xlink:to"] {
                arcs.append((from: from, to: to))
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturingLabel { currentText += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard capturingLabel, XBRLUtils.localName(of: elementName) == "label" else { return }
        capturingLabel = false
        let text = currentText.trimmingCharacters(in: .whitespaces)
        if !currentXlinkLabel.isEmpty && !text.isEmpty {
            labelTextByResource[currentXlinkLabel] = (currentRole, text)
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        for (from, to) in arcs {
            guard let tag = locByLabel[from], let pair = labelTextByResource[to] else { continue }
            if pair.role == roleLabel || labelsByTag[tag] == nil {
                labelsByTag[tag] = pair.text
            }
            if labelsByTagAndRole[tag]?[pair.role] == nil {
                labelsByTagAndRole[tag, default: [:]][pair.role] = pair.text
            }
        }
    }
}

private final class PresentationLinkbaseParser: NSObject, XMLParserDelegate {
    var roleSetsByTag: [String: Set<String>] = [:]
    /// {roleURI: {local_tag: 表示順}}。role（`<presentationLink>` 単位）ごとに深さ優先走査で確定する。
    var orderByRoleTag: [String: [String: Int]] = [:]
    /// 期首残高（`periodStartLabel`）出現の表示順。
    var periodStartOrderByRoleTag: [String: [String: Int]] = [:]
    /// 期末残高（`periodEndLabel`）出現の表示順。同一タグの期首とは別番号になり得る（SS）。
    var periodEndOrderByRoleTag: [String: [String: Int]] = [:]
    /// {roleURI: {local_tag: 直接の親タグ集合}}。`loadPresentationParents` 参照。
    var parentTagsByRoleTag: [String: [String: Set<String>]] = [:]
    /// {roleURI: {local_tag: preferredLabel のロールURI}}。presentationArc の `preferredLabel`
    /// 属性（合計行・期首/期末残高等でどのラベルロールを使うべきかの指示）。
    var preferredLabelByRoleTag: [String: [String: String]] = [:]

    private var currentRole = ""
    private var inPresentationLink = false
    /// role スコープ内でのみ有効な xlink:label → タグ名（`<loc>` はリンクごとにローカルスコープ）。
    private var locTagByLabel: [String: String] = [:]
    private var arcs: [(from: String, to: String, order: Double, preferredLabel: String?)] = []

    private static func isPeriodStartLabelRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return role.hasSuffix("/periodStartLabel")
    }

    private static func isPeriodEndLabelRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return role.hasSuffix("/periodEndLabel")
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let local = XBRLUtils.localName(of: elementName)

        switch local {
        case "presentationLink":
            currentRole = attributeDict["xlink:role"] ?? ""
            inPresentationLink = !currentRole.isEmpty
            locTagByLabel = [:]
            arcs = []
        case "loc" where inPresentationLink:
            if let href = attributeDict["xlink:href"], let label = attributeDict["xlink:label"] {
                let tag = XBRLUtils.conceptLocalName(from: href)
                roleSetsByTag[tag, default: []].insert(currentRole)
                locTagByLabel[label] = tag
            }
        case "presentationArc" where inPresentationLink:
            if let from = attributeDict["xlink:from"], let to = attributeDict["xlink:to"] {
                let order = Double(attributeDict["order"] ?? "") ?? 0
                arcs.append((from: from, to: to, order: order, preferredLabel: attributeDict["preferredLabel"]))
            }
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard XBRLUtils.localName(of: elementName) == "presentationLink" else { return }
        inPresentationLink = false
        defer { locTagByLabel = [:]; arcs = [] }
        guard !currentRole.isEmpty, !locTagByLabel.isEmpty, orderByRoleTag[currentRole] == nil else { return }

        var childrenByFrom: [String: [(order: Double, to: String, preferredLabel: String?)]] = [:]
        var hasIncoming: Set<String> = []
        for arc in arcs {
            childrenByFrom[arc.from, default: []].append((arc.order, arc.to, arc.preferredLabel))
            hasIncoming.insert(arc.to)
        }
        for label in childrenByFrom.keys {
            childrenByFrom[label]?.sort { $0.order < $1.order }
        }

        // 同一概念への複数 loc（例: `Foo_2` と `Foo`）を別名として扱う。
        // EDINET 提出書類では親からの arc が `Foo_2` を指し、子への arc が `Foo` から出るパターンが
        // SS/CF で頻出する（実データ: ニチレイ2871・味の素2802 の持分変動計算書、2026-08-09）。
        // 別名をマージしないと子ツリーが別 root 扱いになり、表示順が開示とずれる。
        var labelsByTag: [String: [String]] = [:]
        for (label, tag) in locTagByLabel {
            labelsByTag[tag, default: []].append(label)
        }
        let tagsWithIncoming = Set(hasIncoming.compactMap { locTagByLabel[$0] })

        // ルート = どの arc の to にもならない label。ただし同一タグの別 loc が子として参照されて
        // いる場合は「見出し用の別名 loc」であり真の root ではないので除外する。
        let roots = locTagByLabel.keys.filter { label in
            guard !hasIncoming.contains(label) else { return false }
            if let tag = locTagByLabel[label], tagsWithIncoming.contains(tag) { return false }
            return true
        }.sorted()

        var order: [String: Int] = [:]
        var periodStartOrder: [String: Int] = [:]
        var periodEndOrder: [String: Int] = [:]
        var preferredLabel: [String: String] = [:]
        var counter = 0
        var visiting: Set<String> = []

        func visit(_ label: String, preferredLabelRole: String?) {
            guard !visiting.contains(label) else { return }
            visiting.insert(label)
            defer { visiting.remove(label) }
            if let tag = locTagByLabel[label] {
                let isPeriodStart = Self.isPeriodStartLabelRole(preferredLabelRole)
                let isPeriodEnd = Self.isPeriodEndLabelRole(preferredLabelRole)
                if isPeriodEnd {
                    // 期末残高は期首と同じタグでも別の通し番号を付ける（SS: 期首→変動→期末）。
                    if periodEndOrder[tag] == nil {
                        periodEndOrder[tag] = counter
                        counter += 1
                    }
                } else if order[tag] == nil {
                    order[tag] = counter
                    if isPeriodStart { periodStartOrder[tag] = counter }
                    counter += 1
                    if let preferredLabelRole { preferredLabel[tag] = preferredLabelRole }
                } else if isPeriodStart, periodStartOrder[tag] == nil {
                    periodStartOrder[tag] = order[tag]!
                }
            }

            // この label の子に加え、同一タグの別名 loc から出る子も辿る。
            var childArcs = childrenByFrom[label] ?? []
            if let tag = locTagByLabel[label] {
                for alias in labelsByTag[tag] ?? [] where alias != label {
                    childArcs.append(contentsOf: childrenByFrom[alias] ?? [])
                }
            }
            childArcs.sort { $0.order < $1.order }
            var seenTo: Set<String> = []
            for child in childArcs {
                guard seenTo.insert(child.to).inserted else { continue }
                visit(child.to, preferredLabelRole: child.preferredLabel)
            }
        }
        for root in roots { visit(root, preferredLabelRole: nil) }

        orderByRoleTag[currentRole] = order
        periodStartOrderByRoleTag[currentRole] = periodStartOrder
        periodEndOrderByRoleTag[currentRole] = periodEndOrder
        preferredLabelByRoleTag[currentRole] = preferredLabel

        var parentsByTag: [String: Set<String>] = [:]
        for arc in arcs {
            guard let parentTag = locTagByLabel[arc.from], let childTag = locTagByLabel[arc.to] else { continue }
            parentsByTag[childTag, default: []].insert(parentTag)
        }
        parentTagsByRoleTag[currentRole] = parentsByTag
    }
}

private final class CalculationLinkbaseParser: NSObject, XMLParserDelegate {
    /// {roleURI: {合計行タグ: 構成要素（表示順ソート済み）}}。
    var componentsByRoleTag: [String: [String: [CalcComponent]]] = [:]

    private var currentRole = ""
    private var inCalculationLink = false
    /// role スコープ内でのみ有効な xlink:label → タグ名（`<loc>` はリンクごとにローカルスコープ）。
    private var locTagByLabel: [String: String] = [:]
    private var arcs: [(from: String, to: String, weight: Double, order: Double)] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let local = XBRLUtils.localName(of: elementName)

        switch local {
        case "calculationLink":
            currentRole = attributeDict["xlink:role"] ?? ""
            inCalculationLink = !currentRole.isEmpty
            locTagByLabel = [:]
            arcs = []
        case "loc" where inCalculationLink:
            if let href = attributeDict["xlink:href"], let label = attributeDict["xlink:label"] {
                locTagByLabel[label] = XBRLUtils.conceptLocalName(from: href)
            }
        case "calculationArc" where inCalculationLink:
            if let from = attributeDict["xlink:from"], let to = attributeDict["xlink:to"] {
                let weight = Double(attributeDict["weight"] ?? "") ?? 1
                let order = Double(attributeDict["order"] ?? "") ?? 0
                arcs.append((from: from, to: to, weight: weight, order: order))
            }
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard XBRLUtils.localName(of: elementName) == "calculationLink" else { return }
        inCalculationLink = false
        defer { locTagByLabel = [:]; arcs = [] }
        // 同一 role が複数の <calculationLink>（extended link）に分割定義されるケースを
        // presentation/label と同じ「最初に見つかった方を採用」で扱う（Opus 監査で発見・修正、
        // 2026-07-31）。以前は無条件に上書きしており、後続の <calculationLink> に同じ role が
        // 現れると先に集めた arc が丸ごと失われ得た（実データでは未発生だが、XBRL の base set
        // 分割は仕様上許容されるため PresentationLinkbaseParser 側の方針に合わせる）。
        guard !currentRole.isEmpty, !locTagByLabel.isEmpty, componentsByRoleTag[currentRole] == nil else {
            return
        }

        var componentsByTag: [String: [CalcComponent]] = [:]
        var seenByTag: [String: Set<String>] = [:]
        let sortedArcs = arcs.sorted { $0.order < $1.order }
        for arc in sortedArcs {
            guard let fromTag = locTagByLabel[arc.from], let toTag = locTagByLabel[arc.to],
                arc.weight.isFinite
            else { continue }
            // 実データ上 weight は ±1 のみ確認済み（加算/控除）。非整数値は四捨五入で
            // 最も近い整数へ丸める（Opus 監査で発見・修正、2026-07-31。以前は `Int(_:)` で
            // 単純切り捨てており 0.5 が 0 になり得た）。
            let weight = Int(arc.weight.rounded())
            let dedupeKey = "\(toTag)#\(weight)"
            guard !(seenByTag[fromTag] ?? []).contains(dedupeKey) else { continue }
            seenByTag[fromTag, default: []].insert(dedupeKey)
            componentsByTag[fromTag, default: []].append(CalcComponent(tag: toTag, weight: weight))
        }
        componentsByRoleTag[currentRole] = componentsByTag
    }
}
