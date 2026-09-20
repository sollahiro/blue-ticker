import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
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

// 標準タクソノミ（GAAP/IFRS）のラベルは `assets/taxonomy` 配下の zip 群という単一の入力から
// プロセス生涯不変で決まるため、doc 単位キャッシュとは別に一度だけ計算しメモ化する。
nonisolated(unsafe) private var _standardTaxonomyLabelsCache: (
    collapsed: [String: String], variants: [String: [String: String]]
)?
private let _standardTaxonomyLock = NSLock()

extension XBRLUtils {
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

    /// 報告セグメント member の presentation 直親。`ReportableSegmentsMember` 等のラッパは除く。
    /// 内訳の「うち」（親を分割しきれない子）判定用。child local name → parent local name。
    /// 複数 role で親が割れたときは辞書順の小さい親を残す（走査順に依存させない）。
    static func operatingSegmentMemberParents(in dir: URL) -> [String: String] {
        let skipParents = Xbrl.segmentSubtotalMemberNames.union(Xbrl.segmentReconcilingMemberNames)
        var result: [String: String] = [:]
        for roleParents in loadPresentationParents(in: dir).values {
            for (child, parents) in roleParents {
                let relevant = parents.subtracting(skipParents)
                guard relevant.count == 1, let parent = relevant.first, parent != child else { continue }
                if let existing = result[child], existing != parent {
                    result[child] = min(existing, parent)
                } else {
                    result[child] = parent
                }
            }
        }
        return result
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
