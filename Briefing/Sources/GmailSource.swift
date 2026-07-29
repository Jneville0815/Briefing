//
//  GmailSource.swift
//  Briefing
//

import Foundation

enum GmailError: LocalizedError {
    case packagesNotInstalled
    case notAuthenticated
    case noPresentingWindow
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .packagesNotInstalled:
            return "GoogleSignIn not installed. Add https://github.com/google/GoogleSignIn-iOS in Xcode → File → Add Package Dependencies…"
        case .notAuthenticated:
            return "Gmail is not connected. Use \"Connect Gmail…\" from the menu bar."
        case .noPresentingWindow:
            return "Open the Briefing window before connecting Gmail (the sign-in flow needs a window to attach to)."
        case .decodingFailed(let detail):
            return "Gmail request failed: \(detail)"
        }
    }
}

#if canImport(GoogleSignIn)

import AppKit
import GoogleSignIn

actor GmailSource {
    private let gmailScope = "https://www.googleapis.com/auth/gmail.readonly"

    nonisolated func isAuthenticated() -> Bool {
        GIDSignIn.sharedInstance.currentUser != nil
    }

    func restoreSignInIfPossible() async {
        await withCheckedContinuation { continuation in
            GIDSignIn.sharedInstance.restorePreviousSignIn { _, _ in
                continuation.resume()
            }
        }
    }

    func authenticate() async throws {
        let window: NSWindow? = await MainActor.run {
            NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey })
        }
        guard let window else { throw GmailError.noPresentingWindow }

        let scopes = [gmailScope]
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GIDSignInResult, Error>) in
            Task { @MainActor in
                GIDSignIn.sharedInstance.signIn(
                    withPresenting: window,
                    hint: nil,
                    additionalScopes: scopes
                ) { result, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let result else {
                        continuation.resume(throwing: GmailError.notAuthenticated)
                        return
                    }
                    continuation.resume(returning: result)
                }
            }
        }
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
    }

    func fetchRecentMessages(since: Date, maxResults: Int = 250) async throws -> [EmailMessage] {
        guard let user = GIDSignIn.sharedInstance.currentUser else {
            throw GmailError.notAuthenticated
        }

        let refreshed = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GIDGoogleUser, Error>) in
            user.refreshTokensIfNeeded { refreshedUser, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: refreshedUser ?? user)
            }
        }
        let token = refreshed.accessToken.tokenString

        // No category filter — InstaCart and similar transactional emails sometimes land in
        // Gmail's "Promotions" tab, so we fetch everything and let the caller post-filter.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        let query = "after:\(formatter.string(from: since))"

        var listComponents = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        listComponents.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: String(maxResults)),
        ]
        guard let listURL = listComponents.url else {
            throw GmailError.decodingFailed("Could not build list URL")
        }

        let list: GmailListResponse = try await jsonGET(listURL, token: token)
        let ids = list.messages?.map { $0.id } ?? []
        Logger.shared.info("Gmail returned \(ids.count) message ids")

        var emails: [EmailMessage] = []
        for id in ids {
            do {
                guard let detailURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=full") else { continue }
                let msg: GmailMessage = try await jsonGET(detailURL, token: token)
                if let parsed = Self.parse(msg) {
                    emails.append(parsed)
                }
            } catch {
                Logger.shared.error("Gmail message \(id) failed: \(error.localizedDescription)")
            }
        }

        return emails.sorted { $0.receivedAt > $1.receivedAt }
    }

    private func jsonGET<T: Decodable>(_ url: URL, token: String) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GmailError.decodingFailed("non-HTTP response")
        }
        guard http.statusCode == 200 else {
            let preview = String(data: data, encoding: .utf8)?.prefix(300).description ?? "<no body>"
            throw GmailError.decodingFailed("HTTP \(http.statusCode): \(preview)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func parse(_ msg: GmailMessage) -> EmailMessage? {
        guard let threadId = msg.threadId else { return nil }

        let headers = msg.payload?.headers ?? []
        let from = headerValue("From", headers: headers) ?? ""
        let subject = headerValue("Subject", headers: headers) ?? ""
        let toRaw = headerValue("To", headers: headers) ?? ""
        let to = toRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        let receivedAt: Date = {
            if let internalDateStr = msg.internalDate, let millis = Int64(internalDateStr) {
                return Date(timeIntervalSince1970: TimeInterval(millis) / 1000.0)
            }
            return Date()
        }()

        let bodyText = extractBody(msg.payload) ?? msg.snippet ?? ""

        return EmailMessage(
            id: msg.id,
            threadId: threadId,
            from: from,
            to: to,
            subject: subject,
            snippet: msg.snippet ?? "",
            bodyText: bodyText,
            receivedAt: receivedAt,
            labelIds: msg.labelIds ?? []
        )
    }

    private static func headerValue(_ name: String, headers: [GmailHeader]) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func extractBody(_ payload: GmailPayload?) -> String? {
        guard let payload else { return nil }

        if payload.mimeType == "text/plain",
           let encoded = payload.body?.data,
           let decoded = decodeBase64URL(encoded) {
            return decoded
        }

        if let parts = payload.parts {
            for part in parts where part.mimeType == "text/plain" {
                if let encoded = part.body?.data, let decoded = decodeBase64URL(encoded) {
                    return decoded
                }
            }
            for part in parts {
                if let text = extractBody(part) {
                    return text
                }
            }
        }
        return nil
    }

    private static func decodeBase64URL(_ string: String) -> String? {
        var s = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 {
            s += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: s) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private struct GmailListResponse: Decodable {
    let messages: [GmailMessageRef]?
    struct GmailMessageRef: Decodable { let id: String }
}

private struct GmailMessage: Decodable {
    let id: String
    let threadId: String?
    let snippet: String?
    let internalDate: String?
    let labelIds: [String]?
    let payload: GmailPayload?
}

private struct GmailPayload: Decodable {
    let mimeType: String?
    let headers: [GmailHeader]?
    let body: GmailBody?
    let parts: [GmailPayload]?
}

private struct GmailHeader: Decodable {
    let name: String
    let value: String
}

private struct GmailBody: Decodable {
    let data: String?
    let size: Int?
}

#else

actor GmailSource {
    nonisolated func isAuthenticated() -> Bool { false }
    func restoreSignInIfPossible() async { /* no-op */ }
    func authenticate() async throws { throw GmailError.packagesNotInstalled }
    func signOut() { /* no-op */ }
    func fetchRecentMessages(since: Date, maxResults: Int = 250) async throws -> [EmailMessage] {
        throw GmailError.packagesNotInstalled
    }
}

#endif
