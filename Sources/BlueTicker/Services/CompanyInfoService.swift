import Foundation

struct CompanyBasicInfo: Codable {
    let code: String
    let name: String
    let industry: String
    let sector33: String
    let sector33Name: String
    let market: String
}

struct CompanyInfoService {
    func searchCompanies(_ query: String) async -> [StockSearchResult] {
        await masterDataManager.search(query, limit: 50)
    }

    func fetchBasicInfo(_ code: String) async -> CompanyBasicInfo {
        guard let stock = await masterDataManager.getByCode(code) else {
            return CompanyBasicInfo(
                code: code, name: "", industry: "",
                sector33: "", sector33Name: "", market: ""
            )
        }
        return CompanyBasicInfo(
            code: code,
            name: stock.coName,
            industry: stock.s33nm,
            sector33: stock.s33,
            sector33Name: stock.s33nm,
            market: stock.mktNm
        )
    }
}
