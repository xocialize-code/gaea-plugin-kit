import Foundation
import GaeaPluginKit
import GaeaProtocol
import MLXHubMetadata
import MLXServeCore
import MLXToolKit

/// The Gaea spec repo (xocialize/gaea): its examples are the contract these tests replay, and its
/// validator checks every line the kit emits. `GAEA_SPEC_ROOT` overrides the sibling checkout.
enum Spec {
    static let root: URL = {
        if let env = ProcessInfo.processInfo.environment["GAEA_SPEC_ROOT"] {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "gaea-mes-media-server", directoryHint: .isDirectory)
    }()

    static func manifest(_ name: String) -> URL { root.appending(path: "examples/v1/manifest/\(name)") }
    static func transcript(_ name: String) -> URL { root.appending(path: "examples/v1/gpp/\(name)") }

    /// Run tools/validate.py; returns (exit status, output).
    static func validate(_ arguments: [String]) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", root.appending(path: "tools/validate.py").path] + arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

// MARK: - The demo: the plugin-exec spike's matmul worker, as a custom model

struct Bundled: PackageConfiguration, BundledWeightSourcing {
    var bundledWeightSources: [BundledWeightSource] { [] }
}

/// The demo's package manifest, as tools/manifest-gen declares it.
let demoPackageManifest = PackageManifest(
    license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .apache2),
    provenance: Provenance(sourceRepo: "xocialize/gaea-plugin-demo", revision: "0.2.0", tier: 1),
    requirements: RequirementsManifest(
        footprints: [QuantFootprint(quant: .fp32, residentBytes: 0, peakActivationBytes: 2_370_000_000)],
        requiredBackends: [.metalGPU]),
    surfaces: [])

/// A matmul loop with no MLX in it: step `k` of a long run (more than 100 iterations) waits until it
/// is cancelled, so a replayed cancel always lands on step 2.
final class FakeMatmul: PluginModel, @unchecked Sendable {
    func prepare(lane: LaneDefinition, context: WorkerContext) async throws {}
    func unload() async {}

    func run(_ job: Job, context: RunContext) async throws -> RunResult {
        let n = job.param("n")?.intValue ?? 4096
        let iterations = job.param("iterations")?.intValue ?? 10
        for step in 1...iterations {
            try context.checkCancellation()
            if iterations > 100, step > 1 { try await Task.sleep(for: .seconds(60)) }
            context.progress("matmul", step: step, of: iterations)
        }
        return RunResult(outputs: [.value("checksum", ["device": "fake", "checksum": 0.0])],
                         effective: ["n": .int(Int64(n)), "iterations": .int(Int64(iterations))])
    }
}

let demoHelper = PluginManifest.Helper(
    operation: "x-gaea.demo.matmul", model: "demo-matmul", title: "Matmul smoke test",
    summary: "n×n fp32 matmul, repeated; holds holdBytes to exercise the memory ledger.",
    params: [
        "type": "object",
        "properties": [
            "n": ["type": "integer", "minimum": 16, "maximum": 16384, "default": 4096],
            "iterations": ["type": "integer", "minimum": 1, "maximum": 1000, "default": 10],
            "holdBytes": ["type": "integer", "minimum": 0, "default": 0],
        ],
        "additionalProperties": false,
    ])

/// examples/v1/manifest/demo.json, declared in code. `declaresEngine: false` because that manifest
/// predates the kit (the spike's worker linked MLX only).
func demoDefinition(onConfigure: (@Sendable (WorkerContext, Bool) async throws -> Void)? = nil) -> GaeaPluginDefinition {
    GaeaPluginDefinition(
        id: "com.xocialize.gaea.demo", version: "0.2.0", team: "CFZS6RXUCP",
        repo: "https://github.com/xocialize/gaea-plugin-demo", title: "Gaea demo worker",
        summary: "A GPU matmul loop that proves the plugin path end to end: download, verify, launch, run, cancel.",
        license: "Apache-2.0", executable: "gaea-demo-worker", declaresEngine: false,
        models: [.custom(id: "demo-matmul", title: "Demo matmul (GPU smoke test)", manifest: demoPackageManifest,
                         lanes: [LaneDefinition(id: "fp32", default: true, configuration: Bundled())],
                         make: { FakeMatmul() })],
        helpers: [demoHelper], onConfigure: onConfigure)
}

