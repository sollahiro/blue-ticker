// `blt-server ingest --stages <csv>` の取り込み対象選択。
// 既定（未指定）は全対象。XBRL 数値 fact は issue #22 で停止中のため
// ここには含めず、従来どおり `--with-facts` で別制御する。

/// ingest で実行できる対象。rawValue が `--stages` の CSV トークン。
public enum IngestTarget: String, CaseIterable, Sendable {
    /// 通期財務サマリ（company_financials）。
    case financials
    /// 有報セクション本文（company_filing_sections）。
    case filingSections = "filing-sections"
    /// 事業別・地域別内訳（company_breakdowns）。ingest は business→geography。
    /// REST/MCP read は business / geography の両軸。
    case breakdowns
    /// BS/PL/CF 完全正規化（company_statements）。対象は日経225限定でスタート。
    case statements
    /// 財務諸表注記（company_statement_notes）。対象は statements と同じ日経225限定。
    case notes = "statement-notes"
    /// 会社アイコン（company_icons、favicon の R2 格納先メタデータ）。`BLT_R2_*` 環境変数未設定時は
    /// 対象に含めてもスキップされる（`runFactsIngestCommand` 参照）。
    case icons
}

/// `--stages` の CSV 値を取り込み対象の集合へ変換する。
/// - `nil`（フラグ未指定）: 全対象。
/// - 有効なトークンのみ（例 `"financials"`, `"financials,statements"`, 空白許容）: その集合。
/// - 未知トークンを含む・有効なトークンが 0 個（`""` や `","`）: `nil`（呼び出し側で usage エラー）。
public func parseIngestTargets(_ csv: String?) -> Set<IngestTarget>? {
    guard let csv else { return Set(IngestTarget.allCases) }
    var result = Set<IngestTarget>()
    for token in csv.split(separator: ",") {
        let value = token.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { continue }
        guard let target = IngestTarget(rawValue: value) else { return nil }
        result.insert(target)
    }
    return result.isEmpty ? nil : result
}
