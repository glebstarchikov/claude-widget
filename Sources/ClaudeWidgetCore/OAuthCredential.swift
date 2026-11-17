import Foundation

/// A Claude sign-in. Never print or log the tokens: both descriptions are redacted.
public struct OAuthCredential: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    public var description: String { "OAuthCredential(expiresAt: \(expiresAt), tokens: <redacted>)" }
    public var debugDescription: String { description }
}

public enum CredentialParser {
    /// Parses Claude Code's Keychain JSON. `expiresAt` of 0 or missing means unknown, treated as needing renewal.
    public static func parseClaudeCode(keychainJSON: Data) -> OAuthCredential? {
        guard let root = (try? JSONSerialization.jsonObject(with: keychainJSON)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String, !access.isEmpty,
              let refresh = oauth["refreshToken"] as? String, !refresh.isEmpty
        else { return nil }
        var expiresAt = Date.distantPast
        if let ms = (oauth["expiresAt"] as? NSNumber)?.doubleValue, ms > 0 {
            expiresAt = Date(timeIntervalSince1970: ms / 1000)
        }
        return OAuthCredential(accessToken: access, refreshToken: refresh, expiresAt: expiresAt)
    }

    public static func needsRenewal(_ c: OAuthCredential, now: Date) -> Bool {
        c.expiresAt <= now.addingTimeInterval(300)
    }
}

public enum TokenRefreshError: Error, Equatable, Sendable {
    case malformedResponse
}

public enum TokenRefresh {
    public static let url = URL(string: "https://platform.claude.com/v1/oauth/token")!
    public static let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let userAgent = "claude-widget/1.0 (macOS)"

    public static func makeRequest(refreshToken: String) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let body = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientId]
        r.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return r
    }

    public static func parseResponse(_ data: Data, now: Date) throws -> OAuthCredential {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = root["access_token"] as? String, !access.isEmpty,
              let refresh = root["refresh_token"] as? String, !refresh.isEmpty,
              let expiresIn = root["expires_in"] as? NSNumber, CFGetTypeID(expiresIn) != CFBooleanGetTypeID()
        else { throw TokenRefreshError.malformedResponse }
        return OAuthCredential(accessToken: access, refreshToken: refresh,
                               expiresAt: now.addingTimeInterval(expiresIn.doubleValue))
    }
}
