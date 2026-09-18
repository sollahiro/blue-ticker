import ImageIO
import SwiftUI
import UIKit

struct CompanyRowView: View {
    var company: CompanyRef
    var caption: String? = nil
    var showsIcon = true
    var showsSector = true
    /// 編集中など、社名の折り返しを非編集時の幅のままにする。
    var locksNameLayout = false

    @State private var nameWidth: CGFloat?

    var body: some View {
        HStack(spacing: 12) {
            if showsIcon {
                CompanyIconView(company)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.displayName(company.name, fallback: company.code))
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                    .lineLimit(3)
                    .truncationMode(.tail)
                Text(company.code)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .frame(width: locksNameLayout ? nameWidth : nil, alignment: .leading)
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onChange(of: geo.size.width, initial: true) { _, width in
                            guard !locksNameLayout, width > 0 else { return }
                            nameWidth = width
                        }
                }
            }
            Spacer(minLength: 0)
            if showsSector, !company.sector.isEmpty {
                SectorTag(sector: company.sector, selected: true)
            }
        }
        .padding(0)
        .animation(nil, value: showsIcon)
        .animation(nil, value: showsSector)
        .animation(nil, value: locksNameLayout)
    }
}

struct SectorTag: View {
    var sector: String
    var selected: Bool = false
    var height: CGFloat? = nil
    var tint: Color = Theme.positive

    var body: some View {
        Text(sector)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, height == nil ? 6 : 0)
            .frame(height: height)
            .background(selected ? tint.opacity(0.22) : Theme.idleTab)
            .foregroundStyle(selected ? tint : .white)
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(selected ? tint : Color.clear, lineWidth: 1.5)
            }
    }
}

struct CompanyIconView: View {
    var code: String
    var url: String?
    var size: CGFloat = 36

    @State private var image: UIImage?

    init(_ company: CompanyRef, size: CGFloat = 36) {
        code = company.code
        url = company.iconURL
        self.size = size
    }

    var body: some View {
        let corner = max(6, size * 0.22)
        ZStack {
            Color.white
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.08)
            } else {
                Image(systemName: "building.2")
                    .font(.system(size: size * 0.38, weight: .medium))
                    .foregroundStyle(Color.gray.opacity(0.55))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .task(id: "\(code)|\(url ?? "")") {
            image = await CompanyIconLoader.shared.image(code: code, preferredURL: url)
        }
    }
}

/// REST の `icon_url` を優先し、無いときは公開 R2 の `company-icons/{code}.{ext}` を試す。
/// 格納の大半は ICO なので `UIImage(data:)` ではなく ImageIO で解码する。
/// 「無い」結果は `UserDefaults` に 1 日持ち、起動ごとに最大 5 回のプローブをやり直さない
/// （Feed / 検索結果の数十リクエストが本文の REST と帯域を争わないようにする）。
actor CompanyIconLoader {
    static let shared = CompanyIconLoader()

    private static let probeExtensions = ["ico", "png", "jpg", "gif", "bmp"]
    private static let missingStorageKey = "blt.icon.missing"
    private static let missingTTL: TimeInterval = 24 * 60 * 60
    private static let missingLimit = 2_000

    private var memory: [String: UIImage] = [:]
    private var missing: [String: Date]
    private var inflight: [String: Task<IconLoadOutcome, Never>] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.missingStorageKey) as? [String: Date] ?? [:]
        missing = stored.filter { now.timeIntervalSince($0.value) < Self.missingTTL }
    }

    func image(code: String, preferredURL: String?) async -> UIImage? {
        let key = cacheKey(code: code, preferredURL: preferredURL)
        if let cached = memory[key] { return cached }
        if let checkedAt = missing[key], Date().timeIntervalSince(checkedAt) < Self.missingTTL {
            return nil
        }
        if let existing = inflight[key] {
            return await existing.value.image
        }
        let task = Task { await load(code: code, preferredURL: preferredURL) }
        inflight[key] = task
        let outcome = await task.value
        inflight[key] = nil
        if let loaded = outcome.image {
            memory[key] = loaded
            if missing.removeValue(forKey: key) != nil {
                persistMissing()
            }
        } else if outcome.cacheAsMissing {
            missing[key] = Date()
            persistMissing()
        }
        return outcome.image
    }

    private func persistMissing() {
        if missing.count > Self.missingLimit {
            let oldest = missing.sorted { $0.value < $1.value }.prefix(missing.count - Self.missingLimit)
            for (key, _) in oldest {
                missing.removeValue(forKey: key)
            }
        }
        defaults.set(missing, forKey: Self.missingStorageKey)
    }

    private func load(code: String, preferredURL: String?) async -> IconLoadOutcome {
        var sawUnavailable = false
        if let preferredURL, let url = URL(string: preferredURL) {
            switch await fetchImage(url) {
            case .image(let image):
                return IconLoadOutcome(image: image, cacheAsMissing: false)
            case .unavailable:
                sawUnavailable = true
            case .notFound:
                break
            }
        }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return IconLoadOutcome(image: nil, cacheAsMissing: !sawUnavailable)
        }
        for ext in Self.probeExtensions {
            let url = APIConfiguration.defaultIconBaseURL
                .appending(path: "company-icons/\(trimmed).\(ext)")
            switch await fetchImage(url) {
            case .image(let image):
                return IconLoadOutcome(image: image, cacheAsMissing: false)
            case .unavailable:
                sawUnavailable = true
            case .notFound:
                break
            }
        }
        return IconLoadOutcome(image: nil, cacheAsMissing: !sawUnavailable)
    }

    private func fetchImage(_ url: URL) async -> IconFetchResult {
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unavailable
            }
            if http.statusCode == 404 || http.statusCode == 410 {
                return .notFound
            }
            guard (200..<300).contains(http.statusCode) else {
                return .unavailable
            }
            guard let image = CompanyIconDecoder.image(from: data) else {
                return .unavailable
            }
            return .image(image)
        } catch is CancellationError {
            return .unavailable
        } catch let error as URLError where error.code == .cancelled {
            return .unavailable
        } catch {
            return .unavailable
        }
    }

    private func cacheKey(code: String, preferredURL: String?) -> String {
        "\(code)|\(preferredURL ?? "")"
    }
}

private struct IconLoadOutcome {
    var image: UIImage?
    var cacheAsMissing: Bool
}

private enum IconFetchResult {
    case image(UIImage)
    case notFound
    case unavailable
}

enum CompanyIconDecoder {
    static func image(from data: Data) -> UIImage? {
        if let image = UIImage(data: data), image.size.width > 0 {
            return image
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let count = CGImageSourceGetCount(source)
        var best: CGImage?
        var bestArea = 0
        for index in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let area = cgImage.width * cgImage.height
            if area > bestArea {
                best = cgImage
                bestArea = area
            }
        }
        guard let best else { return nil }
        return UIImage(cgImage: best)
    }
}
