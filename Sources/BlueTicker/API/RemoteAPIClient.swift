// remote バックエンド（blt-server）の REST API クライアント。
//
// ローカルモードが Services を直呼びするのに対し、remote モードはこのクライアントで
// 計算済み JSON を受け取り、CLI の既存レンダラが使える形（StockSearchResult /
// MetricsResult / セクション辞書）にデコードする（計算はサーバーに集約）。
//
// 失敗は throw せず RemoteOutcome で表現する（error-handling.md の戻り値パターン）。

import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// remote 呼び出しの結果。ok / notFound（404）/ failure（接続・認証・その他）。
enum RemoteOutcome<T> {
    case ok(T)
    case notFound(String)
    case failure(String)
}

/// 書類一覧（filings エンドポイント）のデコード形。
struct RemoteFilings: Codable {
    let code: String
    let name: String
    let filings: [Entry]

    struct Entry: Codable {
        let docId: String
        let docType: String
        let docTypeLabel: String
        let fyEnd: String
        let submittedAt: String

        enum CodingKeys: String, CodingKey {
            case docId = "doc_id"
            case docType = "doc_type"
            case docTypeLabel = "doc_type_label"
            case fyEnd = "fy_end"
            case submittedAt = "submitted_at"
        }
    }
}

/// 書類セクション（filing-content エンドポイント）のデコード形。
/// sections は値が文字列（本文）または辞書（セグメント表）の混在のため [String: Any]。
struct RemoteFilingContent {
    let code: String
    let docId: String
    let sections: [String: Any]
}

struct RemoteAPIClient: Sendable {
    let baseURL: String
    let cfAccessJwt: String?

    /// baseURL が空・不正なら nil。cfAccessJwt は空なら未設定扱い。
    init?(baseURLString: String, cfAccessJwt: String? = nil) {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, URL(string: trimmed) != nil else { return nil }
        baseURL = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        self.cfAccessJwt = (cfAccessJwt?.isEmpty == false) ? cfAccessJwt : nil
    }

    // MARK: - エンドポイント

    func searchCompanies(q: String) async -> RemoteOutcome<[StockSearchResult]> {
        await getDecoding("/v1/companies", query: ["q": q])
    }

    func getSectors() async -> RemoteOutcome<[SectorSummary]> {
        await getDecoding("/v1/sectors", query: [:])
    }

    func getFilings(code: String, maxYears: Int) async -> RemoteOutcome<RemoteFilings> {
        await getDecoding("/v1/companies/\(escape(code))/filings", query: ["max_years": String(maxYears)])
    }

    func getFinancials(code: String, years: Int) async -> RemoteOutcome<FinancialsResponse> {
        await getDecoding("/v1/companies/\(escape(code))/financials", query: ["years": String(years)])
    }

    func getHalfFinancials(code: String, years: Int) async -> RemoteOutcome<HalfFinancialsResponse> {
        await getDecoding(
            "/v1/companies/\(escape(code))/half-financials", query: ["years": String(years)])
    }

    /// Analyze（`docs/feature-tiers.md`）。financials の水準値に加え、増減分解フィールド
    /// （事業利益ウォーターフォール・ROIC/ROE分解・ネットキャッシュ/運転資本/CCC前年差）を含む。
    /// `FinancialsResponse` でデコードするため、④⑤ブロックの新規キーはデコード時に無視される
    /// （render() は既存の水準値フィールドから自前で ④⑤ を再計算するため問題ない）。
    func getAnalysis(code: String, years: Int) async -> RemoteOutcome<FinancialsResponse> {
        await getDecoding("/v1/companies/\(escape(code))/analysis", query: ["years": String(years)])
    }

    /// Analyze の半期版。デコード形の扱いは `getAnalysis` 参照。
    func getHalfAnalysis(code: String, years: Int) async -> RemoteOutcome<HalfFinancialsResponse> {
        await getDecoding(
            "/v1/companies/\(escape(code))/half-analysis", query: ["years": String(years)])
    }

    func getFilingContent(code: String, docId: String?, sections: [String]?)
        async -> RemoteOutcome<RemoteFilingContent>
    {
        var query: [String: String] = [:]
        if let d = docId, !d.isEmpty { query["doc_id"] = d }
        if let s = sections, !s.isEmpty { query["sections"] = s.joined(separator: ",") }

        switch await fetch("/v1/companies/\(escape(code))/filing-content", query: query) {
        case .failure(let m): return .failure(m)
        case .notFound(let m): return .notFound(m)
        case .ok(let data):
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure("応答の解析に失敗しました")
            }
            return .ok(RemoteFilingContent(
                code: obj["code"] as? String ?? code,
                docId: obj["doc_id"] as? String ?? "",
                sections: obj["sections"] as? [String: Any] ?? [:]
            ))
        }
    }

    // MARK: - HTTP

    /// JSON を取得し Decodable へデコードする。
    private func getDecoding<T: Decodable>(_ path: String, query: [String: String])
        async -> RemoteOutcome<T>
    {
        switch await fetch(path, query: query) {
        case .failure(let m): return .failure(m)
        case .notFound(let m): return .notFound(m)
        case .ok(let data):
            guard let value = try? JSONDecoder().decode(T.self, from: data) else {
                return .failure("応答の解析に失敗しました")
            }
            return .ok(value)
        }
    }

    /// GET リクエストを実行し、ステータスごとに RemoteOutcome へ写す。
    private func fetch(_ path: String, query: [String: String]) async -> RemoteOutcome<Data> {
        guard let request = buildRequest(path, query: query) else {
            return .failure("URL の組み立てに失敗しました: \(baseURL)\(path)")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure("不正な応答を受け取りました")
            }
            switch http.statusCode {
            case 200:
                return .ok(data)
            case 401:
                return .failure(
                    "認証に失敗しました。ticker login を再実行してください。")
            case 404:
                return .notFound(errorMessage(data) ?? "見つかりませんでした")
            default:
                return .failure(errorMessage(data) ?? "サーバーエラー (status \(http.statusCode))")
            }
        } catch {
            return .failure("サーバーに接続できませんでした: \(error.localizedDescription)")
        }
    }

    /// リクエストを組み立てヘッダを付与する（URL が不正なら nil）。テストから直接検証できるよう internal。
    func buildRequest(_ path: String, query: [String: String]) -> URLRequest? {
        guard var comps = URLComponents(string: baseURL + path) else { return nil }
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { return nil }

        var request = URLRequest(url: url)
        // Cloudflare Access SSO（ticker login 経由の JWT）。
        // エッジでの認証は Cookie `CF_Authorization` を見る（`Cf-Access-Jwt-Assertion` ヘッダーは
        // Access が認証済みリクエストを origin に転送する際に付与するものであり、クライアントが
        // 未認証状態でこれを送っても Access のログイン画面へ 302 されるだけで通らない。実機検証で確認済み）。
        if let jwt = cfAccessJwt {
            request.setValue("CF_Authorization=\(jwt)", forHTTPHeaderField: "Cookie")
        }
        return request
    }

    /// エラー封筒 `{"error": "...", "status": N}` から message を取り出す。
    private func errorMessage(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj["error"] as? String
    }

    /// パスセグメント用に percent-encode する（日本語の業種名・コードを安全にパスへ載せる）。
    private func escape(_ s: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
