import Foundation
import MLXToolKit

/// `Contents/Resources/manifest.json` of a `.gaeaplugin` bundle (GPP-1 §4, schemas/v1/manifest.schema.json).
///
/// Gaea's keys are snake_case like MES. The engine-owned objects (`PackageManifest`, `ResolvedLane`)
/// are MLXToolKit's own types, encoded by MLXToolKit, so they keep the engine's camelCase and can't
/// drift from the engine the worker links.
public struct PluginManifest: Codable, Sendable {
    public var manifestVersion: Int
    public var id: String
    public var version: String
    public var `protocol`: Int
    public var minGaea: String
    public var team: String
    public var repo: String
    public var title: String
    public var summary: String?
    public var license: String
    public var executable: String
    public var engine: EngineRef?
    public var models: [Model]
    public var offers: [Offer]
    public var helpers: [Helper]?
    public var settings: [Setting]?
    public var storage: Storage?

    enum CodingKeys: String, CodingKey {
        case manifestVersion = "manifest_version", id, version, `protocol`, minGaea = "min_gaea", team, repo,
             title, summary, license, executable, engine, models, offers, helpers, settings, storage
    }

    public init(id: String, version: String, minGaea: String, team: String, repo: String, title: String,
                summary: String?, license: String, executable: String, engine: EngineRef?, models: [Model],
                offers: [Offer], helpers: [Helper]?, settings: [Setting]?, storage: Storage?) {
        self.manifestVersion = 1
        self.protocol = 1
        self.id = id
        self.version = version
        self.minGaea = minGaea
        self.team = team
        self.repo = repo
        self.title = title
        self.summary = summary
        self.license = license
        self.executable = executable
        self.engine = engine
        self.models = models
        self.offers = offers
        self.helpers = helpers
        self.settings = settings
        self.storage = storage
    }

    /// The bytes written to `manifest.json`: sorted keys, pretty-printed, unescaped slashes, and a
    /// final newline. The bundle's signature seals them and `hello.manifest_sha256` is their digest.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    /// The MLXEngine build a worker links (§4.1).
    public struct EngineRef: Codable, Sendable, Equatable {
        public var package: String
        public var version: String
        public var contract: String

        public init(package: String = "mlx-engine-swift", version: String, contract: String) {
            self.package = package
            self.version = version
            self.contract = contract
        }
    }

    /// One MLXEngine package and the lanes it can run in (§4.2).
    public struct Model: Codable, Sendable {
        public var id: String
        public var title: String
        public var package: PackageManifest
        public var lanes: [Lane]

        public init(id: String, title: String, package: PackageManifest, lanes: [Lane]) {
            self.id = id
            self.title = title
            self.package = package
            self.lanes = lanes
        }
    }

    public struct Lane: Codable, Sendable {
        public var id: String
        public var `default`: Bool
        public var resolved: ResolvedLane

        public init(id: String, default: Bool, resolved: ResolvedLane) {
            self.id = id
            self.default = `default`
            self.resolved = resolved
        }
    }

    /// One MES model offer for one operation (§4.3). `model` is a MES `ModelOffer`; `params` the
    /// model's own `x-` options as a params schema; `defaults` profile-vocabulary defaults.
    public struct Offer: Codable, Sendable {
        public var operation: String
        public var profile: String
        public var model: JSONValue
        public var lanes: [String]?
        public var params: JSONValue?
        public var defaults: JSONValue?
        public var limits: Limits?
        /// Which adapters the model takes for this operation (§4.3). Absent: none.
        public var adapterSupport: AdapterSupport?
        /// Host-side facts per shipped adapter, by id (`AdapterMeta`); `adapterMetas` decodes them.
        public var adaptersMeta: JSONValue?
        /// What the model can do beyond the operation's required behaviour, by key (§4.3): `composite` for
        /// `image.decompose`, whose offers make one. Absent keys are false.
        public var supports: [String: Bool]?
        /// The preset voices the model offers for this operation (§4.3, MES Base §6.5): MES `Voice` objects, `id`
        /// first. The offer's `model.supports.voices` is their count.
        public var voices: [JSONValue]?

        enum CodingKeys: String, CodingKey {
            case operation, profile, model, lanes, params, defaults, limits, adapterSupport = "adapter_support",
                 adaptersMeta = "adapters_meta", supports, voices
        }

