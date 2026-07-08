import Foundation

/// HTML エンティティをデコードする。`&amp;` は最後に置換し、`&amp;lt;` 等の二重エンコードを壊さない。
func decodeHtmlEntities(_ text: String) -> String {
    var s = text
    let entities: [(String, String)] = [
        ("&lt;", "<"), ("&gt;", ">"),
        ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", "\u{00A0}"),
        ("&amp;", "&"),
    ]
    for (entity, char) in entities { s = s.replacingOccurrences(of: entity, with: char) }
    return s
}

extension String {
    var htmlEntityDecoded: String { decodeHtmlEntities(self) }
}
