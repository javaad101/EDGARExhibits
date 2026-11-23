import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Dedicated ephemeral session lifting URLSession.shared's 6-connections-per-host cap.
let edgarURLSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.httpMaximumConnectionsPerHost = 128
    config.timeoutIntervalForRequest = 60
    config.timeoutIntervalForResource = 300
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: config)
}()

/// Rewrites an official SEC EDGAR archive URL to the sec-api.io mirror endpoint.
func mirrorURL(for documentURL: String) throws -> URL {
    guard let sourceURL = URL(string: documentURL)?.standardized,
          let scheme = sourceURL.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          let host = sourceURL.host?.lowercased(),
          ["www.sec.gov", "sec.gov"].contains(host),
          sourceURL.path.hasPrefix("/Archives/edgar/data/"),
          var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false) else {
        throw URLError(.badURL)
    }
    components.scheme = "https"
    components.host = "edgar-mirror.sec-api.io"
    components.path = String(sourceURL.path.dropFirst("/Archives/edgar/data".count))
    components.port = nil
    components.user = nil
    components.password = nil
    components.query = nil
    components.fragment = nil
    guard let url = components.url else { throw URLError(.badURL) }
    return url
}

/// Queries https://api.sec-api.io for filings matching `query`.
func queryFilings(
    _ query: SECAPIQuery,
    apiKey: String,
    session: URLSession = edgarURLSession
) async throws -> [Filing] {
    guard let endpoint = URL(string: "https://api.sec-api.io") else {
        throw URLError(.badURL)
    }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue(apiKey, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 30
    request.httpBody = try JSONEncoder().encode(query)

    let data = try await getData(request: request, session: session)
    let box = try JSONDecoder().decode(SECAPIFilingQueryResponsesBox.self, from: data)
    return box.filings
}

/// Dispatches a single filing scrape job to the horizontally autoscaled Cloud Run worker fleet.
func dispatchFilingToWorker(
    _ job: WorkerFilingRequest,
    workerServiceURL: URL,
    apiKey: String,
    session: URLSession = edgarURLSession
) async throws -> FilingScrapeResult {
    let endpoint = workerServiceURL.appendingPathComponent("scrape-filing")
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "X-Worker-Key")
    request.timeoutInterval = 180
    request.httpBody = try JSONEncoder().encode(job)

    let data = try await getData(request: request, session: session)
    return try JSONDecoder().decode(FilingScrapeResult.self, from: data)
}

/// Executes an HTTP request with jittered exponential backoff and `Retry-After` support.
func getData(request: URLRequest, session: URLSession = edgarURLSession) async throws -> Data {
    let maxAttempts = 5
    var attempt = 1
    while true {
        try Task.checkCancellation()
        do {
            let (data, response) = try await performRequest(request, session: session)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard (200..<300).contains(response.statusCode) else {
                throw DownloadError.httpStatus(
                    response.statusCode,
                    retryAfter: retryDelay(from: response)
                )
            }
            return data
        } catch {
            try Task.checkCancellation()
            var delay = 0.25 * pow(2.0, Double(attempt - 1)) + Double.random(in: 0.05...0.25)
            let canRetry: Bool
            if case DownloadError.httpStatus(let status, let retryAfter) = error {
                canRetry = [408, 429, 500, 502, 503, 504].contains(status)
                delay = max(delay, retryAfter ?? 0)
            } else if let networkError = error as? URLError {
                canRetry = [.timedOut, .networkConnectionLost, .cannotConnectToHost]
                    .contains(networkError.code)
            } else {
                canRetry = false
            }
            guard canRetry, attempt < maxAttempts else { throw error }
            try await Task.sleep(for: .seconds(delay))
            attempt += 1
        }
    }
}

private func performRequest(_ request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
    #if canImport(FoundationNetworking)
    return try await withCheckedThrowingContinuation { continuation in
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                continuation.resume(throwing: error)
            } else if let data, let response {
                continuation.resume(returning: (data, response))
            } else {
                continuation.resume(throwing: URLError(.badServerResponse))
            }
        }
        task.resume()
    }
    #else
    return try await session.data(for: request)
    #endif
}

/// Respects a server's `Retry-After` header supplied as seconds or an HTTP date.
private func retryDelay(from response: HTTPURLResponse) -> TimeInterval? {
    guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
    if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return seconds }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
}

enum DownloadError: LocalizedError {
    case httpStatus(Int, retryAfter: TimeInterval?)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status, _):
            return "Download failed: HTTP \(status)."
        }
    }
}
