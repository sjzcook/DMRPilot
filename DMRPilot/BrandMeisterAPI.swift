//
//  BrandMeisterAPI.swift
//  DMRPilot
//
//  BrandMeister 公开 REST API（v2）。v1.0 已于服务端下线，全部请求走 v2。
//  已实测端点：
//    GET https://api.brandmeister.network/v2/device/{id}   设备/热点/中继台详情
//    GET https://api.brandmeister.network/v2/talkgroup      全球通话组名称表 { "91": "World-wide", ... }
//

import Foundation

enum BmApiError: LocalizedError {
    case http(Int)
    case api(String)
    case parsing(String)

    var errorDescription: String? {
        switch self {
        case .http(let code):
            return "服务器返回 HTTP \(code)"
        case .api(let message):
            return message
        case .parsing(let detail):
            return "数据解析失败：\(detail)"
        }
    }
}

struct BrandMeisterAPI {

    private static let baseURL = "https://api.brandmeister.network/v2/"
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    /// 设备详情：热点、中继台、任何 DMR ID 都可以查
    func device(_ id: Int) async throws -> BmDevice {
        try await get("device/\(id)", as: BmDevice.self)
    }

    /// 全球通话组名称表
    func talkgroups() async throws -> [Int: String] {
        let raw = try await get("talkgroup", as: [String: String].self)
        var result: [Int: String] = [:]
        result.reserveCapacity(raw.count)
        for (key, value) in raw {
            if let id = Int(key) {
                result[id] = value
            }
        }
        return result
    }

    // MARK: - 通用 GET

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        guard let url = URL(string: Self.baseURL + path) else {
            throw BmApiError.api("地址无效：\(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DMRPilot/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw BmApiError.api("没有收到 HTTP 响应")
        }

        guard (200..<300).contains(http.statusCode) else {
            // Laravel 风格的错误体：{"message": "No query results for model ..."}
            if let object = try? JSONDecoder().decode([String: String].self, from: data),
               let message = object["message"] {
                throw BmApiError.api(message)
            }
            throw BmApiError.http(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw BmApiError.parsing(error.localizedDescription)
        }
    }
}