// MARK: - Z-Image Turbo: an engine package with no MLX in it

/// One lane per quant, every lane fetching the one bf16 snapshot (z-image-swift 0.5.3). Weights count
/// as present once the fake materializer has written its marker.
struct FakeZImageConfiguration: PackageConfiguration, QuantConfigured, WeightSourcing {
    var quant: Quant
    var weightSources: [WeightSource] {
        [WeightSource(role: "snapshot", repo: "mlx-community/Z-Image-Turbo-bf16", revision: "main",
                      matching: ["transformer/*", "text_encoder/*", "vae/*", "tokenizer/*", "scheduler/*", "*.json"])]
    }

    func missingWeightSources(storeRoot: URL?) -> [WeightSource] {
        guard let storeRoot else { return weightSources }
        return weightSources.filter { !FileManager.default.fileExists(atPath: FakeMaterializer.marker($0, storeRoot).path) }
    }
}

@InferenceActor
final class FakeZImagePackage: ModelPackage {
    typealias Configuration = FakeZImageConfiguration

    nonisolated static var manifest: PackageManifest {
        PackageManifest(
            license: LicenseDeclaration(weightLicense: .apache2, portCodeLicense: .mit),
            provenance: Provenance(sourceRepo: "Tongyi-MAI/Z-Image-Turbo", revision: "main", tier: 1),
            requirements: RequirementsManifest(
                footprints: [
                    QuantFootprint(quant: .bf16, residentBytes: 20_500_000_000, peakActivationBytes: 28_000_000_000),
                    QuantFootprint(quant: .int8, residentBytes: 15_000_000_000, peakActivationBytes: 28_000_000_000),
                    QuantFootprint(quant: .int4, residentBytes: 11_900_000_000, peakActivationBytes: 28_000_000_000),
                ],
                requiredBackends: [.metalGPU],
                os: OSRequirement(minMacOS: SemanticVersion(major: 26, minor: 0, patch: 0)),
                chipFloor: nil),
            specialties: [],
            surfaces: [
                T2IContract.descriptor(name: "z-image-turbo-t2i",
                                       summary: "Z-Image-Turbo 6B text-to-image: distilled 8-step at guidance 0.",
                                       modes: []),
                IEditContract.descriptor(name: "z-image-turbo-img2img",
                                         summary: "Z-Image-Turbo image-to-image; metaData[\"strength\"] 0–1.",
                                         modes: []),
            ])
    }

    private var loaded = false
    nonisolated init(configuration: FakeZImageConfiguration) {}
    func load() async throws { loaded = true }
    func unload() async { loaded = false }

    func run(_ request: any CapabilityRequest) async throws -> any CapabilityResponse {
        guard loaded else { throw PackageError.notLoaded }
        guard let t2i = request as? T2IRequest else { throw PackageError.unsupportedCapability(request.capability) }
        RunProgress.report("encode_prompt")
        let steps = t2i.steps ?? 8
        for step in [steps / 2, steps] {
            try Task.checkCancellation()
            RunProgress.report(.denoise, step: step, totalSteps: steps)
        }
        RunProgress.report(.decode)
        return T2IResponse(image: Image(format: .png, data: tinyPNG, width: 1, height: 1))
    }
}

/// A 1×1 PNG.
let tinyPNG = Data(base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

/// Reports 0 and 50% and writes a marker per source; no network.
struct FakeMaterializer: WeightMaterializing {
    static func marker(_ source: WeightSource, _ root: URL) -> URL {
        root.appending(path: ModelStore.repoFolderName(for: source.repo)).appending(path: ".fake-complete")
    }

    func materialize(_ sources: [WeightSource], into root: URL) async throws {
        WeightDownloadProgress.report(fraction: 0.0)
        WeightDownloadProgress.report(fraction: 0.5)
        for source in sources {
            let marker = Self.marker(source, root)
            try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: marker)
        }
    }
}

/// The snapshot's size, so materialize can report bytes.
struct FakeHub: HubMetadataProviding {
    func files(repo: String, revision: String?) async throws -> [HubFileEntry] {
        [HubFileEntry(path: "transformer/diffusion_pytorch_model.safetensors", size: 20_612_345_678)]
    }
}

let fakeEngineFactory: GPPWorker.EngineFactory = { budget in
    MLXServeEngine(workerBudget: budget, hubMetadata: FakeHub(), materializer: FakeMaterializer(),
                   diskPrecheckEnabled: false)
}

