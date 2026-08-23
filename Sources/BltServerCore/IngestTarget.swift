// `blt-server ingest --stages <csv>` の取り込み対象選択。
// 既定（未指定）は全対象。数値 facts 永続は閉じた（BLT-23）ためここには含めない。
// `--with-facts` は残存 CLI で製品経路ではない。

import BlueTickerCore

/// ingest で実行できる対象。rawValue が `--stages` の CSV トークン。
public enum IngestTarget: String, CaseIterable, Sendable {
    /// 通期財務サマリ（company_financials）。
    case financials
    /// 有報セクション本文（company_filing_sections）。
    case filingSections = "filing-sections"
    /// 事業別・地域別内訳（company_breakdowns）。ingest は business→geography。
    /// REST/MCP read は business / geography の両軸。
    case breakdowns
    /// BS/PL/CF/SS 完全正規化（company_statements）。対象は上場全体（日経225は処理順の優先のみ）。
    case statements
    /// 財務諸表注記（company_statement_notes）。対象は日経225限定（statements の上場拡大とは独立）。
    case notes = "statement-notes"
    /// 会社アイコン（company_icons、favicon の R2 格納先メタデータ）。`BLT_R2_*` 環境変数未設定時は
    /// 対象に含めてもスキップされる（`runFactsIngestCommand` 参照）。
    case icons
}

/// `--note-types` の CSV 値を note_type の集合へ変換する（`statement-notes` ステージ専用）。
/// - `nil`（フラグ未指定）: 全 note_type。
/// - 有効なトークンのみ: その集合。
/// - 未知トークンを含む・有効トークンが 0 個: `nil`（呼び出し側で usage エラー）。
public func parseStatementNoteTypes(_ csv: String?) -> Set<String>? {
    guard let csv else { return nil }
    var result = Set<String>()
    for token in csv.split(separator: ",") {
        let value = token.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { continue }
        guard isKnownStatementNoteType(value) else { return nil }
        result.insert(value)
    }
    return result.isEmpty ? nil : result
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
