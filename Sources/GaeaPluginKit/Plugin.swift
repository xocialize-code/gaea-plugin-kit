import Foundation
import GaeaProtocol
import MLXToolKit

/// A Gaea plugin, declared in code. The kit serves it over GPP and writes its manifest.json from it
/// (`<worker> --manifest`), so the manifest can't drift from what the worker does (GPP-1 §4).
///
/// ```swift
/// @main enum Main { static func main() async { await GaeaPluginMain.run(MyPlugin.definition) } }
/// ```
public struct GaeaPluginDefinition: Sendable {
    public var id: String
    public var version: String
    public var minGaea: String
    public var team: String
    public var repo: String
    public var title: String
    public var summary: String?
    public var license: String
    public var executable: String
    /// Write `engine` into the manifest and the hello. On by default: every kit worker links MLXEngine.
    /// Off only to reproduce a manifest written before the kit (the spike's demo).
    public var declaresEngine: Bool
    public var models: [ModelDefinition]
    public var offers: [PluginManifest.Offer]
    public var helpers: [PluginManifest.Helper]
    public var settings: [PluginManifest.Setting]
    public var storage: PluginManifest.Storage?
    /// Called after every `configured` (the first with `initial == true`): read settings, warm the
    /// plugin store. Runs in its own task, so it may await storage requests.
    public var onConfigure: (@Sendable (WorkerContext, _ initial: Bool) async throws -> Void)?
    /// Called when the host sends `asset_removed` (GPP-1 §3.3.2, MES Base §13 rule 6): drop anything cached under that
    /// asset id (an encoded voice reference) within 60 s. `ResidentEngine` runs a request on one of the plugin's engine
    /// models while its package is loaded (a package's own eviction call); an unloaded package holds nothing.
    public var onAssetRemoved: (@Sendable (String, ResidentEngine) async -> Void)?

    public init(id: String, version: String, minGaea: String = "0.1.0", team: String, repo: String,
                title: String, summary: String? = nil, license: String, executable: String,
                declaresEngine: Bool = true, models: [ModelDefinition], offers: [PluginManifest.Offer] = [],
                helpers: [PluginManifest.Helper] = [], settings: [PluginManifest.Setting] = [],
                storage: PluginManifest.Storage? = nil,
                onConfigure: (@Sendable (WorkerContext, _ initial: Bool) async throws -> Void)? = nil,
                onAssetRemoved: (@Sendable (String, ResidentEngine) async -> Void)? = nil) {
        self.id = id
        self.version = version
        self.minGaea = minGaea
        self.team = team
        self.repo = repo
        self.title = title
        self.summary = summary
        self.license = license
        self.executable = executable
        self.declaresEngine = declaresEngine
        self.models = models
        self.offers = offers
        self.helpers = helpers
        self.settings = settings
        self.storage = storage
        self.onConfigure = onConfigure
        self.onAssetRemoved = onAssetRemoved
    }

    public func model(_ id: String) -> ModelDefinition? { models.first { $0.id == id } }

    /// Whether the manifest offers or helps with `operation` on `model` (the host never sends
    /// anything else; a worker answers it with `unsupported_operation`).
    public func serves(_ operation: String, model: String) -> Bool {
        offers.contains { $0.operation == operation && $0.modelID == model }
            || helpers.contains { $0.operation == operation && $0.model == model }
    }
}

/// One configuration a model can run in, usually one per quant (GPP-1 §4.2). Its `ResolvedLane` is
/// the engine's own resolution of `configuration` against the package manifest.
public struct LaneDefinition: Sendable {
    public var id: String
    public var isDefault: Bool
    public var configuration: any PackageConfiguration

    public init(id: String, default isDefault: Bool = false, configuration: any PackageConfiguration) {
        self.id = id
        self.isDefault = isDefault
        self.configuration = configuration
    }
}

/// One model of the plugin: an MLXEngine `ModelPackage` the kit drives through `MLXServeEngine`,
/// or a `PluginModel` of the plugin's own (a smoke test, anything with no engine capability).
public struct ModelDefinition: Sendable {
    public enum Backing: Sendable {
        /// Registered with the worker's `MLXServeEngine` under the model's id; jobs run through
        /// `engine.run` with `CapabilityWire` envelopes.
        case engine(PackageRegistration, operations: [String: EngineOperation])
        /// The plugin's own code. The kit charges the lane's declared footprint to the engine's
        /// governor as an external tenant while it is prepared.
        case custom(@Sendable () -> any PluginModel)
    }

