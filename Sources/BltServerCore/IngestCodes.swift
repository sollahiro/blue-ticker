// `blt-server ingest --codes <csv>` の対象証券コード絞り込み。
// バグ修正確認後などに特定銘柄だけを手動・単発で先に再計算したいケース向け（定期 launchd drain には使わない）。
// `priorityCodes`（nikkei225.csv）と異なり、対象選定そのものを絞り込む（順序ではなく集合を変える）。

/// `--codes` の CSV 値を証券コード集合へ変換する。空白除去のみ行い、コード形式の妥当性検証はしない
/// （EDINET 側の secCode 由来コードと突き合わせるため、存在しないコードは自然に「対象0件」になる）。
/// `nil`（フラグ未指定）を渡すと `nil` を返す（絞り込みなし＝従来どおり全企業）。
public func parseIngestCodes(_ csv: String?) -> Set<String>? {
    guard let csv else { return nil }
    var result = Set<String>()
    for token in csv.split(separator: ",") {
        let t = token.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { continue }
        result.insert(t)
    }
    return result
}
