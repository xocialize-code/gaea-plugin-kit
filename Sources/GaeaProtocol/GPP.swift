import Foundation

/// The Gaea Plugin Protocol, version 1 (GPP-1, schemas/v1/gpp.schema.json): one JSON object per line,
/// host to worker on stdin, worker to host on stdout.
public enum GPP {
    /// The protocol major version this kit speaks.
    public static let version = 1
    /// The longest line either side may send, newline excluded.
    public static let maxLineBytes = 1 << 20
    /// How a streamed chunk's samples are laid out in its file (GPP-1 §3.3.1): little-endian 32-bit float, or 16-bit
    /// signed integer, interleaved, at the chunk's `sample_rate` and `channels`.
    public static let pcmF32 = "pcm_f32le", pcmS16 = "pcm_s16le"
    /// The one Developer ID team v1 trusts (G-22, AB-D-0184). A bundle signed by any other team is
    /// refused, and so is a manifest naming one. A trust list the operator approves ships in G4.
    public static let trustedTeam = "CFZS6RXUCP"
    /// The largest value `storage.put` accepts, encoded.
    public static let maxStorageValueBytes = 1 << 20

    public enum Direction: String, Sendable {
        case hostToWorker = "H→W"
        case workerToHost = "W→H"
        case either
    }

    /// Every message type, and which way it goes (the schema's `x-gaea-direction`).
    public static let directions: [String: Direction] = [
        "hello": .workerToHost, "configure": .hostToWorker, "configured": .workerToHost,
        "materialize": .hostToWorker, "materialize.progress": .workerToHost, "materialize.done": .workerToHost,
        "prepare": .hostToWorker, "prepared": .workerToHost, "run": .hostToWorker, "progress": .workerToHost,
        "chunk": .workerToHost, "result": .workerToHost, "error": .either, "cancel": .hostToWorker,
        "unload": .hostToWorker, "unloaded": .workerToHost, "shutdown": .hostToWorker,
        "memory.query": .hostToWorker, "memory": .workerToHost, "storage.get": .workerToHost,
        "storage.put": .workerToHost, "storage.delete": .workerToHost, "storage.query": .workerToHost,
        "storage.result": .hostToWorker, "asset_removed": .hostToWorker,
    ]

    /// The fields each host-to-worker message may carry (the schema is closed: anything else is
    /// `invalid_request`), and which of them are required.
    public static let hostFields: [String: (required: Set<String>, optional: Set<String>)] = [
        "configure": (["type", "id", "budget", "models_root", "cache_root", "settings"], []),
        "materialize": (["type", "id", "model", "lane"], []),
        "prepare": (["type", "id", "model", "lane"], []),
        "run": (["type", "id", "job", "operation", "model", "lane", "inputs", "params", "output_dir"],
                ["model_params", "adapters", "seed", "streams", "assets"]),
        "cancel": (["type", "id", "job"], []),
        "unload": (["type", "id", "model"], ["lane"]),
        "shutdown": (["type", "id"], []),
        "memory.query": (["type", "id"], []),
        "asset_removed": (["type", "id", "asset"], []),
        "storage.result": (["type", "re"], ["found", "value", "items", "more"]),
        "error": (["type", "code", "message", "retryable"], ["re", "job", "detail"]),
    ]

    /// GPP-1 §3.5.
    public enum ErrorCode: String, Codable, Sendable, CaseIterable {
        case cancelled
        case invalidRequest = "invalid_request"
        case unsupportedOperation = "unsupported_operation"
        case unknownModel = "unknown_model"
        case notMaterialized = "not_materialized"
        case materializeFailed = "materialize_failed"
        case outOfMemory = "out_of_memory"
        /// `prepare` refused: the weights' volume reads slower than the lane's floor (GPP-1 §3.2.1).
        case storageBelowFloor = "storage_below_floor"
        case modelError = "model_error"
        case storageFailed = "storage_failed"
        case busy
        case `protocol`
        case `internal`
    }

    /// The pattern a `progress.stage`, an output name or a warning code must match.
    public static func isName(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, ("a"..."z").contains(first) else { return false }
        return s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    /// Fold any phase name into a stage name: lower case, `_` for anything else (`encode-prompt` →
    /// `encode_prompt`).
    public static func stageName(_ raw: String) -> String {
        var out = String(raw.lowercased().unicodeScalars.map {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) ? Character($0) : "_"
        })
        if out.first.map({ !("a"..."z").contains($0) }) ?? true { out = "x" + out }
        return out
    }
}

/// A protocol error a worker reports for one request.
public struct GPPError: Error, Sendable, CustomStringConvertible {
    public var code: GPP.ErrorCode
    public var message: String
    public var retryable: Bool
    public var detail: [String: JSONValue]?

    public init(_ code: GPP.ErrorCode, _ message: String, retryable: Bool = false,
                detail: [String: JSONValue]? = nil) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.detail = detail
    }

    public var description: String { "\(code.rawValue): \(message)" }
}