    public var id: String
    public var title: String
    public var manifest: PackageManifest
    public var lanes: [LaneDefinition]
    public var backing: Backing
    /// Adapters the plugin ships for this model (`shipping(_:)`): offered on every offer whose surface admits them,
    /// and registered with the engine as the registry declares them when a run names one.
    public var adapters: [ShippedAdapter] = []

    /// An MLXEngine package type, and the operations it serves.
    public static func engine<P: ModelPackage & SendableMetatype>(
        _ type: P.Type, id: String, title: String, lanes: [LaneDefinition], operations: [EngineOperation]
    ) -> ModelDefinition {
        engine(PackageRegistration.of(type), id: id, title: title, lanes: lanes, operations: operations)
    }

    public static func engine(_ registration: PackageRegistration, id: String, title: String,
                              lanes: [LaneDefinition], operations: [EngineOperation]) -> ModelDefinition {
        ModelDefinition(id: id, title: title, manifest: registration.manifest, lanes: lanes,
                        backing: .engine(registration, operations: Dictionary(
                            operations.map { ($0.operation, $0) }, uniquingKeysWith: { _, last in last })))
    }

    /// A model the plugin runs itself. `manifest` still declares its licence, provenance and
    /// footprints, which is what the host schedules from.
    public static func custom(id: String, title: String, manifest: PackageManifest, lanes: [LaneDefinition],
                              make: @escaping @Sendable () -> any PluginModel) -> ModelDefinition {
        ModelDefinition(id: id, title: title, manifest: manifest, lanes: lanes, backing: .custom(make))
    }

    /// This model, shipping `adapters` (from `AdapterRegistry.decode`). Only engine models take adapters, through
    /// their package's `AdapterSupport`.
    public func shipping(_ adapters: [ShippedAdapter]) -> ModelDefinition {
        var model = self
        model.adapters += adapters
        return model
    }

    public func lane(_ id: String) -> LaneDefinition? { lanes.first { $0.id == id } }

    public var defaultLane: LaneDefinition? { lanes.first(where: \.isDefault) ?? lanes.first }

    /// The lane's resolution, the way the manifest records it (no budget: the largest declared
    /// footprint, which never under-reserves).
    ///
    /// A configuration that is both `WeightSourcing` and `BundledWeightSourcing`, and whose variant
    /// ships its weights in the package (NAFNet's signage checkpoint), resolves in MLXToolKit 1.58 as
    /// `engine` with nothing to download; it is recorded as `bundled`, which is what it is.
    public func resolved(_ lane: LaneDefinition) -> ResolvedLane {
        let resolved = ResolvedLane(manifest: manifest, configuration: lane.configuration)
        guard resolved.materialization == .engine, resolved.weightSources.isEmpty,
              let bundled = lane.configuration as? BundledWeightSourcing, !bundled.bundledWeightSources.isEmpty else {
            return resolved
        }
        return ResolvedLane(
            contractVersion: resolved.contractVersion, quant: resolved.quant, footprintQuant: resolved.footprintQuant,
            persistentBytes: resolved.persistentBytes, persistentSource: resolved.persistentSource,
            peakTransientBytes: resolved.peakTransientBytes, peakTransientSource: resolved.peakTransientSource,
            activationScaling: resolved.activationScaling,
            expectedWeightReadBytesPerRun: resolved.expectedWeightReadBytesPerRun,
            minSustainedReadBytesPerSecond: resolved.minSustainedReadBytesPerSecond,
            materialization: .bundled, weightSources: [], selfMaterializing: resolved.selfMaterializing,
            capabilities: resolved.capabilities)
    }
}

