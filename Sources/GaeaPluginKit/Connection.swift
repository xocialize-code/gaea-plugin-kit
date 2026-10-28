import Foundation
import GaeaProtocol

/// The worker's end of the pipe: writes one line per message, and matches the host's replies to the
/// requests the worker itself sends (the plugin store, GPP-1 §3.6).
public final class GPPConnection: @unchecked Sendable {
    private let write: @Sendable (Data) -> Void
    private let lock = NSLock()
    private var nextRequest = 0
    private var pending: [String: CheckedContinuation<[String: JSONValue], Never>] = [:]

    /// `write` receives each line, newline included, already serialized; it must not reorder them.
    public init(write: @escaping @Sendable (Data) -> Void) {
        self.write = write
    }

    /// stdout. Nothing else may write to it (logs go to stderr).
    public static func standardOutput() -> GPPConnection {
        let out = FileHandle.standardOutput
        return GPPConnection { out.write($0) }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    /// Send one message. Messages are written whole and in call order.
    public func send(_ message: [String: JSONValue]) {
        guard var data = try? Self.encoder.encode(message) else {
            log("could not encode a \(message["type"]?.stringValue ?? "?") message")
            return
        }
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        write(data)
    }

    /// Send a worker request and wait for the host's reply (`storage.result` or `error`).
    func request(_ message: [String: JSONValue]) async -> [String: JSONValue] {
        await withCheckedContinuation { continuation in
            lock.lock()
            nextRequest += 1
            let id = "w\(nextRequest)"
            pending[id] = continuation
            lock.unlock()
            var message = message
            message["id"] = .string(id)
            send(message)
        }
    }

    /// Route a host reply to the worker request it answers. False when it answers nothing.
    func resolve(_ reply: [String: JSONValue]) -> Bool {
        guard let re = reply["re"]?.stringValue else { return false }
        lock.lock()
        let continuation = pending.removeValue(forKey: re)
        lock.unlock()
        continuation?.resume(returning: reply)
        return continuation != nil
    }

    func answersWorkerRequest(_ re: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending[re] != nil
    }
}

/// Log to stderr, which Gaea keeps in the plugin's log.
public func log(_ message: String) {
    FileHandle.standardError.write(Data("[gaea-plugin] \(message)\n".utf8))
}

/// The plugin's own namespaced store in `gaea.sqlite`, reached through the host (GPP-1 §3.6). The
/// plugin never opens the database itself (G-5, G-16).
public struct PluginStorage: Sendable {
    let connection: GPPConnection

    public struct Item: Sendable, Equatable {
        public var key: String
        public var value: JSONValue
    }

    public func get(_ namespace: String, _ key: String) async throws -> JSONValue? {
        let reply = try await call(["type": "storage.get", "namespace": .string(namespace), "key": .string(key)])
        return reply["found"]?.boolValue == true ? (reply["value"] ?? .null) : nil
    }

    public func put(_ namespace: String, _ key: String, _ value: JSONValue) async throws {
        if let size = try? JSONEncoder().encode(value).count, size > GPP.maxStorageValueBytes {
            throw GPPError(.storageFailed, "Value is larger than 1 MiB (\(size) bytes); not sent.")
        }
        _ = try await call(["type": "storage.put", "namespace": .string(namespace), "key": .string(key),
                            "value": value])
    }

    public func delete(_ namespace: String, _ key: String) async throws {
        _ = try await call(["type": "storage.delete", "namespace": .string(namespace), "key": .string(key)])
    }

    /// One page of keys in key order, and whether more follow.
    public func query(_ namespace: String, prefix: String? = nil, after: String? = nil,
                      limit: Int? = nil) async throws -> (items: [Item], more: Bool) {
        var message: [String: JSONValue] = ["type": "storage.query", "namespace": .string(namespace)]
        if let prefix { message["prefix"] = .string(prefix) }
        if let after { message["after"] = .string(after) }
        if let limit { message["limit"] = .int(Int64(limit)) }
        let reply = try await call(message)
        let items = (reply["items"]?.arrayValue ?? []).compactMap { item -> Item? in
            guard let key = item["key"]?.stringValue else { return nil }
            return Item(key: key, value: item["value"] ?? .null)
        }
        return (items, reply["more"]?.boolValue ?? false)
    }

    private func call(_ message: [String: JSONValue]) async throws -> [String: JSONValue] {
        let reply = await connection.request(message)
        if reply["type"]?.stringValue == "error" {
            throw GPPError(GPP.ErrorCode(rawValue: reply["code"]?.stringValue ?? "") ?? .storageFailed,
                           reply["message"]?.stringValue ?? "storage request failed",
                           retryable: reply["retryable"]?.boolValue ?? false)
        }
        return reply
    }
}

/// What every plugin hook sees: the operator's settings, the folders, and the store.
public struct WorkerContext: Sendable {
    public var settings: [String: JSONValue]
    /// The shared model store (G-9), `configure.models_root`.
    public var modelsRoot: URL
    /// The plugin's own cache, `configure.cache_root`; also the working directory.
    public var cacheRoot: URL
    public var storage: PluginStorage

    /// A setting's value, else its manifest default.
    public func setting(_ key: String) -> JSONValue? { settings[key] }
}

/// What a running job sees: progress, streamed chunks, cancellation.
public final class RunContext: @unchecked Sendable {
    public let worker: WorkerContext
    let job: Job
    private let connection: GPPConnection
    private let lock = NSLock()
    private(set) var lastStep: Int?
    private(set) var lastOf: Int?

    init(worker: WorkerContext, job: Job, connection: GPPConnection) {
        self.worker = worker
        self.job = job
        self.connection = connection
    }

    /// Report progress. `stage` is the worker's own phase (`denoise`). The kit sends `fraction` only
    /// when given; for an engine run it passes `step / of`.
    public func progress(_ stage: String, step: Int? = nil, of: Int? = nil, fraction: Double? = nil,
                         message: String? = nil) {
        var m: [String: JSONValue] = ["type": "progress", "re": .string(job.requestID), "job": .string(job.job),
                                      "stage": .string(GPP.isName(stage) ? stage : GPP.stageName(stage))]
        if let step { m["step"] = .int(Int64(max(0, step))) }
        if let of, of >= 1 { m["of"] = .int(Int64(of)) }
        if let fraction { m["fraction"] = .double(min(1, max(0, fraction))) }
        if let message { m["message"] = .string(message) }
        lock.lock()
        if let step { lastStep = step }
        if let of { lastOf = of }
        lock.unlock()
        connection.send(m)
    }

    /// One piece of a streamed output, already written under `output_dir` (MES RFC 0002).
    public func chunk(output: String, index: Int, file: URL, mediaType: String, final: Bool = false) {
        var m: [String: JSONValue] = ["type": "chunk", "re": .string(job.requestID), "job": .string(job.job),
                                      "output": .string(output), "index": .int(Int64(index)),
                                      "path": .string(file.path), "media_type": .string(mediaType)]
        if final { m["final"] = true }
        connection.send(m)
    }

    /// Throws `CancellationError` once the host has sent `cancel` (or `shutdown`).
    public func checkCancellation() throws { try Task.checkCancellation() }

    public var isCancelled: Bool { Task.isCancelled }

    /// "Cancelled at step 3 of 10." from the last progress reported.
    var cancelMessage: String {
        lock.lock()
        defer { lock.unlock() }
        if let step = lastStep, let of = lastOf { return "Cancelled at step \(min(step + 1, of)) of \(of)." }
        return "Cancelled."
    }
}
