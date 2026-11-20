import Foundation
import os
import ClaudeWidgetCore

extension Logger {
    /// Limits logging: status codes and fixed text only, never a token or a body.
    static let limits = Logger(subsystem: "com.glebstarchikov.claude-widget", category: "limits")
}

/// Keychain access for the limits feed, all through `/usr/bin/security` (items
/// it creates don't re-prompt after rebuilds of the ad-hoc-signed app).
/// Secrets travel only on pipes, stdout for reads and stdin for writes, never
/// in a process's arguments. The tool's raw output is never logged.
enum WidgetKeychain {
    /// The widget's own copy of a Claude sign-in: read and written.
    static let service = "Claude Widget-usage-credentials"
    /// Claude Code's sign-in: read-only. Nothing here writes it.
    static let claudeCodeService = "Claude Code-credentials"
    /// `security`'s exit status for errSecItemNotFound.
    private static let notFound: Int32 = 44

    enum Read {
        case found(OAuthCredential)
        /// No entry, or one that doesn't decode: safe to replace.
        case absent
        /// Any other failure (e.g. a locked Keychain): the entry may exist, so don't replace it.
        case failed(Int32)
    }

    static func readOwn() async -> Read {
        let out = await run(["find-generic-password", "-s", service, "-a", NSUserName(), "-w"])
        if out.status == notFound { return .absent }
        guard out.status == 0 else { return .failed(out.status) }
        guard let credential = try? JSONDecoder().decode(OAuthCredential.self, from: trimmed(out.stdout))
        else { return .absent }
        return .found(credential)
    }

    static func readClaudeCode() async -> OAuthCredential? {
        var out = await run(["find-generic-password", "-s", claudeCodeService, "-a", NSUserName(), "-w"])
        if out.status == notFound {
            out = await run(["find-generic-password", "-s", claudeCodeService, "-w"])
        }
        guard out.status == 0 else { return nil }
        return CredentialParser.parseClaudeCode(keychainJSON: trimmed(out.stdout))
    }

    /// Writes `credential` to the widget's own entry, then verifies the write:
    /// exit status 0, nothing on stderr, and a read-back that decodes equal.
    static func save(_ credential: OAuthCredential) async -> Bool {
        guard let json = try? JSONEncoder().encode(credential) else { return false }
        let hex = json.map { String(format: "%02x", $0) }.joined()
        let command = "add-generic-password -U -a \"\(NSUserName())\" -s \"\(service)\" -X \(hex)\n"
        let out = await run(["-i"], input: Data(command.utf8))
        guard out.status == 0, out.stderr.isEmpty else {
            Logger.limits.error("save failed (status \(out.status))")
            return false
        }
        guard case .found(let stored) = await readOwn(), stored == credential else {
            Logger.limits.error("save failed (read-back mismatch)")
            return false
        }
        return true
    }

    // MARK: - Plumbing

    private struct Output {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    /// Runs `security` on a background queue; `input` goes to its stdin.
    private static func run(_ arguments: [String], input: Data? = nil) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(arguments, input: input))
            }
        }
    }

    private static func runBlocking(_ arguments: [String], input: Data?) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch { return Output(status: -1, stdout: Data(), stderr: Data()) }
        if let input {
            let writer = stdin.fileHandleForWriting
            // If security exits before reading, fail the write with EPIPE instead of killing the app.
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            try? writer.write(contentsOf: input)
            try? writer.close()
        }
        // Both stay in memory only. stderr is a line or two, so reading stdout first can't stall.
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, stdout: out, stderr: err)
    }

    /// `-w` ends the value with a newline.
    private static func trimmed(_ data: Data) -> Data {
        data.last == 0x0A ? data.dropLast() : data
    }
}
