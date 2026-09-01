import ImageIO
import SwiftUI
import UIKit

struct CompanyRowView: View {
    var company: CompanyRef

    var body: some View {
        HStack(spacing: 12) {
            CompanyIconView(company)
            VStack(alignment: .leading, spacing: 2) {
                Text(company.name.isEmpty ? company.code : company.name)
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                Text(company.code)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer()
            if !company.sector.isEmpty {
                Text(company.sector)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.sectorColor(company.sector))
                    .foregroundStyle(.white)
            }
        }
        .padding(0)
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
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: "\(code)|\(url ?? "")") {
            image = await CompanyIconLoader.shared.image(code: code, preferredURL: url)
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.gray.opacity(0.25))
            .overlay {
                Image(systemName: "building.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
    }
}

/// REST の `icon_url` を優先し、無いときは公開 R2 の `company-icons/{code}.{ext}` を試す。
/// 格納の大半は ICO なので `UIImage(data:)` ではなく ImageIO で解码する。
actor CompanyIconLoader {
    static let shared = CompanyIconLoader()

    private static let probeExtensions = ["ico", "png", "jpg", "gif", "bmp"]

    private var memory: [String: UIImage] = [:]
    private var missing: Set<String> = []
    private var inflight: [String: Task<IconLoadOutcome, Never>] = [:]

    func image(code: String, preferredURL: String?) async -> UIImage? {
        let key = cacheKey(code: code, preferredURL: preferredURL)
        if let cached = memory[key] { return cached }
        if missing.contains(key) { return nil }
        if let existing = inflight[key] {
            return await existing.value.image
        }
        let task = Task { await load(code: code, preferredURL: preferredURL) }
        inflight[key] = task
        let outcome = await task.value
        inflight[key] = nil
        if let loaded = outcome.image {
            memory[key] = loaded
        } else if outcome.cacheAsMissing {
            missing.insert(key)
        }
        return outcome.image
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
