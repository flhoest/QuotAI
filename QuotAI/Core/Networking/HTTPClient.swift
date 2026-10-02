import Foundation

struct HTTPResponse: Sendable {
    let status: Int
    let data: Data
    let headers: [String: String]

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Maps an HTTP status to a `ProviderError`, never exposing the response body.
    func validated(unauthorizedHint: String, forbiddenHint: String, invalidKeyStatuses: Set<Int> = []) throws -> HTTPResponse {
        switch status {
        case 200..<300:
            return self
        case 401:
            throw ProviderError.unauthorized(hint: unauthorizedHint)
        case let s where invalidKeyStatuses.contains(s):
            throw ProviderError.unauthorized(hint: unauthorizedHint)
        case 403:
            throw ProviderError.forbidden(hint: forbiddenHint)
        case 429:
            throw ProviderError.rateLimited(retryAfter: header("retry-after").flatMap(TimeInterval.init))
        case 500..<600:
            throw ProviderError.server(status: status)
        default:
            throw ProviderError.unexpectedResponse
        }
    }
}

protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// URLSession-based client: ephemeral session, no cookies, no disk cache, short timeout.
struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    init(requestTimeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout * 2
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ProviderError.unexpectedResponse }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String { headers[key] = value }
            }
            return HTTPResponse(status: http.statusCode, data: data, headers: headers)
        } catch let error as ProviderError {
            throw error
        } catch let error as URLError {
            throw Self.map(error)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderError.network(code: (error as NSError).code)
        }
    }

    static func map(_ error: URLError) -> ProviderError {
        switch error.code {
        case .timedOut: return .timeout
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .cancelled: return .network(code: URLError.cancelled.rawValue)
        default: return .network(code: error.code.rawValue)
        }
    }
}

enum UserAgent {
    static let value = "QuotAI/1.0 (macOS)"
}
