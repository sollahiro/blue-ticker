import Foundation

// MARK: - JSON 出力

func printJSON(_ value: some Encodable, pretty: Bool = true) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : []
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(value),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

func printJSONObject(_ obj: [String: Any], pretty: Bool = true) {
    let opts: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys] : []
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: opts),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

// MARK: - テーブル出力

struct TableColumn {
    let header: String
    let width: Int
    let rightAlign: Bool

    init(_ header: String, width: Int, rightAlign: Bool = false) {
        self.header = header
        self.width = width
        self.rightAlign = rightAlign
    }
}

func printTable(columns: [TableColumn], rows: [[String]]) {
    func pad(_ s: String, width: Int, right: Bool) -> String {
        let padded = right ? s.leftPad(width) : s.rightPad(width)
        return String(padded.prefix(width))
    }
    let header = columns.enumerated()
        .map { pad($1.header, width: $1.width, right: false) }
        .joined(separator: "  ")
    print(header)
    print(String(repeating: "-", count: header.count))
    for row in rows {
        let line = columns.indices.map { i in
            let val = i < row.count ? row[i] : ""
            return pad(val, width: columns[i].width, right: columns[i].rightAlign)
        }.joined(separator: "  ")
        print(line)
    }
}

private extension String {
    func rightPad(_ width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
    func leftPad(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
