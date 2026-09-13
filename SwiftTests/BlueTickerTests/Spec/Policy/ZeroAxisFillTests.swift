import Testing

@testable import BlueTickerCore

@Suite struct ZeroAxisFillTests {
    @Test func sameSignKeepsOneAreaAgainstZero() {
        let vertices = [
            ZeroAxisFill.Vertex(position: 0, value: -26.9),
            ZeroAxisFill.Vertex(position: 1, value: -18.2),
        ]
        let areas = ZeroAxisFill.areas(vertices)
        #expect(areas == [vertices])
    }

    @Test func oppositeSignsSplitIntoTwoBaselineTriangles() {
        // マネーフォワード ROE: 24/11 = -14.2%、25/11 = 2.8%
        let start = ZeroAxisFill.Vertex(position: 3, value: -14.2)
        let end = ZeroAxisFill.Vertex(position: 4, value: 2.8)
        let areas = ZeroAxisFill.areas([start, end])
        #expect(areas.count == 2)

        let crossing = ZeroAxisFill.crossingOnZero(from: start, to: end)
        #expect(crossing != nil)
        #expect(crossing?.value == 0)
        let expectedT = 14.2 / (14.2 + 2.8)
        #expect(crossing!.position == 3 + expectedT)

        #expect(areas[0] == [start, crossing!])
        #expect(areas[1] == [crossing!, end])
    }

    @Test func positiveToNegativeAlsoSplitsAtZero() {
        let start = ZeroAxisFill.Vertex(position: 0, value: 4)
        let end = ZeroAxisFill.Vertex(position: 2, value: -6)
        let areas = ZeroAxisFill.areas([start, end])
        #expect(areas.count == 2)
        #expect(areas[0].last?.value == 0)
        #expect(abs((areas[0].last?.position ?? .nan) - 0.8) < 1e-12)
        #expect(areas[1].first?.value == 0)
    }

    @Test func endpointOnZeroDoesNotInsertExtraVertex() {
        let vertices = [
            ZeroAxisFill.Vertex(position: 1, value: -5),
            ZeroAxisFill.Vertex(position: 2, value: 0),
        ]
        #expect(ZeroAxisFill.areas(vertices) == [vertices])
        #expect(ZeroAxisFill.crossingOnZero(from: vertices[0], to: vertices[1]) == nil)
    }

    @Test func twoCrossingsYieldThreeAreas() {
        let vertices = [
            ZeroAxisFill.Vertex(position: 0, value: -10),
            ZeroAxisFill.Vertex(position: 1, value: 10),
            ZeroAxisFill.Vertex(position: 2, value: -10),
        ]
        let areas = ZeroAxisFill.areas(vertices)
        #expect(areas.count == 3)
        #expect(areas.map { $0.last?.value } == [0, 0, -10])
        #expect(areas.map { $0.first?.value } == [-10, 0, 0])
        #expect(areas[0].last?.position == 0.5)
        #expect(areas[1].last?.position == 1.5)
    }

    @Test func emptyAndSingleVertex() {
        #expect(ZeroAxisFill.areas([]) == [])
        let one = [ZeroAxisFill.Vertex(position: 0, value: 1)]
        #expect(ZeroAxisFill.areas(one) == [one])
    }
}
