import CryptoKit
import Foundation
import GaeaProtocol
import MLXServeCore
import MLXToolKit

/// The GPP v1 worker: hello, then every host-to-worker message in GPP-1 §3, over one `MLXServeEngine`
/// built from the host's `WorkerBudget`.
///
/// Lines are handled in arrival order. Anything long (materialize, prepare, run, the configure
/// hook) runs in a task of its own, so `cancel`, `memory.query` and the host's replies to storage
/// requests are answered while it works.
public actor GPPWorker {
    /// Builds the engine from `configure.budget`. Tests inject a materializer and hub metadata here.
    public typealias EngineFactory = @Sendable (WorkerBudget) -> MLXServeEngine

    public let definition: GaeaPluginDefinition
    nonisolated let connection: GPPConnection
    private let manifestSHA256: String
    private let makeEngine: EngineFactory
    private let onExit: @Sendable (Int32) -> Void

    private var lineNumber = 0
    private var helloSent = false
    private var shuttingDown = false
    private var engine: MLXServeEngine?
    private var context: WorkerContext?

    /// Engine models: the lane registered under the model's id (one lane per model at a time).
    private var registeredLane: [String: String] = [:]
    /// Custom models: the instance, its prepared lane, and the footprint charged for it.
    private var customs: [String: CustomState] = [:]
    private var run: ActiveRun?

    private struct CustomState {
        var instance: any PluginModel
        var preparedLane: String?
        var tenant: ExternalTenant?
    }

    private struct ActiveRun {
        let requestID: String
        let job: String
        let model: String
        let task: Task<Void, Never>
    }

    /// - Parameters:
    ///   - manifest: the bytes of the bundle's manifest.json; `hello.manifest_sha256` is their digest.
    ///   - onExit: called once, after `shutdown` or the end of stdin, with the exit status.
    public init(definition: GaeaPluginDefinition, manifest: Data, connection: GPPConnection,
                engineFactory: @escaping EngineFactory = { MLXServeEngine(workerBudget: $0) },
                onExit: @escaping @Sendable (Int32) -> Void) {
        self.definition = definition
        self.connection = connection
        self.manifestSHA256 = SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined()
        self.makeEngine = engineFactory
        self.onExit = onExit
    }

    // MARK: - Start

    /// The worker's first line (GPP-1 §2.2).
    public func sendHello() {
        guard !helloSent else { return }
        helloSent = true
        var hello: [String: JSONValue] = [
            "type": "hello", "protocol": .int(Int64(GPP.version)),
            "plugin": ["id": .string(definition.id), "version": .string(definition.version)],
            "pid": .int(Int64(getpid())),
            "models": .array(definition.models.map { .string($0.id) }),
            "manifest_sha256": .string(manifestSHA256),
            "kit": ["version": .string(GaeaPluginKitInfo.version)],
        ]
        if definition.declaresEngine {
            hello["engine"] = ["version": .string(GaeaPluginKitInfo.engineVersion),
                               "contract": .string(GaeaPluginKitInfo.engineContract)]
        }
        connection.send(hello)
    }

    // MARK: - Lines

    /// Handle one line of stdin (without its newline).
    public func handle(line: String) async {
        lineNumber += 1
        guard !shuttingDown else { return }
        if line.utf8.count > GPP.maxLineBytes {
            return protocolError("Line \(lineNumber) of stdin is longer than 1 MiB; ignored.")
        }
        guard let data = line.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let message = value.objectValue
        else {
            return protocolError("Line \(lineNumber) of stdin is not valid JSON; ignored.")
        }
        guard let type = message["type"]?.stringValue else {
            return protocolError("Line \(lineNumber) of stdin has no type; ignored.")
        }
        guard let direction = GPP.directions[type] else {
            return protocolError("Line \(lineNumber) of stdin has unknown type \(type); ignored.")
        }
        guard direction != .workerToHost else {
            return protocolError("Line \(lineNumber) of stdin is a \(type), which only a worker sends; ignored.")
        }
        let requestID = message["id"]?.stringValue
        if let fields = GPP.hostFields[type] {
            let keys = Set(message.keys)
            let missing = fields.required.subtracting(keys).sorted()
            let unknown = keys.subtracting(fields.required).subtracting(fields.optional).sorted()
            if !missing.isEmpty || !unknown.isEmpty {
                var why: [String] = []
                if !missing.isEmpty { why.append("missing \(missing.joined(separator: ", "))") }
                if !unknown.isEmpty { why.append("unknown \(unknown.joined(separator: ", "))") }
                return reply(error: GPPError(.invalidRequest, "\(type): \(why.joined(separator: "; ")).",
                                             retryable: false), re: requestID, job: message["job"]?.stringValue)
            }
        }

        switch type {
        case "storage.result", "error":
            // Replies to the worker's own requests.
            if type == "error", message["re"] == nil {
                log("host reported a protocol error: \(message["message"]?.stringValue ?? "")")
                return
            }
            if !connection.resolve(message) {
                protocolError("Line \(lineNumber) of stdin answers \(message["re"]?.stringValue ?? "?"), which the worker never sent; ignored.")
            }
            return
        case "shutdown":
            await shutdown()
            return
        case "configure":
            await configure(message, id: requestID!)
            return
        default:
            break
        }
        guard context != nil, engine != nil else {
            return reply(error: GPPError(.invalidRequest, "\(type) before configure; the host sends configure first."),
                         re: requestID, job: message["job"]?.stringValue)
        }
        switch type {
        case "materialize": startMaterialize(message, id: requestID!)
        case "prepare": startPrepare(message, id: requestID!)
        case "run": startRun(message, id: requestID!)
        case "cancel": cancel(job: message["job"]?.stringValue ?? "")
        case "unload": await unload(message, id: requestID!)
        case "memory.query": await sendMemory(re: requestID)
        default: protocolError("Line \(lineNumber) of stdin: \(type) is not handled; ignored.")
        }
    }

    /// stdin ended: the host is gone. Finish like `shutdown`.
    public func endOfInput() async {
        await shutdown()
    }

    // MARK: - configure

    private func configure(_ m: [String: JSONValue], id: String) async {
        let budget: WorkerBudget
        do {
            budget = try (m["budget"] ?? .null).decode(WorkerBudget.self)
        } catch {
            return reply(error: GPPError(.invalidRequest, "configure.budget is not a WorkerBudget: \(error)"), re: id)
        }
        guard let modelsRoot = m["models_root"]?.stringValue, modelsRoot.hasPrefix("/"),
              let cacheRoot = m["cache_root"]?.stringValue, cacheRoot.hasPrefix("/"),
              let settings = m["settings"]?.objectValue
        else {
            return reply(error: GPPError(.invalidRequest, "configure needs absolute models_root and cache_root, and settings."), re: id)
        }
        let initial = engine == nil
        if initial {
            let engine = makeEngine(budget)
            await engine.useModelStore(ModelStore(root: URL(fileURLWithPath: modelsRoot, isDirectory: true)))
            self.engine = engine
        }
        let ctx = WorkerContext(settings: definition.settings(merging: settings),
                                modelsRoot: URL(fileURLWithPath: modelsRoot, isDirectory: true),
                                cacheRoot: URL(fileURLWithPath: cacheRoot, isDirectory: true),
                                storage: PluginStorage(connection: connection))
        context = ctx
        connection.send(["type": "configured", "re": .string(id)])
        if let hook = definition.onConfigure {
            Task {
                do { try await hook(ctx, initial) } catch { log("onConfigure failed: \(error)") }
            }
        }
    }

    // MARK: - Lookup

    private func lookup(_ m: [String: JSONValue], laneRequired: Bool = true) throws
        -> (ModelDefinition, LaneDefinition?)
    {
        let modelID = m["model"]?.stringValue ?? ""
        guard let model = definition.model(modelID) else {
            throw GPPError(.unknownModel, "No model \(modelID) in this plugin.")
        }
        guard let laneID = m["lane"]?.stringValue else {
            if laneRequired { throw GPPError(.invalidRequest, "No lane named.") }
            return (model, nil)
        }
        guard let lane = model.lane(laneID) else {
            throw GPPError(.unknownModel, "No lane \(laneID) of \(modelID).")
        }
        return (model, lane)
    }

    /// Register an engine model's lane under the model's id, replacing another lane of it.
    private func ensureRegistered(_ model: ModelDefinition, _ lane: LaneDefinition,
                                  forRun runID: String? = nil) async throws -> PackageID {
        guard case .engine(let registration, _) = model.backing, let engine else {
            throw GPPError(.internal, "\(model.id) is not an engine model.")
        }
        let id = PackageID(model.id)
        if registeredLane[model.id] == lane.id { return id }
        if let run, run.model == model.id, run.requestID != runID {
            throw GPPError(.busy, "\(model.id) is running on lane \(registeredLane[model.id] ?? "?"); "
                + "lane \(lane.id) can load once the run ends.", retryable: true)
        }
        do {
            try await engine.register(registration, configuration: lane.configuration, id: id)
        } catch {
            throw Self.translate(error)
        }
        registeredLane[model.id] = lane.id
        return id
    }

    private func capability(_ model: ModelDefinition, _ lane: LaneDefinition) throws -> Capability {
        guard let capability = model.resolved(lane).capabilities.first ?? model.manifest.capabilities.first else {
            throw GPPError(.invalidRequest, "Lane \(lane.id) of \(model.id) backs no capability at its quant.")
        }
        return capability
    }

    // MARK: - materialize

    private func startMaterialize(_ m: [String: JSONValue], id: String) {
        Task { await self.materialize(m, id: id) }
    }

    private func materialize(_ m: [String: JSONValue], id: String) async {
        let began = Date()
        do {
            let (model, laneOpt) = try lookup(m)
            let lane = laneOpt!
            let resolved = model.resolved(lane)
            switch resolved.materialization {
            case .bundled:
                connection.send(["type": "materialize.done", "re": .string(id), "model": .string(model.id),
                                 "lane": .string(lane.id), "bytes": 0, "seconds": .double(seconds(since: began))])
                return
            case .package, .undeclared:
                throw GPPError(.invalidRequest, "Lane \(lane.id) of \(model.id) is materialized by its package "
                    + "(\(resolved.materialization.rawValue)); send prepare instead.")
            case .engine:
                break
            }
            guard case .engine = model.backing, let engine else {
                throw GPPError(.invalidRequest, "\(model.id) is not an engine model; send prepare.")
            }
            let packageID = try await ensureRegistered(model, lane)
            let total = await engine.materializationPreview(try capability(model, lane), package: packageID)?.totalBytes
            let progress = ProgressThrottle(connection: connection, re: id, model: model.id, lane: lane.id, total: total)
            let report = try await engine.materialize(package: packageID) { fraction, _ in
                progress.report(fraction)
            }
            let bytes = report.downloaded.isEmpty ? 0 : (total ?? 0)
            connection.send(["type": "materialize.done", "re": .string(id), "model": .string(model.id),
                             "lane": .string(lane.id), "bytes": .int(Int64(clamping: bytes)),
                             "seconds": .double(seconds(since: began))])
        } catch {
            reply(error: Self.translate(error, materializing: true), re: id)
        }
    }

    // MARK: - prepare

    private func startPrepare(_ m: [String: JSONValue], id: String) {
        Task { await self.prepare(m, id: id) }
    }

    private func prepare(_ m: [String: JSONValue], id: String) async {
        let began = Date()
        do {
            let (model, laneOpt) = try lookup(m)
            let lane = laneOpt!
            try await prepare(model, lane, re: id)
            connection.send(["type": "prepared", "re": .string(id), "model": .string(model.id),
                             "lane": .string(lane.id), "seconds": .double(seconds(since: began))])
            await sendMemory(re: nil)
        } catch {
            reply(error: Self.translate(error), re: id)
        }
    }

    /// Load a lane to resident. A download on the way is reported as `materialize.progress` under `re`.
    private func prepare(_ model: ModelDefinition, _ lane: LaneDefinition, re: String?) async throws {
        guard let engine, let context else { throw GPPError(.internal, "not configured") }
        switch model.backing {
        case .engine:
            let packageID = try await ensureRegistered(model, lane)
            let capability = try capability(model, lane)
            var relay: Task<Void, Never>?
            if let re, model.resolved(lane).materialization == .engine,
               await engine.needsDownload(capability, package: packageID) {
                let total = await engine.materializationPreview(capability, package: packageID)?.totalBytes
                let progress = ProgressThrottle(connection: connection, re: re, model: model.id, lane: lane.id,
                                                total: total)
                let events = engine.preparation.events()
                relay = Task {
                    for await event in events where event.packageID == packageID.description {
                        if case .downloading(let fraction, _) = event.phase { progress.report(fraction) }
                    }
                }
            }
            defer { relay?.cancel() }
            _ = try await engine.prepare(capability, package: packageID)
        case .custom(let make):
            var state = customs[model.id] ?? CustomState(instance: make(), preparedLane: nil, tenant: nil)
            if state.preparedLane == lane.id { return }
            if state.preparedLane != nil {
                await state.instance.unload()
                state.tenant?.withdraw()
                state.tenant = nil
                state.preparedLane = nil
            }
            customs[model.id] = state
            try await state.instance.prepare(lane: lane, context: context)
            let resolved = model.resolved(lane)
            state.tenant = await engine.registerExternalTenant(
                id: "gaea.model.\(model.id)", persistentBytes: resolved.persistentBytes,
                transientBytes: resolved.peakTransientBytes)
            state.preparedLane = lane.id
            customs[model.id] = state
        }
    }

    // MARK: - unload

    private func unload(_ m: [String: JSONValue], id: String) async {
        do {
            let (model, lane) = try lookup(m, laneRequired: false)
            if run?.model == model.id {
                throw GPPError(.busy, "\(model.id) is running; cancel the run first.", retryable: true)
            }
            switch model.backing {
            case .engine:
                if lane == nil || registeredLane[model.id] == lane?.id {
                    await engine?.evict(package: PackageID(model.id))
                }
            case .custom:
                if var state = customs[model.id], lane == nil || state.preparedLane == lane?.id {
                    await state.instance.unload()
                    state.tenant?.withdraw()
                    state.tenant = nil
                    state.preparedLane = nil
                    customs[model.id] = state
                }
            }
            connection.send(["type": "unloaded", "re": .string(id), "model": .string(model.id)])
            await sendMemory(re: nil)
        } catch {
            reply(error: Self.translate(error), re: id)
        }
    }

    // MARK: - run

    private func startRun(_ m: [String: JSONValue], id: String) {
        let jobID = m["job"]?.stringValue ?? ""
        if let run {
            return reply(error: GPPError(.busy, "Job \(run.job) is still running; one run at a time.", retryable: true),
                         re: id, job: jobID)
        }
        let job: Job
        let model: ModelDefinition
        let lane: LaneDefinition
        do {
            let found = try lookup(m)
            (model, lane) = (found.0, found.1!)
            job = try Self.job(from: m, id: id)
            guard definition.serves(job.operation, model: model.id) else {
                throw GPPError(.unsupportedOperation, "\(model.id) doesn't do \(job.operation).")
            }
            try FileManager.default.createDirectory(at: job.outputDir, withIntermediateDirectories: true)
        } catch {
            return reply(error: Self.translate(error), re: id, job: jobID)
        }
        guard let context else { return }
        let runContext = RunContext(worker: context, job: job, connection: connection)
        let task = Task {
            let began = Date()
            let outcome: Result<RunResult, any Error>
            do {
                outcome = .success(try await self.execute(job, model: model, lane: lane, context: runContext))
            } catch {
                outcome = .failure(error)
            }
            await self.finish(job, outcome: outcome, context: runContext, seconds: self.seconds(since: began))
        }
        run = ActiveRun(requestID: id, job: job.job, model: model.id, task: task)
    }

    /// Thrown before a run reaches the model: no memory report follows the error.
    private struct Refused: Error { let error: GPPError }

    private func execute(_ job: Job, model: ModelDefinition, lane: LaneDefinition,
                         context: RunContext) async throws -> RunResult {
        switch model.backing {
        case .engine(_, let operations):
            guard let engine else { throw GPPError(.internal, "not configured") }
            guard let operation = operations[job.operation] else {
                throw Refused(error: GPPError(.unsupportedOperation, "\(model.id) maps no engine call for \(job.operation)."))
            }
            let packageID: PackageID
            do {
                packageID = try await ensureRegistered(model, lane, forRun: job.requestID)
            } catch let error as GPPError {
                throw Refused(error: error)
            }
            if let sourcing = lane.configuration as? WeightSourcing,
               let missing = sourcing.missingWeightSources(storeRoot: context.worker.modelsRoot).first {
                throw Refused(error: GPPError(
                    .notMaterialized,
                    "Lane \(lane.id) of \(model.id) has no weights on disk; send materialize or prepare first.",
                    retryable: true,
                    detail: ["repo": .string(missing.repo), "revision": .string(missing.revision ?? "main")]))
            }
            let call: EngineCall
            do {
                call = try operation.request(job)
            } catch let error as GPPError {
                throw Refused(error: error)
            } catch {
                throw Refused(error: GPPError(.invalidRequest, "\(error)"))
            }
            let response = try await RunProgress.$sink.withValue({ report in
                let fraction = report.step.flatMap { step in
                    report.totalSteps.flatMap { $0 > 0 ? Double(step) / Double($0) : nil }
                }
                context.progress(report.phase.rawValue, step: report.step, of: report.totalSteps, fraction: fraction)
            }) {
                try await engine.run(call.request, package: packageID)
            }
            try Task.checkCancellation()
            let outputs = try SpooledResponse.outputs(
                CapabilityResponseEnvelope(capability: call.request.capability, response: response),
                outputDir: job.outputDir, names: operation.outputNames)
            return RunResult(outputs: outputs, effective: call.effective, warnings: call.warnings)
        case .custom:
            try await prepare(model, lane, re: nil)
            guard let state = customs[model.id] else { throw GPPError(.internal, "\(model.id) did not prepare") }
            return try await state.instance.run(job, context: context)
        }
    }

    private func finish(_ job: Job, outcome: Result<RunResult, any Error>, context: RunContext,
                        seconds: Double) async {
        run = nil
        switch outcome {
        case .success(let result) where !result.outputs.isEmpty:
            connection.send([
                "type": "result", "re": .string(job.requestID), "job": .string(job.job),
                "outputs": .array(result.outputs.map(\.json)),
                "effective": .object(result.effective),
                "warnings": .array(result.warnings.map { (try? JSONValue(encoding: $0)) ?? .null }),
                "seconds": .double(seconds),
            ])
        case .success:
            reply(error: GPPError(.modelError, "\(job.model) returned no outputs."), re: job.requestID, job: job.job)
        case .failure(let refused as Refused):
            return reply(error: refused.error, re: job.requestID, job: job.job)
        case .failure(let error):
            // A cancelled run may unwind with the package's own error rather than CancellationError.
            let translated = (error is CancellationError || Task.isCancelled)
                ? GPPError(.cancelled, context.cancelMessage)
                : Self.translate(error)
            reply(error: translated, re: job.requestID, job: job.job)
        }
        // After shutdown the run's end is the last line (GPP-1 §3.4).
        if !shuttingDown { await sendMemory(re: nil) }
    }

    private func cancel(job: String) {
        guard let run, run.job == job else { return }  // finished already, or never ran: nothing answers cancel
        run.task.cancel()
    }

    // MARK: - shutdown

    private func shutdown() async {
        guard !shuttingDown else { return }
        shuttingDown = true
        if let run {
            run.task.cancel()
            await run.task.value
        }
        onExit(0)
    }

    // MARK: - Replies

    private func sendMemory(re: String?) async {
        guard let engine else { return }
        let report = await engine.workerMemoryReport()
        var m: [String: JSONValue] = ["type": "memory"]
        if let re { m["re"] = .string(re) }
        m["report"] = (try? JSONValue(encoding: report)) ?? .null
        connection.send(m)
    }

    private func reply(error: GPPError, re: String?, job: String? = nil) {
        var m: [String: JSONValue] = ["type": "error", "code": .string(error.code.rawValue),
                                      "message": .string(error.message.isEmpty ? error.code.rawValue : error.message),
                                      "retryable": .bool(error.retryable)]
        if let re { m["re"] = .string(re) }
        if let job, !job.isEmpty { m["job"] = .string(job) }
        if let detail = error.detail { m["detail"] = .object(detail) }
        connection.send(m)
    }

    private func protocolError(_ message: String) {
        reply(error: GPPError(.protocol, message), re: nil)
    }

    private nonisolated func seconds(since date: Date) -> Double {
        (Date().timeIntervalSince(date) * 1000).rounded() / 1000
    }

    // MARK: - Translation

    static func job(from m: [String: JSONValue], id: String) throws -> Job {
        func paths(_ v: JSONValue) throws -> [URL] {
            let strings: [String]
            switch v {
            case .string(let s): strings = [s]
            case .array(let a): strings = a.compactMap(\.stringValue)
            default: strings = []
            }
            guard !strings.isEmpty, strings.allSatisfy({ $0.hasPrefix("/") }) else {
                throw GPPError(.invalidRequest, "Inputs are absolute paths or arrays of them.")
            }
            return strings.map { URL(fileURLWithPath: $0) }
        }
        guard let outputDir = m["output_dir"]?.stringValue, outputDir.hasPrefix("/") else {
            throw GPPError(.invalidRequest, "output_dir must be an absolute path.")
        }
        guard let params = m["params"]?.objectValue, let inputsObject = m["inputs"]?.objectValue else {
            throw GPPError(.invalidRequest, "run needs params and inputs objects.")
        }
        let modelParams = m["model_params"]?.objectValue ?? [:]
        if let bad = modelParams.keys.first(where: { !$0.hasPrefix("x-") }) {
            throw GPPError(.invalidRequest, "model_params carries only x- extension keys; got \(bad).")
        }
        var seed: UInt64?
        if let s = m["seed"] {
            guard let i = s.intValue, i >= 0 else { throw GPPError(.invalidRequest, "seed is a non-negative integer.") }
            seed = UInt64(i)
        }
        return Job(requestID: id, job: m["job"]?.stringValue ?? "", operation: m["operation"]?.stringValue ?? "",
                   model: m["model"]?.stringValue ?? "", lane: m["lane"]?.stringValue ?? "",
                   inputs: try inputsObject.mapValues(paths), params: params, modelParams: modelParams,
                   adapters: m["adapters"]?.arrayValue ?? [], seed: seed,
                   outputDir: URL(fileURLWithPath: outputDir, isDirectory: true))
    }

    /// Map an engine or package error onto a GPP error code (GPP-1 §3.5).
    static func translate(_ error: any Error, materializing: Bool = false) -> GPPError {
        if let e = error as? GPPError { return e }
        if let r = error as? Refused { return r.error }
        if error is CancellationError { return GPPError(.cancelled, "Cancelled.") }
        if let e = error as? EngineError {
            switch e {
            case .exceedsMemoryBudget, .workloadExceedsMemoryBudget, .externalTenantsHoldMemory:
                return GPPError(.outOfMemory, "\(e)")
            case .noPackage, .unknownPackage, .packageNotRegistered:
                return GPPError(.unknownModel, "\(e)")
            case .materializationUnavailable(_, let reason):
                return GPPError(.invalidRequest, reason)
            case .insufficientDisk(let required, let free):
                return GPPError(.materializeFailed, "The models volume has \(free) bytes free; this lane needs \(required).",
                                detail: ["required_bytes": .int(Int64(clamping: required)),
                                         "free_bytes": .int(Int64(clamping: free))])
            case .preemptionRetryExhausted:
                return GPPError(.outOfMemory, "\(e)", retryable: true)
            default:
                return GPPError(.modelError, "\(e)")
            }
        }
        if let e = error as? PackageError {
            switch e {
            case .unsupportedCapability: return GPPError(.unsupportedOperation, "\(e)")
            case .unsupportedRequestFeature(let what): return GPPError(.invalidRequest, what)
            default: return GPPError(.modelError, "\(e)")
            }
        }
        if let e = error as? WeightMaterializer.MaterializeError {
            var detail: [String: JSONValue] = [:]
            if case .source(let repo, let revision, let path, let url, _) = e {
                detail = ["repo": .string(repo), "revision": .string(revision), "url": .string(url.absoluteString)]
                if let path { detail["path"] = .string(path) }
            }
            return GPPError(.materializeFailed, e.errorDescription ?? "\(e)", retryable: true,
                            detail: detail.isEmpty ? nil : detail)
        }
        let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        return GPPError(materializing ? .materializeFailed : .modelError, message)
    }
}

/// `materialize.progress`, at most every 1% or half second, with byte counts when the total is known.
final class ProgressThrottle: @unchecked Sendable {
    private let connection: GPPConnection
    private let re: String, model: String, lane: String
    private let total: UInt64?
    private let lock = NSLock()
    private var last: (fraction: Double, at: Date)?

    init(connection: GPPConnection, re: String, model: String, lane: String, total: UInt64?) {
        self.connection = connection
        self.re = re
        self.model = model
        self.lane = lane
        self.total = total
    }

    func report(_ raw: Double) {
        let fraction = min(1, max(0, raw))
        lock.lock()
        if let last, fraction < 1, fraction - last.fraction < 0.01, Date().timeIntervalSince(last.at) < 0.5 {
            lock.unlock()
            return
        }
        last = (fraction, Date())
        lock.unlock()
        var m: [String: JSONValue] = ["type": "materialize.progress", "re": .string(re), "model": .string(model),
                                      "lane": .string(lane), "fraction": .double(fraction)]
        if let total {
            m["bytes_done"] = .int(Int64(clamping: UInt64((Double(total) * fraction).rounded())))
            m["bytes_total"] = .int(Int64(clamping: total))
        }
        connection.send(m)
    }
}
