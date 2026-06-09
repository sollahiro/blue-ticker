import Foundation

struct CompanyBasicInfo: Codable {
    let code: String
    let name: String
    let nameEn: String
    let industry: String
    let sector33: String
    let sector33Name: String
    let sector17: String
    let sector17Name: String
    let market: String
}

struct CompanyInfoService {
    func searchCompanies(_ query: String) async -> [StockSearchResult] {
        await masterDataManager.search(query, limit: 50)
    }

    func fetchBasicInfo(_ code: String) async -> CompanyBasicInfo {
        guard let stock = await masterDataManager.getByCode(code) else {
            return CompanyBasicInfo(
                code: code, name: "", nameEn: "", industry: "",
                sector33: "", sector33Name: "", sector17: "", sector17Name: "", market: ""
            )
        }
        return CompanyBasicInfo(
            code: code,
            name: stock.coName,
            nameEn: "",
            industry: stock.s33nm,
            sector33: stock.s33,
            sector33Name: stock.s33nm,
            sector17: stock.s17,
            sector17Name: stock.s17nm,
            market: stock.mktNm
        )
    }
}
