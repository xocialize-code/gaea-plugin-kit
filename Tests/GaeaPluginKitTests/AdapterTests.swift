import CryptoKit
import Foundation
import GaeaPluginKit
import GaeaProtocol
import MLXHubMetadata
import MLXServeCore
import MLXToolKit
import Testing

// Adapters (GPP-1 §3.3, §4.3, §4.8; AB-T-0381): a package that declares AdapterSupport, a registry it ships, and the
// worker registering, fetching and applying what a run names.

/// What a fake adapter file holds: its path, so every file has its own digest.
func fakeAdapterBytes(_ path: String) -> Data { Data("lora:\(path)".utf8) }
func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

let fakeRevision = String(repeating: "a1", count: 20)

/// Writes `fakeAdapterBytes(path)` for an adapter file; snapshots as FakeMaterializer does.
struct FakeAdapterMaterializer: WeightMaterializing {
    func materialize(_ sources: [WeightSource], into root: URL) async throws {
        try await FakeMaterializer().materialize(sources, into: root)
    }

    func materializeFile(repo: String, revision: String, path: String, to destination: URL) async throws {
        WeightDownloadProgress.report(fraction: 0.5)
        try fakeAdapterBytes(path).write(to: destination)
    }
}

let adapterEngineFactory: GPPWorker.EngineFactory = { budget in
    MLXServeEngine(workerBudget: budget, hubMetadata: FakeHub(), materializer: FakeAdapterMaterializer(),
                   diskPrecheckEnabled: false)
}

/// The adapters each run handed the package, newest last.
final class SeenAdapters: @unchecked Sendable {
    static let shared = SeenAdapters()
    private let lock = NSLock()
    private var runs: [[ResolvedAdapter]] = []
    func record(_ adapters: [ResolvedAdapter]) { lock.lock(); runs.append(adapters); lock.unlock() }
    var last: [ResolvedAdapter]? { lock.lock(); defer { lock.unlock() }; return runs.last }
}

func fakeSupport(_ capability: Capability) -> AdapterSupport {
    AdapterSupport(baseModel: "fake-base", formats: [.diffusersPEFT, .kohya],
                   kinds: capability == .imageEdit ? [.plain, .referenceConditioned] : [.plain], maxCount: 2,
                   strengthRange: AdapterStrengthRange(min: 0, max: 2))
}

@InferenceActor
final class FakeLoRAPackage: ModelPackage {
    typealias Configuration = FakeZImageConfiguration

    nonisolated static var manifest: PackageManifest {
        PackageManifest(
            license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .mit),
            provenance: Provenance(sourceRepo: "xocialize/fake-lora-model", revision: "main", tier: 1),
            requirements: RequirementsManifest(
                footprints: [QuantFootprint(quant: .int8, residentBytes: 1_000_000_000, peakActivationBytes: 1_000_000_000)],
                requiredBackends: [.metalGPU]),
            surfaces: [
                T2IContract.descriptor(name: "fake-t2i", summary: "Takes adapters.", modes: [])
                    .declaring(adapters: fakeSupport(.textToImage)),
                IEditContract.descriptor(name: "fake-edit", summary: "Takes plain and ic adapters.", modes: [])
                    .declaring(adapters: fakeSupport(.imageEdit)),
            ])
    }

    nonisolated init(configuration: FakeZImageConfiguration) {}
    func load() async throws {}
    func unload() async {}

    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        SeenAdapters.shared.record((request as? any AdapterCarrying)?.resolvedAdapters ?? [])
        let image = Image(format: .png, data: tinyPNG, width: 1, height: 1)
        if request is IEditRequest { return IEditResponse(image: image) }
        return T2IResponse(image: image)
    }
}