/// How one MES operation maps onto an engine capability: the plugin owns the model-specific
/// mapping (size grid, steps, masks) and says what it actually used (GPP-1 §3.3).
public struct EngineOperation: Sendable {
    public var operation: String
    /// Build the canonical engine requests from the job, run in order. Most jobs are one call; an MES
    /// `count` above 1 on a capability that returns one result per call is one call per result
    /// (`seed + i`, Image profile §2).
    public var calls: @Sendable (Job) throws -> [EngineCall]
    /// Output names by the response field that carries them (`["image": "images"]`). A field not
    /// listed keeps its name, in snake_case.
    public var outputNames: [String: String]

    public init(_ operation: String, outputNames: [String: String] = [:],
                request: @escaping @Sendable (Job) throws -> EngineCall) {
        self.operation = operation
        self.outputNames = outputNames
        self.calls = { [try request($0)] }
    }

    /// An operation that makes several engine calls for one job. Their outputs are listed in call
    /// order, their `effective` values merged (a later call's key wins), their warnings kept once each.
    public init(_ operation: String, outputNames: [String: String] = [:],
                calls: @escaping @Sendable (Job) throws -> [EngineCall]) {
        self.operation = operation
        self.outputNames = outputNames
        self.calls = calls
    }

    /// When set, the operation runs itself: it gets the job and a session on its model's package, makes
    /// as many engine calls as it decides to (a second draft when the first is rejected, a step that reads
    /// the one before), and returns the run's outputs. `calls` and `outputNames` aren't used.
    public var perform: (@Sendable (Job, EngineSession) async throws -> RunResult)?

    public init(_ operation: String, perform: @escaping @Sendable (Job, EngineSession) async throws -> RunResult) {
        self.operation = operation
        self.outputNames = [:]
        self.calls = { _ in [] }
        self.perform = perform
    }
}

/// What a self-running `EngineOperation` runs its engine calls through: the worker's engine, on the
/// package its model registered, with the engine's progress relayed as the run's.
public struct EngineSession: Sendable {
    let send: @Sendable (any WireRequest) async throws -> any CapabilityResponse
    let sendTo: (@Sendable (String, any WireRequest) async throws -> any CapabilityResponse)?
    let streamTTS: (@Sendable (TTSRequest, @escaping @Sendable (TTSStreamChunk) -> Void) async throws -> TTSResponse)?
    let emitChunk: (@Sendable (String, [Float], Int, Int, Bool) throws -> Void)?
    let emitInt16: (@Sendable (String, Data, Int, Int, Bool) throws -> Void)?
    /// Where the run's output files go (`output_dir`).
    public let outputDir: URL
    /// The outputs the host asked to stream (GPP-1 §3.3 `streams`).
    public let streams: [String]

    public init(outputDir: URL, streams: [String] = [],
                send: @escaping @Sendable (any WireRequest) async throws -> any CapabilityResponse,
                sendTo: (@Sendable (String, any WireRequest) async throws -> any CapabilityResponse)? = nil,
                streamTTS: (@Sendable (TTSRequest, @escaping @Sendable (TTSStreamChunk) -> Void) async throws -> TTSResponse)? = nil,
                emit: (@Sendable (String, [Float], Int, Int, Bool) throws -> Void)? = nil,
                emitInt16: (@Sendable (String, Data, Int, Int, Bool) throws -> Void)? = nil) {
        self.outputDir = outputDir
        self.streams = streams
        self.send = send
        self.sendTo = sendTo
        self.streamTTS = streamTTS
        self.emitChunk = emit
        self.emitInt16 = emitInt16
    }

    /// Whether the host asked for `output` as a stream.
    public func streams(_ output: String) -> Bool { streams.contains(output) }

    /// Send samples of a streamed output to the host as one `chunk` (GPP-1 §3.3): mono or interleaved floats in [-1, 1]
    /// at the model's own rate. The last call is `final`. Gaea converts them to what the client asked for.
    public func emit(_ output: String, samples: [Float], sampleRate: Int, channels: Int = 1, final: Bool = false) throws {
        guard let emitChunk else { throw GPPError(.internal, "This session can't stream.") }
        try emitChunk(output, samples, sampleRate, channels, final)
    }

    /// Samples already made as 16-bit integers (a package's WAV data), sent as they are; Gaea passes them through to a
    /// client that asked for `pcm_s16le` at the same rate.
    public func emit(_ output: String, int16 pcm: Data, sampleRate: Int, channels: Int = 1, final: Bool = false) throws {
        guard let emitInt16 else { throw GPPError(.internal, "This session can't stream.") }
        try emitInt16(output, pcm, sampleRate, channels, final)
    }

