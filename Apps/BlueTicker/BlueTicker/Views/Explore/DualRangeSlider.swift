import SwiftUI

/// 数直線上の 2 ハンドルで「以上〜以下」を選ぶ。`values` は `[下限, 上限]`。
struct DualRangeSlider: View {
    var rangeMin: Double
    var rangeMax: Double
    var step: Double
    @Binding var values: [Double]
    var formatValue: (Double) -> String
    var band: MetricBand = .none

    private let handleSize: CGFloat = 28
    private let trackHeight: CGFloat = 6

    @State private var dragging: Handle?

    private enum Handle {
        case lower
        case upper
    }

    private var span: Double { max(rangeMax - rangeMin, step) }

    private var lower: Double {
        snapped(values.count > 0 ? values[0] : rangeMin)
    }

    private var upper: Double {
        snapped(values.count > 1 ? values[1] : rangeMax)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(formatValue(lower)) 以上")
                    .foregroundStyle(band.color(for: lower))
                Text("\(formatValue(upper)) 以下")
                    .foregroundStyle(band.color(for: upper))
            }
            .font(.subheadline.monospacedDigit())
            .accessibilityLabel("\(formatValue(lower))以上、\(formatValue(upper))以下")

            GeometryReader { geo in
                let width = geo.size.width
                let midY = geo.size.height / 2
                let lowerX = x(for: lower, width: width)
                let upperX = x(for: upper, width: width)

                ZStack {
                    Capsule()
                        .fill(LinearGradient(
                            stops: trackStops,
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .opacity(0.35)
                        .frame(width: width, height: trackHeight)
                        .position(x: width / 2, y: midY)

                    Capsule()
                        .fill(LinearGradient(
                            colors: [band.color(for: lower), band.color(for: upper)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(width: max(upperX - lowerX, 0), height: trackHeight)
                        .position(x: (lowerX + upperX) / 2, y: midY)

                    handle(isLower: true)
                        .position(x: lowerX, y: midY)
                    handle(isLower: false)
                        .position(x: upperX, y: midY)
                }
                .contentShape(Rectangle())
                .highPriorityGesture(dragGesture(width: width))
            }
            .frame(height: handleSize)
        }
        .onAppear { publish(lower, upper) }
    }

    private var trackStops: [Gradient.Stop] {
        let steps = 12
        return (0...steps).map { index in
            let t = Double(index) / Double(steps)
            let value = rangeMin + t * span
            return Gradient.Stop(color: band.color(for: value), location: CGFloat(t))
        }
    }

    private func handle(isLower: Bool) -> some View {
        let value = isLower ? lower : upper
        let fill = band.color(for: value)
        return Circle()
            .fill(fill)
            .shadow(color: fill.opacity(0.55), radius: 3, y: 1)
            .overlay {
                Circle().stroke(Color.white.opacity(0.45), lineWidth: 1.5)
            }
            .frame(width: handleSize, height: handleSize)
            .accessibilityLabel(isLower ? "下限" : "上限")
            .accessibilityValue(accessibilityValue(value))
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? step : -step
                if isLower {
                    publish(min(lower + delta, upper), upper)
                } else {
                    publish(lower, max(upper + delta, lower))
                }
            }
    }

    private func accessibilityValue(_ value: Double) -> String {
        if let zone = band.zoneLabel(for: value) {
            return "\(formatValue(value))、\(zone)"
        }
        return formatValue(value)
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                let handle = dragging ?? nearestHandle(at: drag.startLocation.x, width: width)
                if dragging == nil {
                    dragging = handle
                }
                let next = value(forX: drag.location.x, width: width)
                switch handle {
                case .lower:
                    publish(min(next, upper), upper)
                case .upper:
                    publish(lower, max(next, lower))
                }
            }
            .onEnded { _ in
                dragging = nil
            }
    }

    private func nearestHandle(at rawX: CGFloat, width: CGFloat) -> Handle {
        let lowerX = x(for: lower, width: width)
        let upperX = x(for: upper, width: width)
        if abs(rawX - lowerX) == abs(rawX - upperX) {
            return rawX <= lowerX ? .lower : .upper
        }
        return abs(rawX - lowerX) < abs(rawX - upperX) ? .lower : .upper
    }

    private func x(for value: Double, width: CGFloat) -> CGFloat {
        let usable = max(width - handleSize, 1)
        return handleSize / 2 + CGFloat((value - rangeMin) / span) * usable
    }

    private func value(forX rawX: CGFloat, width: CGFloat) -> Double {
        let usable = max(width - handleSize, 1)
        let ratio = Double((rawX - handleSize / 2) / usable)
        return snapped(rangeMin + min(max(ratio, 0), 1) * span)
    }

    private func snapped(_ value: Double) -> Double {
        let clamped = min(max(value, rangeMin), rangeMax)
        guard step > 0 else { return clamped }
        let steps = ((clamped - rangeMin) / step).rounded()
        return min(max(rangeMin + steps * step, rangeMin), rangeMax)
    }

    private func publish(_ newLower: Double, _ newUpper: Double) {
        let lo = snapped(min(newLower, newUpper))
        let hi = snapped(max(newLower, newUpper))
        let next = [lo, hi]
        if values != next {
            values = next
        }
    }
}