let apache: JSONValue = ["spdx": "Apache-2.0", "commercial_use": true,
                         "terms_url": "https://www.apache.org/licenses/LICENSE-2.0"]

/// The image.generate mapping a Z-Image plugin would declare.
let zImageGenerate = EngineOperation("image.generate", outputNames: ["image": "images"]) { job in
    let width = job.param("width")?.intValue ?? 1024
    let height = job.param("height")?.intValue ?? 1024
    let steps = job.param("steps")?.intValue ?? 8
    let shift = job.param("x-zimage.shift")?.doubleValue ?? 3
    var warnings: [Warning] = []
    if job.param("negative_prompt") != nil {
        warnings.append(Warning(code: "negative_prompt_ignored",
                                message: "Z-Image Turbo runs without CFG; the negative prompt had no effect.",
                                param: "negative_prompt"))
    }
    let request = T2IRequest(prompt: job.param("prompt")?.stringValue ?? "", width: width, height: height,
                             steps: steps, guidanceScale: 0, seed: job.seed, metaData: ["shift": .double(shift)])
    return EngineCall(request, effective: ["width": .int(Int64(width)), "height": .int(Int64(height)),
                                           "steps": .int(Int64(steps)), "guidance_scale": 0.0,
                                           "x-zimage.shift": .double(shift)],
                      warnings: warnings)
}

/// examples/v1/manifest/z-image.json, declared in code.
func zImageDefinition(onConfigure: (@Sendable (WorkerContext, Bool) async throws -> Void)? = nil) -> GaeaPluginDefinition {
    GaeaPluginDefinition(
        id: "com.xocialize.gaea.z-image", version: "0.1.0", team: "CFZS6RXUCP",
        repo: "https://github.com/xocialize/gaea-plugin-z-image", title: "Z-Image",
        summary: "Tongyi-MAI's Z-Image Turbo: fast photoreal text-to-image and image-to-image.",
        license: "MIT", executable: "gaea-z-image-worker",
        models: [.engine(FakeZImagePackage.self, id: "z-image-turbo", title: "Z-Image Turbo",
                         lanes: [LaneDefinition(id: "int4", default: true, configuration: FakeZImageConfiguration(quant: .int4)),
                                 LaneDefinition(id: "int8", configuration: FakeZImageConfiguration(quant: .int8)),
                                 LaneDefinition(id: "bf16", configuration: FakeZImageConfiguration(quant: .bf16))],
                         operations: [zImageGenerate])],
        offers: [
            PluginManifest.Offer(
                operation: "image.generate", profile: "image",
                model: ["id": "z-image-turbo", "title": "Z-Image Turbo", "license": apache, "memory_class": "large",
                        "speed_class": "fast", "quality_tiers": ["draft", "standard"], "default": true,
                        "notes": "Distilled 8-step, no CFG: negative prompts do nothing. Low seed variance is a model trait."],
                params: ["type": "object",
                         "properties": ["x-zimage.shift": [
                             "type": "number", "minimum": 1, "maximum": 6, "default": 3,
                             "description": "Flow-matching shift; higher favours composition over detail.",
                             "x-mes-ui": ["widget": "slider", "label": "Shift", "advanced": true]]],
                         "additionalProperties": false],
                defaults: ["steps": 8],
                limits: .init(maxPixels: 2_359_296, minSide: 256, maxSide: 1536, sizeMultiple: 16)),
            PluginManifest.Offer(
                operation: "image.edit", profile: "image",
                model: ["id": "z-image-turbo", "title": "Z-Image Turbo (image to image)", "license": apache,
                        "memory_class": "large", "speed_class": "fast", "quality_tiers": ["draft"], "named_only": true,
                        "notes": "Re-generates from the input image; strength 0–1 (default 0.75). Not an instruction editor."],
                limits: .init(maxPixels: 2_359_296, sizeMultiple: 16, maxImages: 1)),
        ],
        settings: [PluginManifest.Setting(
            key: "default_lane", title: "Default precision",
            description: "Which lane Gaea loads when memory allows more than one.",
            schema: ["type": "string", "enum": ["int4", "int8", "bf16"], "default": "int4"], apply: .reloadModels)],
        storage: PluginManifest.Storage(schemaVersion: 1, migrations: ["0001_presets"]),
        onConfigure: onConfigure)
}
