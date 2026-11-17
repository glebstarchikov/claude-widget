import XCTest
@testable import ClaudeWidgetCore

final class UsageTests: XCTestCase {
    private let limitsJSON = #"""
    {"five_hour":null,
     "seven_day":{"utilization":78.0,"resets_at":"2026-11-18T19:59:59.672043+00:00"},
     "seven_day_opus":null,
     "extra_usage":{"is_enabled":false},
     "limits":[
      {"kind":"weekly_all","group":"weekly","percent":78,"severity":"warning","resets_at":"2026-11-18T19:59:59.926513+00:00","scope":null,"is_active":false},
      {"kind":"weekly_scoped","group":"weekly","percent":100,"severity":"critical","resets_at":"2026-11-18T19:59:59.926795+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":true}
     ],"pace":null,"indicator":null}
    """#

    // MARK: usage parser

    func testParsesLimitsArray() throws {
        let u = try UsageParser.parseClaude(Data(limitsJSON.utf8), fetchedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(u.provider, "Claude")
        XCTAssertEqual(u.windows.map(\.label), ["week", "Fable · week"])
        XCTAssertEqual(u.windows.map(\.percent), [78, 100])
        XCTAssertEqual(u.windows.map(\.severity), ["warning", "critical"])
        XCTAssertEqual(u.windows.map(\.isActive), [false, true])
        XCTAssertNotNil(u.windows[0].resetsAt)
        XCTAssertNotNil(u.windows[1].resetsAt)
    }

    func testFallbackToFiveHourAndSevenDay() throws {
        let json = #"{"five_hour":{"utilization":42,"resets_at":"2026-11-17T15:00:00.123456+00:00"},"seven_day":{"utilization":61.5,"resets_at":"2026-11-20T09:00:00+00:00"},"seven_day_opus":null}"#
        let u = try UsageParser.parseClaude(Data(json.utf8), fetchedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(u.windows.map(\.label), ["5h", "week"])
        XCTAssertEqual(u.windows.map(\.percent), [42, 61.5])
        XCTAssertNotNil(u.windows[0].resetsAt)   // fractional seconds accepted
        XCTAssertNotNil(u.windows[1].resetsAt)   // plain seconds accepted
    }

    func testFallbackOmitsNullWindowAndEmptyLimitsFallsBack() throws {
        let json = #"{"limits":[],"five_hour":null,"seven_day":{"utilization":10,"resets_at":null}}"#
        let u = try UsageParser.parseClaude(Data(json.utf8), fetchedAt: Date())
        XCTAssertEqual(u.windows.map(\.label), ["week"])
        XCTAssertNil(u.windows[0].resetsAt)
    }

    func testNumericEpochResetParses() throws {
        let json = #"{"seven_day":{"utilization":10,"resets_at":1790000000}}"#
        let u = try UsageParser.parseClaude(Data(json.utf8), fetchedAt: Date())
        XCTAssertEqual(u.windows[0].resetsAt, Date(timeIntervalSince1970: 1790000000))
    }

    func testGroupLabelMapping() throws {
        let json = #"""
        {"limits":[
         {"kind":"k1","group":"five_hour","percent":1},
         {"kind":"k2","group":"session","percent":2},
         {"kind":"k3","group":"monthly","percent":3.5,"scope":{"model":{"display_name":"Fable"}}},
         {"kind":"only_kind","percent":4,"scope":{"model":{"display_name":""}}}
        ]}
        """#
        let u = try UsageParser.parseClaude(Data(json.utf8), fetchedAt: Date())
        XCTAssertEqual(u.windows.map(\.label), ["5h", "5h", "Fable · monthly", "only_kind"])
        XCTAssertEqual(u.windows.map(\.percent), [1, 2, 3.5, 4])
        XCTAssertEqual(u.windows.map(\.isActive), [false, false, false, false])
    }

    func testNoWindowsThrows() {
        for body in ["{}", #"{"limits":[]}"#, #"{"five_hour":null,"seven_day":null}"#, "[]"] {
            XCTAssertThrowsError(try UsageParser.parseClaude(Data(body.utf8), fetchedAt: Date()), body)
        }
    }

    func testGarbageThrowsWithoutLeakingBody() {
        XCTAssertThrowsError(try UsageParser.parseClaude(Data("nope-AAA-secret".utf8), fetchedAt: Date())) { error in
            XCTAssertFalse(String(describing: error).contains("AAA-secret"))
            XCTAssertFalse(String(reflecting: error).contains("AAA-secret"))
        }
    }

    func testProviderUsageRoundTripsThroughCache() throws {
        let u = try UsageParser.parseClaude(Data(limitsJSON.utf8), fetchedAt: Date(timeIntervalSince1970: 1_000))
        let data = try JSONEncoder().encode(u)
        XCTAssertEqual(try JSONDecoder().decode(ProviderUsage.self, from: data), u)
    }

    func testLimitsCachePath() {
        XCTAssertEqual(WidgetConstants.limitsCache.lastPathComponent, "limits.json")
        XCTAssertEqual(WidgetConstants.limitsCache.deletingLastPathComponent(), WidgetConstants.baseDir)
    }

    // MARK: usage request

    func testRequestHeaders() {
        let r = UsageRequest.make(token: "abc")
        XCTAssertEqual(r.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(r.httpMethod, "GET")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
        XCTAssertEqual(r.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(r.value(forHTTPHeaderField: "User-Agent"), "claude-widget/1.0 (macOS)")
    }

    // MARK: credential

    func testParseClaudeCodeFullItem() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"AAA-secret","refreshToken":"RRR-secret","expiresAt":1790000000000,"scopes":["a"]},"mcpOAuth":{}}"#
        let c = try XCTUnwrap(CredentialParser.parseClaudeCode(keychainJSON: Data(json.utf8)))
        XCTAssertEqual(c.accessToken, "AAA-secret")
        XCTAssertEqual(c.refreshToken, "RRR-secret")
        XCTAssertEqual(c.expiresAt, Date(timeIntervalSince1970: 1_790_000_000))
    }

    func testParseClaudeCodeZeroOrMissingExpiryNeedsRenewal() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        for json in [#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":0}}"#,
                     #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r"}}"#] {
            let c = try XCTUnwrap(CredentialParser.parseClaudeCode(keychainJSON: Data(json.utf8)))
            XCTAssertEqual(c.expiresAt, .distantPast)
            XCTAssertTrue(CredentialParser.needsRenewal(c, now: now))
        }
    }

    func testParseClaudeCodeRejectsBadInput() {
        let bad = [#"{"claudeAiOauth":{"accessToken":"","refreshToken":"r","expiresAt":1}}"#,
                   #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"","expiresAt":1}}"#,
                   #"{"claudeAiOauth":{"accessToken":"a","expiresAt":1}}"#,
                   #"{"claudeAiOauth":{"refreshToken":"r"}}"#,
                   #"{"mcpOAuth":{}}"#, "nope", "[]"]
        for json in bad {
            XCTAssertNil(CredentialParser.parseClaudeCode(keychainJSON: Data(json.utf8)), json)
        }
    }

    func testNeedsRenewalMargin() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func cred(_ left: TimeInterval) -> OAuthCredential {
            OAuthCredential(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(left))
        }
        XCTAssertFalse(CredentialParser.needsRenewal(cred(600), now: now))
        XCTAssertTrue(CredentialParser.needsRenewal(cred(240), now: now))
        XCTAssertTrue(CredentialParser.needsRenewal(cred(300), now: now))
        XCTAssertFalse(CredentialParser.needsRenewal(cred(301), now: now))
        XCTAssertTrue(CredentialParser.needsRenewal(cred(-60), now: now))
    }

    func testCredentialDescriptionsRedactTokens() {
        let c = OAuthCredential(accessToken: "AAA-secret", refreshToken: "RRR-secret", expiresAt: Date(timeIntervalSince1970: 0))
        for s in [String(describing: c), String(reflecting: c), "\(c)", c.description, c.debugDescription] {
            XCTAssertFalse(s.contains("AAA-secret"), s)
            XCTAssertFalse(s.contains("RRR-secret"), s)
            XCTAssertTrue(s.contains("redacted"), s)
        }
        var dumped = ""
        dump(c, to: &dumped)
        XCTAssertFalse(dumped.contains("AAA-secret"), dumped)
        XCTAssertFalse(dumped.contains("RRR-secret"), dumped)
        XCTAssertTrue(dumped.contains("expiresAt"), dumped)
        let children = Mirror(reflecting: c).children
        for child in children {
            let value = String(describing: child.value) + String(reflecting: child.value)
            XCTAssertFalse(value.contains("AAA-secret"), value)
            XCTAssertFalse(value.contains("RRR-secret"), value)
        }
        XCTAssertTrue(children.contains { $0.label == "expiresAt" })
    }

    // MARK: token refresh

    func testRefreshRequest() throws {
        let r = TokenRefresh.makeRequest(refreshToken: "RRR-secret")
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.url?.absoluteString, "https://platform.claude.com/v1/oauth/token")
        XCTAssertEqual(r.value(forHTTPHeaderField: "User-Agent"), "claude-widget/1.0 (macOS)")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(r.httpBody)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(obj, ["grant_type": "refresh_token",
                             "refresh_token": "RRR-secret",
                             "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e"])
    }

    func testParseRefreshResponse() throws {
        let json = #"{"access_token":"AAA2","refresh_token":"RRR2","expires_in":28800,"refresh_token_expires_in":2592000,"scope":"user:profile user:inference","token_type":"Bearer","token_uuid":"u","account":{},"organization":{}}"#
        let now = Date(timeIntervalSince1970: 5_000)
        let c = try TokenRefresh.parseResponse(Data(json.utf8), now: now)
        XCTAssertEqual(c.accessToken, "AAA2")
        XCTAssertEqual(c.refreshToken, "RRR2")
        XCTAssertEqual(c.expiresAt, now.addingTimeInterval(28800))
    }

    func testParseRefreshResponseRejectsBadShapes() {
        let bad = [#"{"access_token":"a","expires_in":1}"#,
                   #"{"refresh_token":"r","expires_in":1}"#,
                   #"{"access_token":"a","refresh_token":"r"}"#,
                   #"{"access_token":"a","refresh_token":"r","expires_in":"28800"}"#,
                   #"{"access_token":"","refresh_token":"r","expires_in":1}"#,
                   "nope-AAA-secret"]
        for json in bad {
            XCTAssertThrowsError(try TokenRefresh.parseResponse(Data(json.utf8), now: Date())) { error in
                XCTAssertFalse(String(describing: error).contains("AAA-secret"))
                XCTAssertFalse(String(reflecting: error).contains("AAA-secret"))
            }
        }
    }

    func testNeverSentOnlyForErrorsThatProveNothingWasSent() {
        let neverSent: [URLError.Code] = [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed]
        for code in neverSent {
            XCTAssertTrue(TokenRefresh.neverSent(URLError(code)), "\(code.rawValue)")
        }
        // May have reached the server (and rotated the refresh token): never released.
        let maybeSent: [URLError.Code] = [.timedOut, .networkConnectionLost, .cancelled, .badServerResponse,
                                          .secureConnectionFailed, .unknown]
        for code in maybeSent {
            XCTAssertFalse(TokenRefresh.neverSent(URLError(code)), "\(code.rawValue)")
        }
        XCTAssertFalse(TokenRefresh.neverSent(CancellationError()))
        XCTAssertFalse(TokenRefresh.neverSent(TokenRefreshError.malformedResponse))
    }

    // MARK: reset format

    func testResetFormat() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func f(_ s: TimeInterval) -> String { ResetFormat.resetsIn(now.addingTimeInterval(s), now: now) }
        XCTAssertEqual(f(45 * 60), "45m")
        XCTAssertEqual(f(2 * 3600 + 10 * 60), "2h 10m")
        XCTAssertEqual(f(3 * 86400 + 4 * 3600), "3d 4h")
        XCTAssertEqual(f(-5), "now")
        XCTAssertEqual(f(0), "now")
    }

    func testResetFormatClampsAbsurdResetTimes() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(ResetFormat.resetsIn(Date(timeIntervalSince1970: 1e300), now: now), "999d 0h")
        XCTAssertEqual(ResetFormat.resetsIn(Date(timeIntervalSinceReferenceDate: .infinity), now: now), "999d 0h")
        XCTAssertEqual(ResetFormat.resetsIn(.distantFuture, now: now), "999d 0h")
        XCTAssertEqual(ResetFormat.resetsIn(Date(timeIntervalSinceReferenceDate: .nan), now: now), "now")
        XCTAssertEqual(ResetFormat.resetsIn(now.addingTimeInterval(998 * 86400 + 5 * 3600), now: now), "998d 5h",
                       "below the clamp, unchanged")
        // Through the parser: a huge numeric resets_at parses, then formats without trapping.
        let usage = try UsageParser.parseClaude(Data(#"{"limits":[{"kind":"weekly","percent":5,"resets_at":1e300}]}"#.utf8),
                                                fetchedAt: now)
        let resetsAt = try XCTUnwrap(usage.windows.first?.resetsAt)
        XCTAssertEqual(ResetFormat.resetsIn(resetsAt, now: now), "999d 0h")
    }

    // MARK: poll policy

    func testPollPolicy() {
        XCTAssertEqual(UsagePollPolicy.nextDelay(after: .success, consecutiveFailures: 0), 300)
        XCTAssertEqual(UsagePollPolicy.nextDelay(after: .failure, consecutiveFailures: 1), 60)
        XCTAssertEqual(UsagePollPolicy.nextDelay(after: .failure, consecutiveFailures: 3), 240)
        XCTAssertEqual(UsagePollPolicy.nextDelay(after: .failure, consecutiveFailures: 10), 1800)
        XCTAssertEqual(UsagePollPolicy.nextDelay(after: .failure, consecutiveFailures: 1000), 1800)
        XCTAssertEqual(UsagePollPolicy.nextDelay(after: .unauthorized, consecutiveFailures: 0), 1800)
    }
}
