import BlueTickerCore
import FluentKit
import Foundation
import Logging
import SQLKit

/// 指定銘柄（4 桁証券コード）の 書類同期 書類を DB から引いて正規化レコードで返す。
/// EDINET の secCode は 5 桁（4 桁＋種別 1 桁）のため、`XXXX0`…`XXXX9` の等価比較で突き合わせる
/// （ライブ探索の hasPrefix(code4) と同条件。btree 索引が LIKE 前方一致に使えないロケールでも効く）。
/// `sec_code` が空の行は master の EDINETコードでも拾う（提出当日の欠落がキャッシュに残るため）。
/// EDINET フォールバックは空/`null` の `sec_code` に限る（非空の別銘柄行は混ぜない）。
/// 該当 0 件なら空配列（呼び出し側はライブ探索へフォールバック）。
/// 会社開示府令(010)のみ。同じ secCode に載る信託受益証券等(030)の 120/160 は会社の書類一覧に出さない。
package func loadStoredFilingRecords(code: String, db: Database) async throws -> [EdinetDocumentRecord] {
    let secCodes = edinetSecCodes(forIssuerCode: code)
    guard !secCodes.isEmpty else { return [] }
    let listedEdinet = await listedEdinetCode(forCode: code)
    let rows = try await EdinetDocument.query(on: db)
        .group(.or) { group in
            group.filter(\.$secCode ~~ secCodes)
            if let listedEdinet {
                group.group(.and) { fallback in
                    fallback.filter(\.$edinetCode == listedEdinet)
                    fallback.filter(.sql(emptySecCodeSQL))
                }
            }
        }
        .filter(\.$ordinanceCode == Api.ordinanceCompanyDisclosure)
        .all()
    return rows.map { $0.toRecord() }
}

/// `sec_code` が未設定（NULL / 空 / 空白のみ）。SQLite と Postgres 共通。
package let emptySecCodeSQL = SQLRaw("(sec_code IS NULL OR TRIM(sec_code) = '')")

/// 4 桁証券コードに対応する EDINET 5 桁 secCode（末尾 0–9）。
/// filings の突き合わせと外国法人・組合の既存行削除で同じ集合を使う。
package func edinetSecCodes(forIssuerCode code: String) -> [String] {
    let code4 = String(code.prefix(4)).uppercased()
    guard code4.count == 4, code4.allSatisfy({ $0.isLetter || $0.isNumber }) else { return [] }
    return (0...9).map { "\(code4)\($0)" }
}

extension EdinetDocument {
    /// DB モデル → 正規化済みレコード（read 経路でファサードへ渡す）。
    package func toRecord() -> EdinetDocumentRecord {
        EdinetDocumentRecord(
            docID: id ?? "",
            edinetCode: edinetCode,
            secCode: secCode,
            filerName: filerName,
            docTypeCode: docTypeCode,
            ordinanceCode: ordinanceCode,
            formCode: formCode,
            periodStart: periodStart,
            periodEnd: periodEnd,
            submitDateTime: submitDateTime,
            docDescription: docDescription,
            parentDocID: parentDocID)
    }

    /// 正規化済みレコードの値を自身へ写す（id は呼び出し側で設定済み）。
    package func apply(_ record: EdinetDocumentRecord) {
        edinetCode = record.edinetCode
        secCode = record.secCode
        filerName = record.filerName
        docTypeCode = record.docTypeCode
        ordinanceCode = record.ordinanceCode
        formCode = record.formCode
        periodStart = record.periodStart
        periodEnd = record.periodEnd
        submitDateTime = record.submitDateTime
        docDescription = record.docDescription
        parentDocID = record.parentDocID
    }
}
