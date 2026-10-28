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
        public var adaptersMeta: JSONValue?

        enum CodingKeys: String, CodingKey {
            case operation, profile, model, lanes, params, defaults, limits, adaptersMeta = "adapters_meta"
        }

        public init(operation: String, profile: String, model: JSONValue, lanes: [String]? = nil,
                    params: JSONValue? = nil, defaults: JSONValue? = nil, limits: Limits? = nil,
                    adaptersMeta: JSONValue? = nil) {
            self.operation = operation
            self.profile = profile
            self.model = model
            self.lanes = lanes
            self.params = params
            self.defaults = defaults
            self.limits = limits
            self.adaptersMeta = adaptersMeta
        }

        /// The model id the offer names (`model.id`).
        public var modelID: String? { model["id"]?.stringValue }
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

        enum CodingKeys: String, CodingKey {
            case maxPixels = "max_pixels", minSide = "min_side", maxSide = "max_side",
                 sizeMultiple = "size_multiple", maxImages = "max_images", maxSeconds = "max_seconds",
                 maxFrames = "max_frames", sampleRates = "sample_rates"
        }

        public init(maxPixels: Int? = nil, minSide: Int? = nil, maxSide: Int? = nil, sizeMultiple: Int? = nil,
                    maxImages: Int? = nil, maxSeconds: Double? = nil, maxFrames: Int? = nil,
                    sampleRates: [Int]? = nil) {
            self.maxPixels = maxPixels
            self.minSide = minSide
            self.maxSide = maxSide
            self.sizeMultiple = sizeMultiple
            self.maxImages = maxImages
            self.maxSeconds = maxSeconds
            self.maxFrames = maxFrames
            self.sampleRates = sampleRates
        }
    }

    /// An operation only Gaea calls, never offered to clients (§4.4): `x-<vendor>.<name>`.
    public struct Helper: Codable, Sendable {
        public var operation: String
        public var model: String
        public var title: String
        public var summary: String?
        public var params: JSONValue?

        public init(operation: String, model: String, title: String, summary: String? = nil,
                    params: JSONValue? = nil) {
            self.operation = operation
            self.model = model
            self.title = title
            self.summary = summary
            self.params = params
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
