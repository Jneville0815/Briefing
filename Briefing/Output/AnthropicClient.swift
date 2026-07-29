//
//  AnthropicClient.swift
//  Briefing
//

import Foundation

struct AnthropicClient: Sendable {
    let apiKey: String

    func generateBriefing(
        systemPrompt: String,
        userMessage: String,
        model: String = "claude-opus-4-7"
    ) async throws -> Briefing {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 300

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4000,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userMessage]
            ],
            "output_config": [
                "format": [
                    "type": "json_schema",
                    "schema": Self.briefingSchema
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AnthropicError.invalidResponse
        }
        guard http.statusCode == 200 else {
            let preview = String(data: data, encoding: .utf8)?.prefix(800).description ?? "<no body>"
            throw AnthropicError.httpError(status: http.statusCode, body: preview)
        }

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        let texts = decoded.content.compactMap { $0.type == "text" ? $0.text : nil }
        let combined = texts.joined()
        guard let jsonData = combined.data(using: .utf8) else {
            throw AnthropicError.emptyResponse
        }
        do {
            return try JSONDecoder().decode(Briefing.self, from: jsonData)
        } catch {
            throw AnthropicError.parseFailure(detail: error.localizedDescription, raw: combined)
        }
    }

    private struct ResponseBody: Decodable {
        let content: [Block]
        struct Block: Decodable {
            let type: String
            let text: String?
        }
    }

    private static let briefingSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["today", "reminders", "thisWeek", "upcomingTrips", "deliveries"],
        "properties": [
            "today": [
                "type": "object",
                "additionalProperties": false,
                "required": ["summary", "weather", "items"],
                "properties": [
                    "summary": ["type": "string"],
                    "weather": ["type": "string"],
                    "items": ["type": "array", "items": ["type": "string"]]
                ]
            ],
            "reminders": [
                "type": "array",
                "items": ["type": "string"]
            ],
            "thisWeek": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["dayOffset", "items"],
                    "properties": [
                        "dayOffset": ["type": "integer"],
                        "items": ["type": "array", "items": ["type": "string"]]
                    ]
                ]
            ],
            "upcomingTrips": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["title", "destination", "dates", "weather"],
                    "properties": [
                        "title": ["type": "string"],
                        "destination": ["type": "string"],
                        "dates": ["type": "string"],
                        "weather": ["type": "string"]
                    ]
                ]
            ],
            "deliveries": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["id", "state", "item", "dateOrdered", "dateDelivered"],
                    "properties": [
                        "id": ["type": "string"],
                        "state": ["type": "string", "enum": ["ordered", "delivered"]],
                        "item": ["type": "string"],
                        "dateOrdered": ["type": "string"],
                        "dateDelivered": ["type": "string"]
                    ]
                ]
            ]
        ]
    ]
}

enum AnthropicError: LocalizedError {
    case invalidResponse
    case httpError(status: Int, body: String)
    case emptyResponse
    case parseFailure(detail: String, raw: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Anthropic API returned a non-HTTP response."
        case .httpError(let status, let body):
            return "Anthropic API \(status): \(body)"
        case .emptyResponse:
            return "Anthropic API returned an empty response."
        case .parseFailure(let detail, _):
            return "Could not parse the structured briefing: \(detail)"
        }
    }
}
