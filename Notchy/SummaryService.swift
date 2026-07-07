import Foundation

/// Calls the Anthropic Messages API to produce a 2-sentence "next steps" summary
/// of recently-completed Claude Code activity.
actor SummaryService {
    static let shared = SummaryService()

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-haiku-4-5-20251001"
    private static let anthropicVersion = "2023-06-01"

    enum SummaryError: Error {
        case missingAPIKey
        case badResponse
    }

    func summarize(terminalOutput: String, lastRequest: String?) async throws -> String {
        let apiKey = SettingsManager.shared.anthropicAPIKey
        guard !apiKey.isEmpty else {
            print("[summary-svc] missing API key")
            throw SummaryError.missingAPIKey
        }
        print("[summary-svc] preparing request: terminalOutput=\(terminalOutput.count) chars, lastRequest=\(lastRequest.map { "\"\($0)\"" } ?? "nil")")

        let requestLine = lastRequest.map { "The user's most recent request was: \"\($0)\"\n\n" } ?? ""
        let prompt = """
        You are summarizing the result of a Claude Code session that just finished a task. \
        \(requestLine)Below is the recent terminal output. Write exactly two short sentences:
        1) What Claude just completed (be specific — file names, behaviors).
        2) What the user should verify, run, or do next.

        No preamble, no markdown, no bullets. Plain prose.

        Terminal output:
        \(terminalOutput)
        """

        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 250,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        print("[summary-svc] POST \(Self.endpoint.absoluteString) (model=\(Self.model))")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        print("[summary-svc] HTTP \(http?.statusCode ?? -1), body=\(data.count) bytes")
        guard let http, (200..<300).contains(http.statusCode) else {
            let bodyPreview = String(data: data.prefix(500), encoding: .utf8) ?? "<non-utf8>"
            print("[summary-svc] non-2xx body: \(bodyPreview)")
            throw SummaryError.badResponse
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let first = content.first,
              let text = first["text"] as? String else {
            print("[summary-svc] could not parse response JSON")
            throw SummaryError.badResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
