import SwiftUI
import UIKit

struct NewsView: View {
    var code: String
    @State private var response: CompanyNewsResponse?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let response {
                newsList(response)
            } else if let errorMessage {
                TickerStubView(title: "ニュース", detail: errorMessage)
            } else {
                ProgressView()
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
    }

    private func newsList(_ response: CompanyNewsResponse) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("ニュース")
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                if response.items.isEmpty {
                    Text("直近のニュースは見つかりませんでした。")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textMuted)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                } else {
                    ForEach(response.items) { item in
                        newsRow(item)
                        if item.id != response.items.last?.id {
                            Divider()
                                .overlay(Theme.textMuted.opacity(0.25))
                                .padding(.leading, 16)
                        }
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.card)
        .padding(16)
    }

    private func newsRow(_ item: CompanyNewsItem) -> some View {
        Button {
            guard let url = URL(string: item.url) else { return }
            UIApplication.shared.open(url)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .multilineTextAlignment(.leading)
                    if let description = item.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    HStack(spacing: 6) {
                        if let source = item.source, !source.isEmpty {
                            Text(source)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                        if let age = item.age, !age.isEmpty {
                            Text(age)
                                .font(.caption2)
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        do {
            response = try await APIClient.shared.companyNews(code: code)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            response = nil
        }
    }
}