    /// One TTS call on a `StreamEmitting` package (MLXEngine contract 1.25), each of its chunks sent to the host as
    /// `output` while it runs. Returns the package's aggregated response, the same `run` would.
    public func stream(_ request: TTSRequest, output: String = "audio") async throws -> TTSResponse {
        guard let streamTTS else { throw GPPError(.internal, "This session can't stream.") }
        let failure = LockedError()
        let response = try await streamTTS(request) { chunk in
            do { try self.emit(output, samples: chunk.samples, sampleRate: chunk.sampleRate, final: chunk.isFinal) }
            catch { failure.set(error) }
        }
        if let error = failure.value { throw error }
        return response
    }

    /// One engine call on the model's package.
    public func run(_ request: any WireRequest) async throws -> any CapabilityResponse {
        try await send(request)
    }

    /// One engine call on another engine model of the same plugin, at its default lane: a step the job's model composes
    /// with (a guarded upscale's fast tier, under the words it protects). Its weights must be on disk already.
    public func run(_ request: any WireRequest, model: String) async throws -> any CapabilityResponse {
        guard let sendTo else { throw GPPError(.internal, "This session runs only its own model.") }
        return try await sendTo(model, request)
    }
}

/// What `onAssetRemoved` runs its engine calls through: the worker's engine, on a model of the plugin only while its
/// package is loaded. Nothing is loaded for it, and nothing is downloaded.
public struct ResidentEngine: Sendable {
    let send: @Sendable (String, any WireRequest) async throws -> (any CapabilityResponse)?

    public init(send: @escaping @Sendable (String, any WireRequest) async throws -> (any CapabilityResponse)?) {
        self.send = send
    }

    /// Runs `request` on engine model `model` when its package is resident; nil, and nothing runs, when it isn't.
    @discardableResult
    public func run(_ request: any WireRequest, model: String) async throws -> (any CapabilityResponse)? {
        try await send(model, request)
    }
}

/// The first error a chunk callback hit, kept for the run to throw.
final class LockedError: @unchecked Sendable {
    private let lock = NSLock()
    private var error: (any Error)?
    func set(_ e: any Error) { lock.lock(); if error == nil { error = e }; lock.unlock() }
    var value: (any Error)? { lock.lock(); defer { lock.unlock() }; return error }
}

/// One engine call for a job: the request, and the values it will use.
public struct EngineCall: Sendable {
    public var request: any WireRequest
    public var effective: [String: JSONValue]
    public var warnings: [Warning]

    public init(_ request: any WireRequest, effective: [String: JSONValue] = [:], warnings: [Warning] = []) {
        self.request = request
        self.effective = effective
        self.warnings = warnings
    }
}

/// A model the plugin runs itself rather than through an MLXEngine package.
public protocol PluginModel: AnyObject, Sendable {
    /// Load `lane` to resident. Called before the first run on a lane, and again after `unload`.
    func prepare(lane: LaneDefinition, context: WorkerContext) async throws
    /// Drop everything resident.
    func unload() async
    /// Run one job. Check `context.checkCancellation()` at every step: a cancel arrives as a
    /// `CancellationError`.
    func run(_ job: Job, context: RunContext) async throws -> RunResult
}

/// A MES warning: a request was honoured differently than asked.
public struct Warning: Codable, Sendable, Equatable {
    public var code: String
    public var message: String
    public var param: String?

    public init(code: String, message: String, param: String? = nil) {
        self.code = code
        self.message = message
        self.param = param
    }
}

/// One output of a run: a file under the run's `output_dir`, or a small JSON value.
public struct Output: Sendable, Equatable {
    public var name: String
    public var path: String?
    public var mediaType: String?
    public var value: JSONValue?
    /// The output went to the host as `chunk`s (GPP-1 §3.3); the host builds its file from them.
    public var streamed = false

    public static func file(_ name: String, _ url: URL, mediaType: String) -> Output {
        Output(name: name, path: url.path, mediaType: mediaType, value: nil)
    }

    public static func value(_ name: String, _ value: JSONValue) -> Output {
        Output(name: name, path: nil, mediaType: nil, value: value)
    }

