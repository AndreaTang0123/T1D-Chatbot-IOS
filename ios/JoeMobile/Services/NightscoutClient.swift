import Foundation
import JoeCore

// Refuse redirects: a redirect must never forward credentials to another origin.
final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
actor NightscoutClient {
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()
    struct Result: Sendable {
        let glucose: [GlucoseSample]; let treatments: [Treatment]; let profile: Data?
        let warnings: [String]
    }
    func sync(_ credentials: NightscoutCredentials, since: Date, now: Date) async throws -> Result {
        // CGM is independent of optional pump/profile failures.
        let g = try await fetch(credentials.request(path: "api/v1/entries.json", query: [
            .init(name: "count", value: "10000"), .init(name: "find[date][$gte]", value: String(Int(since.timeIntervalSince1970*1000))),
            .init(name: "find[date][$lte]", value: String(Int(now.timeIntervalSince1970*1000)))]))
        if try count(g) >= 10000 { throw NightscoutError.truncated }
        let glucose = try NightscoutDecoder.glucose(g, receivedAt: now)
        var treatments: [Treatment] = []; var profile: Data?; var warnings: [String] = []
        do {
            let iso = ISO8601DateFormatter()
            let data = try await fetch(credentials.request(path: "api/v1/treatments.json", query: [
                .init(name: "count", value: "10000"), .init(name: "find[created_at][$gte]", value: iso.string(from: since)),
                .init(name: "find[created_at][$lte]", value: iso.string(from: now))]))
            if try count(data) >= 10000 { throw NightscoutError.truncated }
            treatments = try NightscoutDecoder.treatments(data, receivedAt: now)
        } catch is CancellationError { throw CancellationError() }
        catch { warnings.append("Pump/meal sync failed. Related features may be missing.") }
        do {
            let data = try await fetch(credentials.request(path: "api/v1/profile.json", query: [.init(name: "count", value: "1")]))
            _ = try count(data); profile = data
        } catch is CancellationError { throw CancellationError() }
        catch { warnings.append("Profile unavailable. Basal rate and IOB will not be inferred.") }
        return Result(glucose: glucose, treatments: treatments, profile: profile, warnings: warnings)
    }
    private func count(_ data: Data) throws -> Int {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [Any] else { throw NightscoutError.malformed }
        return rows.count
    }
    private func fetch(_ request: URLRequest) async throws -> Data {
        for attempt in 0..<3 {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw NightscoutError.malformed }
                if http.statusCode == 401 || http.statusCode == 403 { throw NightscoutError.authentication }
                if (http.statusCode == 429 || (500...599).contains(http.statusCode)), attempt < 2 {
                    try await Task.sleep(for: .seconds(Double(1 << attempt))); continue
                }
                guard (200...299).contains(http.statusCode) else { throw NightscoutError.http(http.statusCode) }
                guard data.count < 20_000_000 else { throw NightscoutError.malformed }
                return data
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                guard attempt < 2, [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code) else { throw NightscoutError.network }
                try await Task.sleep(for: .seconds(Double(1 << attempt)))
            }
        }
        throw NightscoutError.network
    }
}
