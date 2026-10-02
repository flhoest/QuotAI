import Foundation

/// OpenAI API (plateforme) via les endpoints d'organisation :
///   GET /v1/organization/costs               (amount.value en USD)
///   GET /v1/organization/usage/completions   (completion tokens and requests)
/// Requires an Admin key. Does NOT cover the ChatGPT/Codex subscription.
struct OpenAIAdminConnector: UsageConnector {
    let kind: ProviderKind = .openAIAPI
    let http: HTTPClient
    var baseURL = URL(string: "https://api.openai.com")!
    var maxPages = 4

    struct CostPage: Decodable {
        struct Bucket: Decodable {
            struct Result: Decodable {
                struct Amount: Decodable { let value: Double?; let currency: String? }
                let amount: Amount?
            }
            let results: [Result]
        }
        let data: [Bucket]
        let hasMore: Bool?
        let nextPage: String?
    }

    struct UsagePage: Decodable {
        struct Bucket: Decodable {
            struct Result: Decodable {
                let inputTokens: Double?
                let outputTokens: Double?
                let numModelRequests: Double?
            }
            let results: [Result]
        }
        let data: [Bucket]
        let hasMore: Bool?
        let nextPage: String?
    }

    func fetch(_ context: FetchContext) async throws -> UsageSnapshot {
        guard let key = context.secret, !key.isEmpty else { throw ProviderError.missingCredential }
        let start = UsageMath.startOfMonthUTC(containing: context.now)
        let nextMonth = UsageMath.startOfNextMonthUTC(after: context.now)

        let costUSD = try await fetchCost(key: key, start: start)

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
            let usage = try await fetchUsage(key: key, start: start)
            metrics.append(UsageMetric(id: "tokens_input", label: "Input tokens (month)", value: usage.input,
                                       limit: nil, format: .tokens, resetsAt: nextMonth, source: .official))
            metrics.append(UsageMetric(id: "tokens_output", label: "Output tokens (month)", value: usage.output,
                                       limit: nil, format: .tokens, resetsAt: nextMonth, source: .official))
            metrics.append(UsageMetric(id: "requests", label: "Requests (month)", value: usage.requests,
                                       limit: nil, format: .count, resetsAt: nextMonth, source: .official))
            notes.append("Tokens and requests: \"completions\" endpoint only; the cost figure covers all services.")
        } catch let error as ProviderError {
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
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(UserAgent.value, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private func validate(_ response: HTTPResponse) throws -> HTTPResponse {
        try response.validated(
            unauthorizedHint: "Check the OpenAI Admin key.",
            forbiddenHint: "This key lacks admin rights: an Admin API key is required."
        )
    }

    func fetchCost(key: String, start: Date) async throws -> Double {
        var total = 0.0
        var page: String?
        for _ in 0..<maxPages {
            var query = [
                URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "limit", value: "31")
            ]
            if let page { query.append(URLQueryItem(name: "page", value: page)) }
            let response = try validate(try await http.send(makeRequest(path: "v1/organization/costs", key: key, query: query)))
            guard let decoded = try? decoder().decode(CostPage.self, from: response.data) else {
                throw ProviderError.unexpectedResponse
            }
            for bucket in decoded.data {
                for result in bucket.results {
                    guard let amount = result.amount, let value = amount.value, value.isFinite else { continue }
                    // Only USD is documented; another currency would be summed incorrectly.
                    if let currency = amount.currency, currency.lowercased() != "usd" { throw ProviderError.unexpectedResponse }
                    total += value
                }
            }
            guard decoded.hasMore == true, let next = decoded.nextPage else { return total }
            page = next
        }
        return total
    }

    func fetchUsage(key: String, start: Date) async throws -> (input: Double, output: Double, requests: Double) {
        var input = 0.0, output = 0.0, requests = 0.0
        var page: String?
        for _ in 0..<maxPages {
            var query = [
                URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "limit", value: "31")
            ]
            if let page { query.append(URLQueryItem(name: "page", value: page)) }
            let response = try validate(try await http.send(makeRequest(path: "v1/organization/usage/completions", key: key, query: query)))
            guard let decoded = try? decoder().decode(UsagePage.self, from: response.data) else {
                throw ProviderError.unexpectedResponse
            }
            for bucket in decoded.data {
                for r in bucket.results {
                    input += r.inputTokens ?? 0
                    output += r.outputTokens ?? 0
                    requests += r.numModelRequests ?? 0
                }
            }
            guard decoded.hasMore == true, let next = decoded.nextPage else { return (input, output, requests) }
            page = next
        }
        return (input, output, requests)
    }
}
