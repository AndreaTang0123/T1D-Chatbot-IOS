import Foundation

public struct NightscoutCredentials: Codable, Sendable {
    public enum Auth: String, Codable, Sendable { case token, secretSHA1 }
    public let baseURL: URL
    public let secret: String
    public let auth: Auth
    public init(url: String, secret: String, auth: Auth) throws {
        guard let parts = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let url = parts.url, !secret.isEmpty, !secret.contains(where: { $0.isNewline }) else { throw NightscoutError.invalidURL }
        if auth == .secretSHA1 {
            guard secret.count == 40, secret.allSatisfy({ $0.isHexDigit }) else { throw NightscoutError.invalidCredential }
        }
        self.baseURL = url; self.secret = secret; self.auth = auth
    }
    public func request(path: String, query: [URLQueryItem] = []) -> URLRequest {
        var parts = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        parts.queryItems = query + (auth == .token ? [URLQueryItem(name: "token", value: secret)] : [])
        var request = URLRequest(url: parts.url!); request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if auth == .secretSHA1 { request.setValue(secret, forHTTPHeaderField: "api-secret") }
        return request
    }
}

public enum NightscoutError: Error, LocalizedError {
    case invalidURL, invalidCredential, authentication, http(Int), malformed, network, truncated
    public var errorDescription: String? {
        switch self {
        case .invalidURL: "请输入有效 HTTPS Nightscout 地址，不要包含账号、查询参数或 token"
        case .invalidCredential: "API secret 必须为 40 位 SHA-1；也可选择只读 access token"
        case .authentication: "Nightscout 认证失败，请检查只读权限"
        case .http(let code): "Nightscout HTTP 错误：\(code)"
        case .malformed: "Nightscout 返回格式无效"
        case .network: "无法连接 Nightscout，请检查网络和公开 HTTPS 地址"
        case .truncated: "历史记录超过单页限制，请缩短同步窗口"
        }
    }
}

public enum NightscoutDecoder {
    public static func date(_ value: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    public static func glucose(_ data: Data, receivedAt: Date) throws -> [GlucoseSample] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw NightscoutError.malformed }
        return rows.compactMap { row in
            guard let value = number(row["sgv"]), (40...400).contains(value),
                  let ms = number(row["date"]), ms > 0 else { return nil }
            let t = Date(timeIntervalSince1970: ms/1000)
            guard t <= receivedAt else { return nil }
            return GlucoseSample(id: row["_id"] as? String ?? "cgm-\(ms)", timestamp: t, glucose: value,
                                 direction: row["direction"] as? String, receivedAt: receivedAt)
        }.sorted { $0.timestamp < $1.timestamp }
    }
    public static func treatments(_ data: Data, receivedAt: Date) throws -> [Treatment] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw NightscoutError.malformed }
        return rows.compactMap { row in
            guard let text = row["created_at"] as? String ?? row["timestamp"] as? String,
                  let t = date(text), t <= receivedAt else { return nil }
            func bounded(_ key: String, _ max: Double) -> Double? {
                guard let n = number(row[key]), n >= 0, n <= max else { return nil }; return n
            }
            let kind = row["eventType"] as? String ?? "other"
            return Treatment(id: row["_id"] as? String ?? "\(text)-\(kind)", timestamp: t, kind: kind,
                             insulin: bounded("insulin", 100), carbs: bounded("carbs", 500),
                             rate: bounded("absolute", 50), duration: bounded("duration", 1440))
        }.sorted { $0.timestamp < $1.timestamp }
    }
    private static func number(_ value: Any?) -> Double? {
        let n = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        return n.flatMap { $0.isFinite ? $0 : nil }
    }
}