    /// An output sent as chunks (`RunContext.emit`, `EngineSession.emit`): listed in the result with no file.
    public static func streamed(_ name: String) -> Output {
        Output(name: name, path: nil, mediaType: nil, value: nil, streamed: true)
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["name": .string(name)]
        if let path { o["path"] = .string(path) }
        if let mediaType { o["media_type"] = .string(mediaType) }
        if let value { o["value"] = value }
        if streamed { o["streamed"] = true }
        return .object(o)
    }
}

/// What a successful run returns (`result`).
public struct RunResult: Sendable {
    public var outputs: [Output]
    public var effective: [String: JSONValue]
    public var warnings: [Warning]

    public init(outputs: [Output], effective: [String: JSONValue] = [:], warnings: [Warning] = []) {
        self.outputs = outputs
        self.effective = effective
        self.warnings = warnings
    }
}

/// One `run`, as the worker received it.
public struct Job: Sendable {
    /// The request id (`run.id`); replies carry it as `re`.
    public var requestID: String
    public var job: String
    public var operation: String
    public var model: String
    public var lane: String
    /// Input files by name; a single path arrives as a one-element array.
    public var inputs: [String: [URL]]
    /// Profile-vocabulary params, already normalized by Gaea.
    public var params: [String: JSONValue]
    /// The client's `x-` extension params, unchanged.
    public var modelParams: [String: JSONValue]
    /// The adapters to apply (GPP-1 §3.3), in the client's order. `adapterRefs()` puts them on a request.
    public var adapters: [JobAdapter]
    public var seed: UInt64?
    public var outputDir: URL
    /// The outputs the host asked to stream (GPP-1 §3.3): send them with `emit` and list them as `.streamed`.
    public var streams: [String] = []
    /// The MES asset id behind each input value, by input name (nil for one that isn't an asset): key a cache of what
    /// the model derives from an input by it, never by the file's bytes (MES Base §13 rule 6).
    public var assets: [String: [String?]] = [:]

    /// Whether the host asked for `output` as a stream.
    public func streams(_ output: String) -> Bool { streams.contains(output) }

    /// The asset id of input `name`'s value `index`, if it is an asset.
    public func asset(_ name: String, index: Int = 0) -> String? {
        guard let ids = assets[name], index < ids.count else { return nil }
        return ids[index]
    }

    public func param(_ name: String) -> JSONValue? { params[name] ?? modelParams[name] }

    /// The first file of input `name`.
    public func input(_ name: String) -> URL? { inputs[name]?.first }

    /// A text input (an MES `prompt` or `instruction`), which Gaea sends as a UTF-8 file (GPP-1 §3.3).
    /// nil when the run has no such input.
    public func text(_ name: String, index: Int = 0) throws -> String? {
        guard let urls = inputs[name], index < urls.count else { return nil }
        do {
            return try String(contentsOf: urls[index], encoding: .utf8)
        } catch {
            throw GPPError(.invalidRequest, "Input \(name) isn't a readable UTF-8 file: \(urls[index].lastPathComponent).")
        }
    }

    /// Decode an input image through MLXToolKit's wire codec (the bytes are memory-mapped, not
    /// copied). The format comes from the file extension.
    public func image(_ name: String, index: Int = 0) throws -> Image {
        guard let urls = inputs[name], index < urls.count else {
            throw GPPError(.invalidRequest, "The run has no input \(name)[\(index)].")
        }
        return try imageFile(urls[index], name: "Input \(name)")
    }

    func imageFile(_ url: URL, name: String) throws -> Image {
        let format: String
        switch url.pathExtension.lowercased() {
        case "png": format = "png"
        case "jpg", "jpeg": format = "jpeg"
        default: throw GPPError(.invalidRequest, "\(name) is not a PNG or JPEG file: \(url.lastPathComponent).")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw GPPError(.invalidRequest, "\(name) isn't a readable file: \(url.path).")
        }
        let reference: JSONValue = ["format": .string(format), "file": .string(url.path)]
        return try CapabilityWire.decoder(spool: ArtifactSpool(directory: outputDir))
            .decode(Image.self, from: JSONEncoder().encode(reference))
    }
}
