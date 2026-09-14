/// 折れ線を 0 軸基準で塗り分けるための点列分割。
/// 符号が変わる辺は 0 との交点で切り、各ピースが 0 を底辺にした三角／台形になる。
enum ZeroAxisFill {
    struct Vertex: Equatable {
        var position: Double
        var value: Double
    }

    /// `vertices` は位置順の折れ線。空や1点はそのまま返す。
    static func areas(_ vertices: [Vertex]) -> [[Vertex]] {
        guard vertices.count >= 2 else { return vertices.isEmpty ? [] : [vertices] }
        var areas: [[Vertex]] = []
        var current: [Vertex] = [vertices[0]]
        for vertex in vertices.dropFirst() {
            let previous = current[current.count - 1]
            if let crossing = crossingOnZero(from: previous, to: vertex) {
                current.append(crossing)
                areas.append(current)
                current = [crossing]
            }
            current.append(vertex)
        }
        if current.count >= 2 {
            areas.append(current)
        }
        return areas
    }

    /// 両端が 0 の反対側にあるとき、線形補間した 0 交点。端点が 0 なら不要。
    static func crossingOnZero(from start: Vertex, to end: Vertex) -> Vertex? {
        guard start.value * end.value < 0 else { return nil }
        let span = start.value - end.value
        let t = start.value / span
        return Vertex(
            position: start.position + t * (end.position - start.position),
            value: 0
        )
    }
}
