// `blt-server ingest --stages <csv>` のステージ選択。
// 既定（未指定）は全ステージ。Stage 3（XBRL 数値 fact）は issue #22 で停止中のため
// ここには含めず、従来どおり `--with-facts` で別制御する。

/// ingest で実行できるステージ。rawValue が `--stages` の CSV トークン。
public enum IngestStage: String, CaseIterable, Sendable {
    /// Stage 4: 通期財務サマリ（company_financials）。
    case financials = "4"
    /// Stage 4-half: 半期財務サマリ（company_half_financials）。
    case half = "4half"
    /// Stage 5: 有報セクション本文（company_filing_sections）。
    case sections = "5"
    /// Stage 6: 事業別・地域別内訳（company_breakdowns）。ingest は business→geography。
    /// REST/MCP read は business / geography の両軸。
    case breakdowns = "6"
}

/// `--stages` の CSV 値をステージ集合へ変換する。
/// - `nil`（フラグ未指定）: 全ステージ。
/// - 有効なトークンのみ（例 `"5"`, `"4,5"`, 空白許容）: その集合。
/// - 未知トークンを含む・有効トークンが 0 個（`""` や `","`）: `nil`（呼び出し側で usage エラー）。
public func parseIngestStages(_ csv: String?) -> Set<IngestStage>? {
    guard let csv else { return Set(IngestStage.allCases) }
    var result = Set<IngestStage>()
    for token in csv.split(separator: ",") {
        let t = token.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { continue }
        guard let stage = IngestStage(rawValue: t) else { return nil }
        result.insert(stage)
    }
    return result.isEmpty ? nil : result
}
