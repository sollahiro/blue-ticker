import SwiftUI

struct CompanyRowView: View {
    var company: CompanyRef

    var body: some View {
        HStack(spacing: 12) {
            CompanyIconView(url: company.iconURL)
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
    var url: String?

    var body: some View {
        Group {
            if let url, let parsed = URL(string: url) {
                AsyncImage(url: parsed) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
