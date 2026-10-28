import Foundation
import GaeaPluginKit
import GaeaProtocol

/// Drives a `GPPWorker` in process from a transcript: sends its `H` lines in order, and checks each
/// `W` line against what the worker actually wrote, field by field, with only the values a run
/// can't reproduce masked (pid, timings, measured memory, a checksum).
///
/// Transcripts name paths under `/Users/me/`; the replay maps them into a scratch directory and back.
/// A comment `# stdin (not JSON): <text>` sends `<text>` as a raw line.
final class Replay: @unchecked Sendable {
    let transcript: URL
    let manifest: URL
    let scratch: URL
    private let lines = LineQueue()
    private let exited = LineQueue()
    private(set) var session: [String] = []

    static let placeholderRoot = "/Users/me/"
    /// Fields whose values differ on every run, or with every kit release (`kit`: the transcripts
    /// are kit-agnostic).
    static let volatile: Set<String> = ["pid", "seconds", "date", "kit"]
    /// Measurements a report carries when the syscall or MLX's device answered: dropped from both sides.
    static let measured: Set<String> = ["physFootprintBytes", "gpuActiveBytes", "gpuCacheBytes"]

    init(transcript: URL) throws {
        self.transcript = transcript
        let text = try String(contentsOf: transcript, encoding: .utf8)
        guard let name = text.split(separator: "\n").first(where: { $0.hasPrefix("# manifest:") })?
            .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) else {
            throw ReplayError("\(transcript.lastPathComponent) names no manifest")
        }
        manifest = Spec.manifest(name)
        scratch = FileManager.default.temporaryDirectory.appending(path: "gaea-replay-\(UUID().uuidString)/")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    func toScratch(_ s: String) -> String { s.replacingOccurrences(of: Self.placeholderRoot, with: scratch.path + "/") }
    func fromScratch(_ s: String) -> String { s.replacingOccurrences(of: scratch.path + "/", with: Self.placeholderRoot) }

    /// Replay against `definition`. Throws on the first mismatch.
    func run(_ definition: GaeaPluginDefinition) async throws {
        let connection = GPPConnection { [lines] data in
            lines.push(String(decoding: data.dropLast(), as: UTF8.self))
        }
        let worker = GPPWorker(definition: definition, manifest: try Data(contentsOf: manifest),
                               connection: connection, engineFactory: fakeEngineFactory,
                               onExit: { [exited] status in exited.push("\(status)") })
        await worker.sendHello()

        let text = try String(contentsOf: transcript, encoding: .utf8)
        for (n, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let where_ = "\(transcript.lastPathComponent):\(n + 1)"
            if raw.hasPrefix("# stdin (not JSON): ") {
                await worker.handle(line: String(raw.dropFirst("# stdin (not JSON): ".count)))
                continue
            }
            if raw.hasPrefix("H ") {
                let line = toScratch(String(raw.dropFirst(2)))
                session.append("H " + line)
                await worker.handle(line: line)
            } else if raw.hasPrefix("W ") {
                guard let actual = await lines.pop(timeout: .seconds(20)) else {
                    throw ReplayError("\(where_): the worker sent nothing; expected \(raw.dropFirst(2))")
                }
                session.append("W " + actual)
                let expected = try Self.parse(String(raw.dropFirst(2)))
                let got = try Self.parse(fromScratch(actual))
                if Self.normalized(expected) != Self.normalized(got) {
                    throw ReplayError("\(where_):\n  expected \(raw.dropFirst(2))\n  got      \(fromScratch(actual))")
                }
            }
        }
        if let extra = await lines.pop(timeout: .milliseconds(300)) {
            throw ReplayError("\(transcript.lastPathComponent): the worker sent more than the transcript: \(fromScratch(extra))")
        }
        if text.contains("\"type\":\"shutdown\"") {
            guard await exited.pop(timeout: .seconds(10)) == "0" else {
                throw ReplayError("\(transcript.lastPathComponent): the worker did not exit 0 after shutdown")
            }
        }
    }

    /// Write the session as it happened (scratch paths and all), headed by the manifest it ran
    /// against, for tools/validate.py --transcript.
    func writeSession() throws -> URL {
        let url = scratch.appending(path: "session.gpp")
        let header = "# manifest: \(manifest.path)\n# Replayed from \(transcript.lastPathComponent) by GaeaPluginKitTests.\n"
        try (header + session.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func parse(_ line: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
    }

    /// Mask what can't repeat: volatile fields, and the values a run computes.
    static func normalized(_ v: JSONValue) -> JSONValue {
        switch v {
        case .object(var o):
            for key in volatile where o[key] != nil { o[key] = "…" }
            for key in measured { o[key] = nil }
            if o["type"] == "result", case .array(let outputs)? = o["outputs"] {
                o["outputs"] = .array(outputs.map { out in
                    guard case .object(var oo) = out, oo["value"] != nil else { return out }
                    oo["value"] = "…"
                    return .object(oo)
                })
            }
            return .object(o.mapValues(normalized))
        case .array(let a):
            return .array(a.map(normalized))
        case .double(let d) where d == d.rounded() && abs(d) < 9e15:
            return .int(Int64(d))
        default:
            return v
        }
    }
}

struct ReplayError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Lines the worker wrote, awaited one at a time.
final class LineQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [String] = []
    private var waiter: (id: UUID, continuation: CheckedContinuation<String?, Never>)?

    func push(_ line: String) {
        lock.lock()
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.continuation.resume(returning: line)
        } else {
            buffer.append(line)
            lock.unlock()
        }
    }

    func pop(timeout: Duration) async -> String? {
        let id = UUID()
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            lock.lock()
            if !buffer.isEmpty {
                let line = buffer.removeFirst()
                lock.unlock()
                c.resume(returning: line)
                return
            }
            waiter = (id, c)
            lock.unlock()
            Task {
                try? await Task.sleep(for: timeout)
                self.expire(id)
            }
        }
    }

    /// Time out this pop's own waiter only: a later pop has a waiter of its own.
    private func expire(_ id: UUID) {
        lock.lock()
        guard let w = waiter, w.id == id else { lock.unlock(); return }
        waiter = nil
        lock.unlock()
        w.continuation.resume(returning: nil)
    }
}
