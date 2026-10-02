import Foundation

/// Claude API (Console) via l'Admin API « Usage & Cost » :
///   GET /v1/organizations/cost_report              (amounts in cents, decimal string)
///   GET /v1/organizations/usage_report/messages    (tokens)
/// Requires an Admin key (sk-ant-admin01-…). Sources: see `ProviderDescriptor.anthropicAPI`.
struct AnthropicAdminConnector: UsageConnector {
    let kind: ProviderKind = .anthropicAPI
    let http: HTTPClient
    var baseURL = URL(string: "https://api.anthropic.com")!
    /// Safety: a month fits in one page (31 buckets max), but pagination is bounded anyway.
    var maxPages = 4

    struct CostPage: Decodable {
        struct Bucket: Decodable {
            struct Result: Decodable { let amount: String? }
            let results: [Result]
        }
        let data: [Bucket]
        let hasMore: Bool?
        let nextPage: String?

        private enum CodingKeys: String, CodingKey {
            case data, hasMore = "has_more", nextPage = "next_page"
        }
    }

    struct UsagePage: Decodable {
        struct Bucket: Decodable {
            struct Result: Decodable {
                struct CacheCreation: Decodable {
                    let ephemeral1hInputTokens: Double?
                    let ephemeral5mInputTokens: Double?

                    // Explicit keys: Foundation's automatic snake_case conversion turns "1h" into "1H".
                    private enum CodingKeys: String, CodingKey {
                        case ephemeral1hInputTokens = "ephemeral_1h_input_tokens"
                        case ephemeral5mInputTokens = "ephemeral_5m_input_tokens"
                    }
                }
                let uncachedInputTokens: Double?
                let cacheReadInputTokens: Double?
                let outputTokens: Double?
                let cacheCreation: CacheCreation?

                private enum CodingKeys: String, CodingKey {
                    case uncachedInputTokens = "uncached_input_tokens"
                    case cacheReadInputTokens = "cache_read_input_tokens"
                    case outputTokens = "output_tokens"
                    case cacheCreation = "cache_creation"
                }
            }
            let results: [Result]
        }
        let data: [Bucket]
        let hasMore: Bool?
        let nextPage: String?

        private enum CodingKeys: String, CodingKey {
            case data, hasMore = "has_more", nextPage = "next_page"
        }
    }

    func fetch(_ context: FetchContext) async throws -> UsageSnapshot {
        guard let key = context.secret, !key.isEmpty else { throw ProviderError.missingCredential }
        let start = UsageMath.startOfMonthUTC(containing: context.now)
        let nextMonth = UsageMath.startOfNextMonthUTC(after: context.now)

        let costUSD = try await fetchCost(key: key, start: start, end: context.now)

        var metrics: [UsageMetric] = [
            UsageMetric(id: "cost_month", label: "Cost this month", value: costUSD, limit: nil,
                        format: .usd, resetsAt: nextMonth, source: .official)
        ]
        if let budget = context.connection.monthlyBudgetUSD, let percent = UsageMath.percent(used: costUSD, limit: budget) {
            metrics.append(UsageMetric(id: "budget_percent", label: "Monthly budget used", value: percent,
                                       limit: nil, format: .percent, resetsAt: nextMonth, source: .derived))
        }

        var notes: [String] = []
        do {
            let tokens = try await fetchTokens(key: key, start: start, end: context.now)
            metrics.append(UsageMetric(id: "tokens_input", label: "Input tokens (month)", value: tokens.input,
                                       limit: nil, format: .tokens, resetsAt: nextMonth, source: .official))
            metrics.append(UsageMetric(id: "tokens_output", label: "Output tokens (month)", value: tokens.output,
                                       limit: nil, format: .tokens, resetsAt: nextMonth, source: .official))
        } catch let error as ProviderError {
            // Cost is the primary information: a token failure does not invalidate the rest.
            notes.append("Tokens unavailable: \(error.userMessage)")
        }
        if context.connection.monthlyBudgetUSD == nil {
            notes.append("No API returns your spending cap: enter a budget in Settings to get a percentage.")
        }
        return UsageSnapshot(fetchedAt: context.now, metrics: metrics, notes: notes)
    }

    // MARK: - Requests

    private func makeRequest(path: String, key: String, query: [URLQueryItem]) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(UserAgent.value, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Plain decoder: every response type above declares its exact JSON keys.
    private func decoder() -> JSONDecoder { JSONDecoder() }

    private func validate(_ response: HTTPResponse) throws -> HTTPResponse {
        try response.validated(
            unauthorizedHint: "Check the Admin key (sk-ant-admin01-…).",
            forbiddenHint: "The Admin API requires an organization Admin key; workspace keys and individual accounts are excluded."
        )
    }

    func fetchCost(key: String, start: Date, end: Date) async throws -> Double {
        var total = 0.0
        var page: String?
        for _ in 0..<maxPages {
            var query = [
                URLQueryItem(name: "starting_at", value: ISO8601.string(start)),
                URLQueryItem(name: "ending_at", value: ISO8601.string(end)),
                URLQueryItem(name: "limit", value: "31")
            ]
            if let page { query.append(URLQueryItem(name: "page", value: page)) }
            let response = try validate(try await http.send(makeRequest(path: "v1/organizations/cost_report", key: key, query: query)))
            guard let decoded = try? decoder().decode(CostPage.self, from: response.data) else {
                throw ProviderError.unexpectedResponse
            }
            for bucket in decoded.data {
                for result in bucket.results {
                    guard let amount = result.amount, let dollars = UsageMath.dollars(fromCentsString: amount) else {
                        throw ProviderError.unexpectedResponse
                    }
                    total += dollars
                }
            }
            guard decoded.hasMore == true, let next = decoded.nextPage else { return total }
            page = next
        }
        return total
    }

    func fetchTokens(key: String, start: Date, end: Date) async throws -> (input: Double, output: Double) {
        var input = 0.0, output = 0.0
        var page: String?
        for _ in 0..<maxPages {
            var query = [
                URLQueryItem(name: "starting_at", value: ISO8601.string(start)),
                URLQueryItem(name: "ending_at", value: ISO8601.string(end)),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "limit", value: "31")
            ]
            if let page { query.append(URLQueryItem(name: "page", value: page)) }
            let response = try validate(try await http.send(makeRequest(path: "v1/organizations/usage_report/messages", key: key, query: query)))
            guard let decoded = try? decoder().decode(UsagePage.self, from: response.data) else {
                throw ProviderError.unexpectedResponse
            }
            for bucket in decoded.data {
                for r in bucket.results {
                    input += (r.uncachedInputTokens ?? 0) + (r.cacheReadInputTokens ?? 0)
                        + (r.cacheCreation?.ephemeral1hInputTokens ?? 0) + (r.cacheCreation?.ephemeral5mInputTokens ?? 0)
                    output += r.outputTokens ?? 0
                }
            }
            guard decoded.hasMore == true, let next = decoded.nextPage else { return (input, output) }
            page = next
        }
        return (input, output)
    }
}