/// A registry in format 3: a plain adapter with a trigger (candidate, NOASSERTION), an ic one with two ordered slots,
/// and an ic one with no footprint, which the engine would refuse and the decoder skips.
func fakeRegistry() -> Data {
    func source(_ file: String) -> String {
        #"{"host":"huggingface","repo":"xocialize/fake-loras","revision":"\#(fakeRevision)","file":"\#(file)","sha256":"\#(sha256(fakeAdapterBytes(file)))","bytes":\#(fakeAdapterBytes(file).count),"gated":false}"#
    }
    return Data(#"""
    {"format":"adapter-registry","schemaVersion":3,"namespace":"fake","title":"Fake","adapters":[
     {"id":"style","title":"Style","kind":"plain","format":"diffusers-peft","baseModels":["fake-base"],"capabilities":["textToImage"],
      "source":\#(source("loras/style.safetensors")),"license":"NOASSERTION","licenseTerms":{"commercialUse":"unknown","gated":false},
      "defaultStrength":1.0,"status":"candidate","trigger":"stylish",
      "clearance":{"fake-base":{"level":"declared","note":"Trained on the base; not yet judged on our stack."}}},
     {"id":"pose","title":"Pose","kind":"ic","format":"diffusers-peft","baseModels":["fake-base"],"capabilities":["imageEdit"],
      "source":\#(source("pose.safetensors")),"license":"Apache-2.0","licenseTerms":{"commercialUse":"allowed","gated":false},
      "defaultStrength":1.0,"strengthRange":{"min":0.5,"max":1.5},"status":"verified","promptTemplate":"apply pose from image 1",
      "conditioning":[{"role":"pose","media":"image","note":"The skeleton."},{"role":"reference","media":"image"}],
      "footprint":{"residentBytes":10,"activationMultiplier":1.02},"clearance":{"fake-base":{"level":"mechanical"}}},
     {"id":"broken","kind":"ic","format":"diffusers-peft","baseModels":["fake-base"],"capabilities":["imageEdit"],
      "source":\#(source("broken.safetensors")),"license":"Apache-2.0","licenseTerms":{"commercialUse":"allowed"},
      "status":"verified","conditioning":[{"role":"pose","media":"image"}]}
    ]}
    """#.utf8)
}

let fakeGenerate = EngineOperation("image.generate", outputNames: ["image": "images"]) { job in
    EngineCall(T2IRequest(prompt: try job.text("prompt") ?? "", width: 64, height: 64, steps: 1, seed: job.seed,
                          adapters: try job.adapterRefs()))
}
let fakeEdit = EngineOperation("image.edit", outputNames: ["image": "image"]) { job in
    EngineCall(IEditRequest(images: try (job.inputs["images"] ?? []).indices.map { try job.image("images", index: $0) },
                            prompt: try job.text("instruction") ?? "", seed: job.seed, adapters: try job.adapterRefs()))
}
/// An operation that forgets the adapters: the worker refuses rather than run without them.
let forgetfulGenerate = EngineOperation("image.generate") { job in
    EngineCall(T2IRequest(prompt: "x", width: 64, height: 64, seed: job.seed))
}

func loraDefinition(generate: EngineOperation = fakeGenerate) throws -> GaeaPluginDefinition {
    let shipped = try AdapterRegistry.decode(fakeRegistry())
    let model: JSONValue = ["id": "fake-lora", "title": "Fake LoRA model", "license": apache, "memory_class": "small",
                            "speed_class": "fast", "quality_tiers": ["draft"]]
    return GaeaPluginDefinition(
        id: "com.xocialize.gaea.fake-lora", version: "0.1.0", team: "CFZS6RXUCP",
        repo: "https://github.com/xocialize-code/gaea-plugin-fake-lora", title: "Fake LoRA",
        license: "Apache-2.0", executable: "gaea-fake-lora-worker",
        models: [ModelDefinition.engine(FakeLoRAPackage.self, id: "fake-lora", title: "Fake LoRA model",
                                        lanes: [LaneDefinition(id: "int8", default: true,
                                                               configuration: FakeZImageConfiguration(quant: .int8))],
                                        operations: [generate, fakeEdit]).shipping(shipped.adapters)],
        offers: [
            PluginManifest.Offer(operation: "image.generate", profile: "image", model: model),
            PluginManifest.Offer(operation: "image.edit", profile: "image", model: model,
                                 limits: .init(maxImages: 2)),
        ])
}

@Suite("adapters", .serialized)
struct AdapterTests {
    @Test func registryDecodesLikeTheRuntimeCatalog() throws {
        let (adapters, skipped) = try AdapterRegistry.decode(fakeRegistry())
        #expect(adapters.map(\.id) == ["fake:style", "fake:pose"])
        #expect(skipped.map(\.id) == ["fake:broken"])
        #expect(skipped.first?.reason.contains("footprint") == true)
        let pose = try #require(adapters.last)
        #expect(pose.descriptor.conditioning.map(\.role) == ["pose", "reference"])
        #expect(pose.descriptor.source.revision == fakeRevision)
    }

    @Test func manifestOffersShippedAdaptersAndSupport() throws {
        let manifest = try loraDefinition().manifest()
        let generate = try #require(manifest.offers.first { $0.operation == "image.generate" })
        let edit = try #require(manifest.offers.first { $0.operation == "image.edit" })
        #expect(generate.adapterSupport == PluginManifest.AdapterSupport(
            baseModel: "fake-base", formats: ["diffusers-peft", "kohya"], kinds: ["plain"], maxCount: 2,
            strength: .init(min: 0, max: 2)))
        #expect(edit.adapterSupport?.kinds == ["plain", "ic"])
        // The plain t2i adapter on generate only, the ic edit adapter on edit only.
        #expect(generate.model["adapters"]?.arrayValue?.compactMap { $0["id"]?.stringValue } == ["fake:style"])
        #expect(edit.model["adapters"]?.arrayValue?.compactMap { $0["id"]?.stringValue } == ["fake:pose"])
        let style = try #require(generate.model["adapters"]?.arrayValue?.first)
        #expect(style["license"]?["spdx"] == "NOASSERTION")
        #expect(style["license"]?["commercial_use"] == "unknown")
        #expect(style["strength"] == ["min": 0.0, "max": 2.0, "default": 1.0])
        #expect(style["notes"] == "Trained on the base; not yet judged on our stack.")
        let meta = try #require(generate.adapterMetas["fake:style"])
        #expect(meta.status == "candidate" && meta.trigger == "stylish" && meta.format == "diffusers-peft")
        #expect(meta.source.revision == fakeRevision && meta.clearance == ["fake-base": "declared"])
        let pose = try #require(edit.model["adapters"]?.arrayValue?.first)
        #expect(pose["strength"] == ["min": 0.5, "max": 1.5, "default": 1.0])
        #expect(pose["slots"]?.arrayValue?.compactMap { $0["role"]?.stringValue } == ["pose", "reference"])
        #expect(edit.adapterMetas["fake:pose"]?.promptTemplate == "apply pose from image 1")

        let file = FileManager.default.temporaryDirectory.appending(path: "gaea-\(UUID().uuidString)-fake-lora.json")
        try manifest.encoded().write(to: file)
        let (status, output) = try Spec.validate(["--manifest", file.path])
        #expect(status == 0, "\(output)")
    }

    @Test func aModelWithoutAdapterSupportOffersNone() throws {
        let manifest = try zImageDefinition().manifest()
        #expect(manifest.offers.allSatisfy { $0.adapterSupport == nil && $0.adaptersMeta == nil })
    }

    @Test func anAdapterNoOfferAdmitsIsADefinitionError() throws {
        var definition = try loraDefinition()
        definition.offers.removeLast()   // no image.edit offer: fake:pose fits nothing
        #expect(throws: GPPError.self) { try definition.manifest() }
    }

    /// A worker over the fake package, its lines, and a run helper.
    struct Session {
        let worker: GPPWorker
        let lines = LineQueue()
        let tmp = FileManager.default.temporaryDirectory.appending(path: "gaea-adapters-\(UUID().uuidString)").path
        var n = 0

        init(_ definition: GaeaPluginDefinition) throws {
            let lines = self.lines
            worker = GPPWorker(definition: definition, manifest: try definition.manifest().encoded(),
                               connection: GPPConnection { lines.push(String(decoding: $0.dropLast(), as: UTF8.self)) },
                               engineFactory: adapterEngineFactory, onExit: { _ in })
        }

        func next() async throws -> JSONValue { try Replay.parse(try #require(await lines.pop(timeout: .seconds(10)))) }

        func start() async throws {
            await worker.sendHello()
            _ = try await next()
            await worker.handle(line: #"{"type":"configure","id":"c","budget":{"ceilingBytes":8000000000,"wiresWeights":false},"models_root":"\#(tmp)/models","cache_root":"\#(tmp)/cache","settings":{}}"#)
            #expect(try await next()["type"] == "configured")
            await worker.handle(line: #"{"type":"materialize","id":"m","model":"fake-lora","lane":"int8"}"#)
            while try await next()["type"] != "materialize.done" {}
        }

        /// Run and return its `result` or `error`, skipping progress and memory.
        mutating func run(_ operation: String, inputs: String = "{}", adapters: String) async throws -> JSONValue {
            n += 1
            let text = URL(fileURLWithPath: "\(tmp)/prompt-\(n).txt")
            try Data("a fox".utf8).write(to: text)
            let input = operation == "image.generate" ? #""prompt":"\#(text.path)""# : #""instruction":"\#(text.path)""#
            let merged = inputs == "{}" ? "{\(input)}" : "{\(input)," + inputs.dropFirst()
            await worker.handle(line: #"{"type":"run","id":"r\#(n)","job":"job_\#(n)","operation":"\#(operation)","model":"fake-lora","lane":"int8","inputs":\#(merged),"params":{},"adapters":\#(adapters),"seed":7,"output_dir":"\#(tmp)/out-\#(n)"}"#)
            while true {
                let m = try await next()
                if ["result", "error"].contains(m["type"]?.stringValue) { return m }
            }
        }
    }

    static func item(_ id: String, file: String, strength: Double, kind: String = "plain", inputs: String? = nil,
                     sha: String? = nil, revision: String = fakeRevision) -> String {
        let source = #"{"repo":"xocialize/fake-loras","revision":"\#(revision)","file":"\#(file)","sha256":"\#(sha ?? sha256(fakeAdapterBytes(file)))"}"#
        return #"{"id":"\#(id)","strength":\#(strength),"kind":"\#(kind)","format":"diffusers-peft","source":\#(source)"#
            + (inputs.map { #","inputs":\#($0)"# } ?? "") + "}"
    }

    @Test func aRunAppliesShippedAndRegisteredAdapters() async throws {
        var session = try Session(try loraDefinition())
        try await session.start()
        let adapters = "[" + Self.item("fake:style", file: "loras/style.safetensors", strength: 0.8) + ","
            + Self.item("operator:mine", file: "mine.safetensors", strength: 1.25) + "]"
        let result = try await session.run("image.generate", adapters: adapters)
        #expect(result["type"] == "result", "\(result)")
        let seen = try #require(SeenAdapters.shared.last)
        #expect(seen.map(\.id) == ["fake:style", "operator:mine"])
        #expect(seen.map(\.strength) == [0.8, 1.25])
        // Fetched into the models root by digest, and checked.
        let digest = sha256(fakeAdapterBytes("mine.safetensors"))
        #expect(seen[1].fileURL.path.hasSuffix("/models/adapters/\(digest)/mine.safetensors"))
        #expect(try Data(contentsOf: seen[1].fileURL) == fakeAdapterBytes("mine.safetensors"))
        // The operator's adapter registered under the surface's base model, for NOASSERTION.
        #expect(seen[1].source.repo == "xocialize/fake-loras")
    }

    @Test func anICAdapterTakesItsImagesInSlotOrder() async throws {
        var session = try Session(try loraDefinition())
        try await session.start()
        let png = URL(fileURLWithPath: "\(session.tmp)/ref.png")
        try FileManager.default.createDirectory(atPath: session.tmp, withIntermediateDirectories: true)
        try tinyPNG.write(to: png)
        // Roles arrive in any order; the engine puts them in the descriptor's.
        let inputs = #"{"reference":"\#(png.path)","pose":["\#(png.path)"]}"#
        let result = try await session.run("image.edit", adapters: "[" + Self.item(
            "fake:pose", file: "pose.safetensors", strength: 1.0, kind: "ic", inputs: inputs) + "]")
        #expect(result["type"] == "result", "\(result)")
        let seen = try #require(SeenAdapters.shared.last?.first)
        #expect(seen.id == "fake:pose" && seen.kind == .referenceConditioned)
        #expect(seen.conditioning.map(\.role) == ["pose", "reference"])
    }

    @Test func refusals() async throws {
        var session = try Session(try loraDefinition())
        try await session.start()
        try FileManager.default.createDirectory(atPath: session.tmp, withIntermediateDirectories: true)
        let png = "\(session.tmp)/x.png"
        try tinyPNG.write(to: URL(fileURLWithPath: png))
        func refused(_ operation: String, _ adapters: String, _ code: String, _ words: String,
                     inputs: String = "{}") async throws {
            let m = try await session.run(operation, inputs: inputs, adapters: adapters)
            #expect(m["type"] == "error" && m["code"]?.stringValue == code, "\(m)")
            #expect(m["message"]?.stringValue?.contains(words) == true, "\(m)")
        }
        // An ic adapter the plugin doesn't ship: GPP carries no slots or footprint.
        try await refused("image.edit", "[" + Self.item("operator:ic", file: "ic.safetensors", strength: 1, kind: "ic",
                                                        inputs: #"{"pose":"/tmp/x.png"}"#) + "]",
                          "invalid_request", "doesn't ship")
        // A shipped adapter under another pin.
        try await refused("image.generate", "[" + Self.item("fake:style", file: "loras/style.safetensors", strength: 1,
                                                            revision: String(repeating: "b2", count: 20)) + "]",
                          "invalid_request", "pinned to")
        // A branch name for a revision.
        try await refused("image.generate", "[" + Self.item("operator:x", file: "x.safetensors", strength: 1,
                                                            revision: "main") + "]", "invalid_request", "isn't pinned")
        // The package's own pre-flight: a strength outside the adapter's range, an edit adapter on generate.
        try await refused("image.edit", "[" + Self.item("fake:pose", file: "pose.safetensors", strength: 1.9, kind: "ic",
                                                        inputs: #"{"pose":"\#(png)","reference":"\#(png)"}"#) + "]",
                          "invalid_request", "outside")
        try await refused("image.generate", "[" + Self.item("fake:pose", file: "pose.safetensors", strength: 1, kind: "ic",
                                                            inputs: #"{"pose":"\#(png)","reference":"\#(png)"}"#) + "]",
                          "invalid_request", "applies to imageEdit")
        // A conditioning image that isn't there.
        try await refused("image.edit", "[" + Self.item("fake:pose", file: "pose.safetensors", strength: 1, kind: "ic",
                                                        inputs: #"{"pose":"/nonexistent/p.png","reference":"\#(png)"}"#) + "]",
                          "invalid_request", "isn't a readable file")
        // A file whose bytes aren't the pinned digest.
        try await refused("image.generate", "[" + Self.item("operator:bad", file: "bad.safetensors", strength: 1,
                                                            sha: String(repeating: "0", count: 64)) + "]",
                          "materialize_failed", "sha256")
        // An unknown field.
        try await refused("image.generate", #"[{"id":"x","format":"kohya","source":{},"lora_url":"http://x"}]"#,
                          "invalid_request", "unknown field")
    }

    @Test func anOperationThatDropsTheAdaptersIsRefused() async throws {
        var session = try Session(try loraDefinition(generate: forgetfulGenerate))
        try await session.start()
        let m = try await session.run("image.generate", adapters: "[" + Self.item(
            "fake:style", file: "loras/style.safetensors", strength: 1) + "]")
        #expect(m["code"] == "internal" && m["message"]?.stringValue?.contains("adapterRefs") == true, "\(m)")
    }

    @Test func aModelWithoutAdapterSupportRefusesAdapters() async throws {
        let lines = LineQueue()
        let worker = GPPWorker(definition: zImageDefinition(), manifest: try zImageDefinition().manifest().encoded(),
                               connection: GPPConnection { lines.push(String(decoding: $0.dropLast(), as: UTF8.self)) },
                               engineFactory: adapterEngineFactory, onExit: { _ in })
        let tmp = FileManager.default.temporaryDirectory.appending(path: "gaea-noadapters-\(UUID().uuidString)").path
        await worker.sendHello()
        _ = await lines.pop(timeout: .seconds(10))
        await worker.handle(line: #"{"type":"configure","id":"c","budget":{"ceilingBytes":30000000000,"wiresWeights":false},"models_root":"\#(tmp)/models","cache_root":"\#(tmp)/cache","settings":{}}"#)
        _ = await lines.pop(timeout: .seconds(10))
        await worker.handle(line: #"{"type":"materialize","id":"m","model":"z-image-turbo","lane":"int4"}"#)
        while try Replay.parse(try #require(await lines.pop(timeout: .seconds(10))))["type"] != "materialize.done" {}
        await worker.handle(line: #"{"type":"run","id":"r","job":"j","operation":"image.generate","model":"z-image-turbo","lane":"int4","inputs":{},"params":{},"adapters":[\#(Self.item("operator:x", file: "x.safetensors", strength: 1))],"output_dir":"\#(tmp)/out"}"#)
        var m = try Replay.parse(try #require(await lines.pop(timeout: .seconds(10))))
        while m["type"] == "progress" { m = try Replay.parse(try #require(await lines.pop(timeout: .seconds(10)))) }
        #expect(m["type"] == "error" && m["code"] == "invalid_request", "\(m)")
        #expect(m["message"]?.stringValue?.contains("takes no adapters") == true, "\(m)")
    }
}