        public init(operation: String, profile: String, model: JSONValue, lanes: [String]? = nil,
                    params: JSONValue? = nil, defaults: JSONValue? = nil, limits: Limits? = nil,
                    adapterSupport: AdapterSupport? = nil, adaptersMeta: JSONValue? = nil, supports: [String: Bool]? = nil,
                    voices: [JSONValue]? = nil) {
            self.operation = operation
            self.profile = profile
            self.model = model
            self.lanes = lanes
            self.params = params
            self.defaults = defaults
            self.limits = limits
            self.adapterSupport = adapterSupport
            self.adaptersMeta = adaptersMeta
            self.supports = supports
            self.voices = voices
        }

        /// The model id the offer names (`model.id`).
        public var modelID: String? { model["id"]?.stringValue }

        /// `adaptersMeta`, typed. An entry that doesn't decode is left out.
        public var adapterMetas: [String: AdapterMeta] {
            guard let object = adaptersMeta?.objectValue else { return [:] }
            return object.compactMapValues { try? $0.decode(AdapterMeta.self) }
        }
    }

    /// Which adapters a model takes for one operation (§4.3), from its package's `AdapterSupport`.
    public struct AdapterSupport: Codable, Sendable, Equatable {
        public struct Strength: Codable, Sendable, Equatable {
            public var min: Double
            public var max: Double
            public init(min: Double, max: Double) { self.min = min; self.max = max }
        }

        /// The package's adapter base id (MLXToolKit `AdapterSupport.baseModel`), e.g. `qwen-image`.
        public var baseModel: String
        public var formats: [String]
        public var kinds: [String]
        public var maxCount: Int
        public var strength: Strength

        enum CodingKeys: String, CodingKey {
            case baseModel = "base_model", formats, kinds, maxCount = "max_count", strength
        }

        public init(baseModel: String, formats: [String], kinds: [String], maxCount: Int, strength: Strength) {
            self.baseModel = baseModel
            self.formats = formats
            self.kinds = kinds
            self.maxCount = maxCount
            self.strength = strength
        }
    }

    /// The pinned file a worker fetches into the models root and checks (§4.3, §4.8).
    public struct AdapterSource: Codable, Sendable, Equatable {
        public var repo: String
        /// A 40-hex commit.
        public var revision: String
        public var file: String
        public var sha256: String
        public var bytes: Int?

        public init(repo: String, revision: String, file: String, sha256: String, bytes: Int? = nil) {
            self.repo = repo
            self.revision = revision
            self.file = file
            self.sha256 = sha256
            self.bytes = bytes
        }
    }

    /// Host-side facts for one shipped adapter (§4.3).
    public struct AdapterMeta: Codable, Sendable, Equatable {
        public var trigger: String?
        public var promptTemplate: String?
        public var status: String?
        public var clearance: [String: String]?
        public var bytes: Int?
        public var format: String
        public var source: AdapterSource

        enum CodingKeys: String, CodingKey {
            case trigger, promptTemplate = "prompt_template", status, clearance, bytes, format, source
        }

        public init(trigger: String? = nil, promptTemplate: String? = nil, status: String? = nil,
                    clearance: [String: String]? = nil, bytes: Int? = nil, format: String, source: AdapterSource) {
            self.trigger = trigger
            self.promptTemplate = promptTemplate
            self.status = status
            self.clearance = clearance
            self.bytes = bytes
            self.format = format
            self.source = source
        }
    }

    public struct Limits: Codable, Sendable, Equatable {
        public var maxPixels: Int?
        public var minSide: Int?
        public var maxSide: Int?
        public var sizeMultiple: Int?
        public var maxImages: Int?
        public var maxSeconds: Double?
        public var maxFrames: Int?
        public var sampleRates: [Int]?
        /// The most layers `image.decompose` returns (MES Image §3.2's `layer_count`).
        public var maxLayerCount: Int?

        enum CodingKeys: String, CodingKey {
            case maxPixels = "max_pixels", minSide = "min_side", maxSide = "max_side",
                 sizeMultiple = "size_multiple", maxImages = "max_images", maxSeconds = "max_seconds",
                 maxFrames = "max_frames", sampleRates = "sample_rates", maxLayerCount = "max_layer_count"
        }

