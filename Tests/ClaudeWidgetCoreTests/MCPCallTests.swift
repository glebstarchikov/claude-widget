import XCTest
@testable import ClaudeWidgetCore

/// Splitting an MCP summary back into name and arguments, with each value's JSON
/// type, so the view can mark non-strings next to Allow.
final class MCPCallTests: XCTestCase {
    private func request(_ tool: String, _ input: String) -> ApprovalRequest {
        ApprovalRequest(id: "r1", sessionId: "s1", agentId: nil, cwd: "/tmp/p", toolName: tool,
                        toolDisplay: nil, toolInput: input, toolInputTruncated: false, ownerBundleId: "com.apple.Terminal")
    }

    /// The call as the hub shows it beside Allow: only for an allowable request.
    private func call(_ tool: String, _ input: String, file: StaticString = #filePath, line: UInt = #line) -> MCPCall? {
        let r = request(tool, input)
        guard case .allowable(let summary, _) = ApprovalPolicy.presentation(for: r) else {
            XCTFail("expected allowable", file: file, line: line)
            return nil
        }
        return MCPCall(summary: summary, request: r)
    }

    func testStringAndBooleanTrueReadAlikeButDifferInKind() throws {
        let c = try XCTUnwrap(call("mcp__db__query", #"{"dry_run":"true","force":true}"#))
        XCTAssertEqual(c.name, "mcp__db__query")
        XCTAssertEqual(c.arguments.map(\.key), ["dry_run", "force"])
        XCTAssertEqual(c.arguments.map(\.value), ["true", "true"], "the summary writes both the same way")
        XCTAssertEqual(c.arguments.map(\.kind), [.string, .boolean])
    }

    func testNumbersAndNullAreNotStrings() throws {
        let c = try XCTUnwrap(call("mcp__s__t", #"{"n":1,"s":"1","z":null}"#))
        XCTAssertEqual(c.arguments.map(\.value), ["1", "1", "null"])
        XCTAssertEqual(c.arguments.map(\.kind), [.number, .string, .null])
        let zero = try XCTUnwrap(call("mcp__s__t", #"{"f":false,"n":0,"x":1.5}"#))
        XCTAssertEqual(zero.arguments.map(\.kind), [.boolean, .number, .number], "0 and 1 are numbers, not booleans")
    }

    func testArraysAndObjects() throws {
        let c = try XCTUnwrap(call("mcp__s__t", #"{"a":[1,"x"],"o":{"k":true},"s":"[1]"}"#))
        XCTAssertEqual(c.arguments.map(\.kind), [.array, .object, .string])
        XCTAssertEqual(c.arguments.map(\.value), [#"[1,"x"]"#, #"{"k":true}"#, "[1]"])
    }

    func testAKeyContainingColonSpaceStillSplitsRight() throws {
        let c = try XCTUnwrap(call("mcp__s__t", #"{"a: b":"v: w"}"#))
        XCTAssertEqual(c.arguments, [.init(key: "a: b", value: "v: w", kind: .string)])
    }

    func testZeroArguments() throws {
        let c = try XCTUnwrap(call("mcp__s__ping", "{}"))
        XCTAssertEqual(c.name, "mcp__s__ping")
        XCTAssertTrue(c.arguments.isEmpty)
    }

    func testMismatchedSummaryOrNonMCPIsNil() {
        let r = request("mcp__s__t", #"{"a":"1"}"#)
        XCTAssertNil(MCPCall(summary: "mcp__s__t\nb: 1", request: r), "wrong key")
        XCTAssertNil(MCPCall(summary: "mcp__s__t", request: r), "missing line")
        XCTAssertNil(MCPCall(summary: "mcp__s__t\na: 1\nb: 2", request: r), "extra line")
        XCTAssertNil(MCPCall(summary: "Bash\na: 1", request: request("Bash", #"{"a":"1"}"#)), "not MCP")
        XCTAssertNil(MCPCall(summary: "mcp__s__t\na: 1", request: request("mcp__s__t", "not json")))
    }

    /// Fail closed: an MCP request the hub can't lay out as a call (key column,
    /// type badges) is open-only, so no surface offers Allow and answer() refuses it.
    func testAnMCPRequestThatCantBeSplitBackIsOpenOnly() {
        let r = request("mcp__s__t", #"{"a":true}"#)
        let openOnly = ApprovalPresentation.openOnly(summary: "mcp__s__t")
        let mismatched = ApprovalPolicy.mcpLaidOut(summary: "mcp__s__t\nb: true", fitsOneLine: false,
                                                   request: r, otherwise: openOnly)
        XCTAssertEqual(mismatched, openOnly)
        XCTAssertEqual(ApprovalPolicy.action(for: mismatched, on: .row), .open)
        XCTAssertEqual(ApprovalRules.answer(allow: true, presentation: mismatched, settled: true), .allowNotOffered)
        XCTAssertEqual(ApprovalPolicy.mcpLaidOut(summary: "mcp__s__t\na: true", fitsOneLine: false, request: r, otherwise: openOnly),
                       .allowable(summary: "mcp__s__t\na: true", fitsOneLine: false))
    }

    func testEveryAllowableMCPRequestSplitsBackWithKinds() {
        let inputs = [#"{}"#, #"{"a":"x"}"#, #"{"a: b":"v: w","c":1}"#, #"{"f":false,"n":null,"s":"true"}"#,
                      #"{"a":[1,2],"o":{"k":"v"}}"#, #"{"":"empty key"}"#, #"{"k":""}"#]
        for input in inputs {
            let r = request("mcp__srv__tool", input)
            guard case .allowable(let summary, _) = ApprovalPolicy.presentation(for: r) else {
                XCTFail("expected allowable: \(input)"); continue
            }
            let call = MCPCall(summary: summary, request: r)
            XCTAssertNotNil(call, input)
            XCTAssertEqual(call?.name, "mcp__srv__tool", input)
        }
    }
}
