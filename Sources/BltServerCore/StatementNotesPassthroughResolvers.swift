// 財務諸表注記取り込み の決定論 note_type のうち、Stage 4（company_financials）が有報 1 件ごとに既に計算・
// 格納している値をそのまま再公開するだけの4種（発行済株式数・研究開発費・設備投資概要・
// 自己株式取得）を解決する。いずれも `Extractors.swift` の対応する Extractor が Stage 4 側で既に
// 実行済みのため、財務諸表注記取り込み 側で同じ XBRL を再抽出しない（重複ロジック回避。`Stage6Ingest.swift` の
// `consolidatedSalesForDoc` と同型の設計判断）。
//
// dividends（決議単位のテーブル）・per_share_information（EPS/BPS/潜在株式調整後EPSの3指標）は
// 当初この passthrough 経路で実装したが、実データレビュー（2026-08-02）で注記・業績概要側が
// より豊富な情報を持つと判明したため `StatementNotesResolver`（BlueTickerCore側、XBRL直接抽出）へ
// 置き換えた。capital_expenditures_overview・issued_shares・treasury_stock_acquisition も同様の
// 置き換えを検討中（レビュー未完了時点ではこの passthrough のまま）。
//
// sga_breakdown・borrowings_schedule_cf_supplement・policy_holding_securities・PPE明細・のれん明細
// のように Stage 4 に対応値が無い note_type も、この経路ではなく別途 XBRL 直接抽出（BlueTickerCore
// 側 resolver）を実装している。

import BlueTickerCore
import Fluent

/// `code`/`docID` の Stage 4 計算結果から `extractValue` で当該 note_type の値（円・株数など、
/// note_type ごとの単位のまま）を取り出し `StatementNoteResolveResult` へ変換する。
/// Stage 4 が当該 docID をまだ計算していなければ `.failed`（次回 ingest で再試行。Stage 6 の
/// 売上参照未計算時と同じ「進展なし」扱い）。計算済みだが値が無ければ `.notApplicable(not_found)`
/// （正当欠測: 例えば当期配当が無い、または対象タグが開示されていない）。
func resolveStatementNoteFromFinancials(
    code: String, docID: String, unit: String, db: Database,
    extractValue: (FinancialsResponse) -> Double?
) async throws -> StatementNoteResolveResult {
    guard let financials = try await CompanyFinancials.find(code, on: db) else { return .failed }
    guard financials.response.hasDoc(docID) else { return .failed }
    guard let value = extractValue(financials.response) else {
        return .notApplicable(reason: statementNoteNotApplicableNotFound)
    }
    return .resolved(
        payload: StatementNotePayload(value: value, unit: unit),
        source: statementNoteSourceXbrlFacts, contentHash: String(value))
}

/// Stage 4 passthrough 6種の `StatementNoteResolveFn` を組み立てる。note_type ごとに
/// `Stage3Ingest.swift` から `runStatementNotesIngest` へそのまま渡す。DB 例外は `.failed`
/// （次回再試行）へ落とす（`error-handling.md`: サービス層は throw せず戻り値で表現する）。
enum StatementNotesFinancialsPassthroughResolvers {
    static func issuedShares(db: Database) -> StatementNoteResolveFn {
        { docID, code in
            (try? await resolveStatementNoteFromFinancials(
                code: code, docID: docID, unit: "shares", db: db,
                extractValue: { $0.issuedSharesForDoc(docID) })) ?? .failed
        }
    }

    static func researchAndDevelopment(db: Database) -> StatementNoteResolveFn {
        { docID, code in
            (try? await resolveStatementNoteFromFinancials(
                code: code, docID: docID, unit: "yen", db: db,
                extractValue: { $0.rdForDoc(docID) })) ?? .failed
        }
    }

    static func treasuryStockAcquisition(db: Database) -> StatementNoteResolveFn {
        { docID, code in
            (try? await resolveStatementNoteFromFinancials(
                code: code, docID: docID, unit: "yen", db: db,
                extractValue: { $0.treasuryStockAcquisitionForDoc(docID) })) ?? .failed
        }
    }
}