        public init(maxPixels: Int? = nil, minSide: Int? = nil, maxSide: Int? = nil, sizeMultiple: Int? = nil,
                    maxImages: Int? = nil, maxSeconds: Double? = nil, maxFrames: Int? = nil,
                    sampleRates: [Int]? = nil, maxLayerCount: Int? = nil) {
            self.maxPixels = maxPixels
            self.minSide = minSide
            self.maxSide = maxSide
            self.sizeMultiple = sizeMultiple
            self.maxImages = maxImages
            self.maxSeconds = maxSeconds
            self.maxFrames = maxFrames
            self.sampleRates = sampleRates
            self.maxLayerCount = maxLayerCount
        }
    }

    /// An operation only Gaea calls, never offered to clients (§4.4): `x-<vendor>.<name>`.
    public struct Helper: Codable, Sendable {
        public var operation: String
        public var model: String
        public var title: String
        public var summary: String?
        public var params: JSONValue?
        /// For a prompt-enhance helper (`x-gaea.prompt.enhance`, G-10): the profiles it rewrites with, so Gaea can
        /// decide whether a prompt needs the model at all before it calls (GPP-1 §4.4).
        public var profiles: [PromptProfile]?

        public init(operation: String, model: String, title: String, summary: String? = nil,
                    params: JSONValue? = nil, profiles: [PromptProfile]? = nil) {
            self.operation = operation
            self.model = model
            self.title = title
            self.summary = summary
            self.params = params
            self.profiles = profiles
        }
    }

    /// One prompt profile a prompt-enhance helper serves: the facts its decision reads, not its instructions.
    public struct PromptProfile: Codable, Sendable, Equatable {
        public enum Policy: String, Codable, Sendable { case required, recommended, optional }

        public var id: String
        public var version: Int
        public var title: String
        /// The image models it rewrites prompts for.
        public var models: [String]
        public var policy: Policy
        /// The tasks it has instructions for (`textToImage`, `imageEdit`).
        public var tasks: [String]
        /// It answers JSON, not prose.
        public var structured: Bool
        /// Its answer suggests a size.
        public var suggestsSize: Bool
        /// It lays out a canvas, so it is always told a size.
        public var laysOutCanvas: Bool
        /// It needs the large backbone.
        public var large: Bool
        /// A prompt that is already JSON goes as typed.
        public var passThroughStructured: Bool
        /// Under `recommended`, a prompt this many words long or longer goes as typed.
        public var detailedAtWords: Int?

        enum CodingKeys: String, CodingKey {
            case id, version, title, models, policy, tasks, structured, large
            case suggestsSize = "suggests_size", laysOutCanvas = "lays_out_canvas"
            case passThroughStructured = "pass_through_structured", detailedAtWords = "detailed_at_words"
        }

        public init(id: String, version: Int, title: String, models: [String], policy: Policy, tasks: [String],
                    structured: Bool, suggestsSize: Bool, laysOutCanvas: Bool, large: Bool, passThroughStructured: Bool,
                    detailedAtWords: Int?) {
            self.id = id; self.version = version; self.title = title; self.models = models; self.policy = policy
            self.tasks = tasks; self.structured = structured; self.suggestsSize = suggestsSize
            self.laysOutCanvas = laysOutCanvas; self.large = large; self.passThroughStructured = passThroughStructured
            self.detailedAtWords = detailedAtWords
        }
    }

    /// An operator setting (§4.5), sent to the worker in `configure`.
    public struct Setting: Codable, Sendable {
        public enum Apply: String, Codable, Sendable {
            case live
            case reloadModels = "reload_models"
            case restartWorker = "restart_worker"
        }

        public var key: String
        public var title: String
        public var description: String?
        /// A MES parameter property with a `default`.
        public var schema: JSONValue
        public var apply: Apply

        public init(key: String, title: String, description: String? = nil, schema: JSONValue, apply: Apply) {
            self.key = key
            self.title = title
            self.description = description
            self.schema = schema
            self.apply = apply
        }
    }

    /// The plugin store's schema version and its ordered migrations (§4.6).
    public struct Storage: Codable, Sendable {
        public var schemaVersion: Int
        public var migrations: [String]

        enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", migrations }

        public init(schemaVersion: Int, migrations: [String]) {
            self.schemaVersion = schemaVersion
            self.migrations = migrations
        }
    }
}
