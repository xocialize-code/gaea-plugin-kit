import Foundation
import GaeaProtocol
import MLXToolKit

// Adapters (LoRAs) on a plugin's engine models (GPP-1 §3.3, §4.3, §4.8; Gaea AB-T-0378, AB-T-0381).
//
// - A run's `adapters[]` arrive typed as `Job.adapters`. An operation puts `job.adapterRefs()` on its
//   `T2IRequest`/`IEditRequest`; the worker registers each adapter with its `MLXServeEngine` first (the descriptor
//   built from what Gaea sent, or the one the plugin ships), fetches it into `<models_root>/adapters/<sha256>/`,
//   and the engine checks the digest and applies it through the package's typed adapter path.
// - A model can ship adapters (`ModelDefinition.shipping`, read from an adapter registry in format 3). The manifest
//   generator lists them on every offer whose surface admits them (MES `AdapterOffer` in `model.adapters`, the
//   host-side facts in `adapters_meta`), and writes `adapter_support` from the package's own `AdapterSupport`.

/// One `run.adapters` item (GPP-1 §3.3): the client's id and strength, an `ic` adapter's images by role, and the kind,
/// format and pinned source Gaea adds from the offer's `adapters_meta` or the operator's registration.
public struct JobAdapter: Sendable, Equatable {
    public var id: String
    public var strength: Double?
    public var kind: AdapterKind
    public var format: AdapterFormat
    public var source: PluginManifest.AdapterSource
    /// An `ic` adapter's conditioning inputs, by slot role; a single path arrives as a one-element array.
    public var inputs: [String: [URL]]

    public init(id: String, strength: Double? = nil, kind: AdapterKind = .plain, format: AdapterFormat,
                source: PluginManifest.AdapterSource, inputs: [String: [URL]] = [:]) {
        self.id = id
        self.strength = strength
        self.kind = kind
        self.format = format
        self.source = source
        self.inputs = inputs
    }

    /// Decode one item, refusing what the worker couldn't fetch or apply.
    static func decode(_ value: JSONValue, index: Int) throws -> JobAdapter {
        let at = "adapters[\(index)]"
        guard let o = value.objectValue else { throw GPPError(.invalidRequest, "\(at) is not an object.") }
        guard let id = o["id"]?.stringValue, !id.isEmpty else { throw GPPError(.invalidRequest, "\(at) has no id.") }
        let known: Set<String> = ["id", "strength", "kind", "format", "source", "inputs"]
        if let unknown = o.keys.filter({ !known.contains($0) }).sorted().first {
            throw GPPError(.invalidRequest, "Adapter \(id) has unknown field \(unknown).")
        }
        var strength: Double?
        if let s = o["strength"] {
            guard let d = s.doubleValue, d.isFinite else { throw GPPError(.invalidRequest, "Adapter \(id): strength is a number.") }
            strength = d
        }
        guard let format = o["format"]?.stringValue, !format.isEmpty else {
            throw GPPError(.invalidRequest, "Adapter \(id) has no format; Gaea sends the one adapters_meta or the registration names.")
        }
        let source: PluginManifest.AdapterSource
        do {
            source = try (o["source"] ?? .null).decode(PluginManifest.AdapterSource.self)
        } catch {
            throw GPPError(.invalidRequest, "Adapter \(id) has no source {repo, revision, file, sha256}, so the worker can't fetch it.")
        }
        let problems = MLXToolKit.AdapterSource(repo: source.repo, revision: source.revision, file: source.file,
                                                sha256: source.sha256).validationProblems
        guard problems.isEmpty else {
            throw GPPError(.invalidRequest, "Adapter \(id)'s source isn't pinned: \(problems.joined(separator: "; ")).")
        }
        var inputs: [String: [URL]] = [:]
        for (role, v) in o["inputs"]?.objectValue ?? [:] {
            let paths: [String] = switch v {
            case .string(let s): [s]
            case .array(let a): a.compactMap(\.stringValue)
            default: []
            }
            guard !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") }) else {
                throw GPPError(.invalidRequest, "Adapter \(id): inputs.\(role) is an absolute path or an array of them.")
            }
            inputs[role] = paths.map { URL(fileURLWithPath: $0) }
        }
        let kind = AdapterKind(rawValue: o["kind"]?.stringValue ?? (inputs.isEmpty ? "plain" : "ic"))
        guard kind == .plain || kind == .referenceConditioned else {
            throw GPPError(.invalidRequest, "Adapter \(id) is of kind \(kind), which GPP v1 doesn't carry (plain, ic).")
        }
        if kind == .plain, !inputs.isEmpty {
            throw GPPError(.invalidRequest, "Adapter \(id) is plain, so it takes no inputs.")
        }
        return JobAdapter(id: id, strength: strength, kind: kind, format: AdapterFormat(rawValue: format), source: source,
                          inputs: inputs)
    }
}

extension Job {
    /// The run's adapters as the engine's `AdapterRef`s, for an operation to put on its request (`T2IRequest(…,
    /// adapters:)`): each with the strength Gaea sent, and an `ic` adapter's images as role-tagged conditioning (the
    /// engine orders them into the adapter's slots). Triggers and prompt templates are already in the prompt (GPP-1
    /// §3.3): the operation adds nothing to it.
    public func adapterRefs() throws -> [AdapterRef] {
        try adapters.map { adapter in
            let conditioning = try adapter.inputs.sorted { $0.key < $1.key }.flatMap { role, urls in
                try urls.map { url in
                    ConditioningInput(role: role, media: .image(try imageFile(url, name: "adapter \(adapter.id) \(role)")))
                }
            }
            return AdapterRef(id: adapter.id, strength: adapter.strength, conditioning: conditioning)
        }
    }
}

/// An adapter a model ships, from an adapter registry in format 3 (ltx-lora-registry; the packages' own `registry/*.json`,
/// vendored by mlx-image-runtime): what the engine registers, and what the manifest offers and Gaea shows.
public struct ShippedAdapter: Sendable, Equatable {
    public struct Clearance: Sendable, Equatable {
        /// `declared`, `mechanical` or `perceptual`.
        public var level: String
        public var note: String?
    }

    /// The engine's descriptor; its id qualified `<namespace>:<id>` as mlx-image-runtime's catalog does.
    public var descriptor: AdapterDescriptor
    public var title: String
    public var trigger: String?
    public var promptTemplate: String?
    /// `allowed`, `conditional`, `prohibited` or `unknown` (the registry's `licenseTerms.commercialUse`).
    public var commercialUse: String
    public var licenseGated: Bool
    public var licenseNotice: String?
    public var licenseURL: String?
    /// The registry's status: `verified`, or `candidate` for one Gaea makes opt-in.
    public var status: String
    /// By base model.
    public var clearance: [String: Clearance]

    public var id: String { descriptor.id }
}

public enum AdapterRegistry {
    public struct Skipped: Sendable, Equatable {
        public var id: String
        public var reason: String
    }

    private struct Document: Decodable {
        let format: String
        let schemaVersion: Int
        let namespace: String
    }

    private struct Extras: Decodable {
        struct Terms: Decodable {
            let commercialUse: String
            let gated: Bool?
            let notice: String?
            let url: String?
        }
        struct Clearance: Decodable {
            let level: String
            let note: String?
        }
        let title: String?
        let trigger: String?
        let promptTemplate: String?
        let licenseTerms: Terms
        let status: String
        let clearance: [String: Clearance]?
    }

    /// Read a registry in format 3 the way mlx-image-runtime's `AdapterCatalog.decode` does: ids qualified by the
    /// registry's namespace, `withdrawn` never read, and an entry the engine would refuse skipped with its reason.
    public static func decode(_ data: Data) throws -> (adapters: [ShippedAdapter], skipped: [Skipped]) {
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.format == "adapter-registry", document.schemaVersion == 3 else {
            throw GPPError(.internal, "Not an adapter registry in format 3 (format \(document.format), schemaVersion \(document.schemaVersion)).")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["adapters"] as? [[String: Any]] else { return ([], []) }
        var adapters: [ShippedAdapter] = [], skipped: [Skipped] = []
        for item in items {
            let raw = try JSONSerialization.data(withJSONObject: item)
            let id = "\(document.namespace):\((item["id"] as? String) ?? "?")"
            do {
                let d = try JSONDecoder().decode(AdapterDescriptor.self, from: raw)
                let extras = try JSONDecoder().decode(Extras.self, from: raw)
                let descriptor = AdapterDescriptor(
                    id: id, title: d.title, kind: d.kind, format: d.format, baseModels: d.baseModels,
                    capabilities: d.capabilities, source: d.source, license: d.license, defaultStrength: d.defaultStrength,
                    strengthRange: d.strengthRange, conditioning: d.conditioning, conditioningGroups: d.conditioningGroups,
                    footprint: d.footprint)
                let problems = descriptor.validationProblems
                guard problems.isEmpty else {
                    skipped.append(Skipped(id: id, reason: problems.joined(separator: "; ")))
                    continue
                }
                adapters.append(ShippedAdapter(
                    descriptor: descriptor, title: d.title ?? extras.title ?? id, trigger: extras.trigger,
                    promptTemplate: extras.promptTemplate, commercialUse: extras.licenseTerms.commercialUse,
                    licenseGated: extras.licenseTerms.gated ?? false, licenseNotice: extras.licenseTerms.notice,
                    licenseURL: extras.licenseTerms.url, status: extras.status,
                    clearance: (extras.clearance ?? [:]).mapValues { ShippedAdapter.Clearance(level: $0.level, note: $0.note) }))
            } catch {
                skipped.append(Skipped(id: id, reason: "\(error)"))
            }
        }
        return (adapters, skipped)
    }
}

// MARK: - The manifest

extension PluginManifest.AdapterSupport {
    /// GPP's form of a package's `AdapterSupport` (§4.3).
    public init(_ support: MLXToolKit.AdapterSupport) {
        self.init(baseModel: support.baseModel, formats: support.formats.map(\.rawValue), kinds: support.kinds.map(\.rawValue),
                  maxCount: support.maxCount, strength: Strength(min: support.strengthRange.min, max: support.strengthRange.max))
    }
}

extension ShippedAdapter {
    /// The MES `AdapterOffer` (descriptor §6.3) on an offer whose surface admits it with `support`.
    func offer(_ support: MLXToolKit.AdapterSupport) -> JSONValue {
        let range = descriptor.strengthRange.flatMap { support.strengthRange.intersection($0) } ?? support.strengthRange
        let use: JSONValue = switch commercialUse {
        case "allowed", "conditional": .bool(true)
        case "prohibited", "no", "none": .bool(false)
        default: "unknown"
        }
        var license: [String: JSONValue] = ["spdx": .string(descriptor.license.identifier), "commercial_use": use]
        if let licenseURL { license["terms_url"] = .string(licenseURL) }
        if let licenseNotice { license["notice"] = .string(licenseNotice) }
        if licenseGated { license["accepted_required"] = true }
        var o: [String: JSONValue] = [
            "id": .string(id), "title": .string(title), "kind": .string(descriptor.kind.rawValue),
            "strength": ["min": .double(range.min), "max": .double(range.max), "default": .double(descriptor.defaultStrength)],
            "license": .object(license),
        ]
        if !descriptor.conditioning.isEmpty {
            o["slots"] = .array(descriptor.conditioning.map { slot in
                var s: [String: JSONValue] = ["role": .string(slot.role), "kind": .string(slot.media.rawValue),
                                              "required": .bool(slot.required)]
                if let note = slot.note { s["notes"] = .string(String(note.prefix(1000))) }
                return .object(s)
            })
        }
        // The note on how it was cleared for this base model ("not yet judged on our stack").
        if let note = clearance[support.baseModel]?.note, !note.isEmpty { o["notes"] = .string(String(note.prefix(1000))) }
        return .object(o)
    }

    /// The host-side facts (`adapters_meta`, §4.3).
    var meta: PluginManifest.AdapterMeta {
        let source = descriptor.source
        return PluginManifest.AdapterMeta(
            trigger: trigger, promptTemplate: promptTemplate, status: status,
            clearance: clearance.isEmpty ? nil : clearance.mapValues(\.level),
            bytes: source.bytes.map { Int(clamping: $0) }, format: descriptor.format.rawValue,
            source: PluginManifest.AdapterSource(repo: source.repo, revision: source.revision, file: source.file,
                                                 sha256: source.sha256, bytes: source.bytes.map { Int(clamping: $0) }))
    }
}

/// The engine capability behind an MES operation that can carry adapters.
func adapterCapability(_ operation: String) -> Capability? {
    switch operation {
    case "image.generate": .textToImage
    case "image.edit": .imageEdit
    case "video.generate": .textToVideo
    case "video.edit": .videoEdit
    default: nil
    }
}

extension ModelDefinition {
    /// The package's adapter support for `capability`, when its surface declares one.
    func adapterSupport(_ capability: Capability) -> MLXToolKit.AdapterSupport? {
        guard case .engine = backing,
              let surface = manifest.surfaces.first(where: { $0.capability == capability }),
              surface.adaptersMatchCapability else { return nil }
        return surface.adapters
    }
}

extension PluginManifest.Offer {
    /// The offer with `adapter_support` from the package's surface (unless the definition set one), and the model's
    /// shipped adapters that surface admits in `model.adapters` and `adapters_meta`.
    func withAdapters(of model: ModelDefinition) -> PluginManifest.Offer {
        guard let capability = adapterCapability(operation), let support = model.adapterSupport(capability) else { return self }
        var offer = self
        if offer.adapterSupport == nil { offer.adapterSupport = PluginManifest.AdapterSupport(support) }
        let fitting = model.adapters.filter { support.mismatch($0.descriptor, capability: capability) == nil }
        guard !fitting.isEmpty, var m = offer.model.objectValue else { return offer }
        var listed = m["adapters"]?.arrayValue ?? []
        var metas = offer.adaptersMeta?.objectValue ?? [:]
        let ids = Set(listed.compactMap { $0["id"]?.stringValue })
        for adapter in fitting where !ids.contains(adapter.id) {
            listed.append(adapter.offer(support))
            metas[adapter.id] = (try? JSONValue(encoding: adapter.meta)) ?? .null
        }
        m["adapters"] = .array(listed)
        offer.model = .object(m)
        offer.adaptersMeta = .object(metas)
        return offer
    }
}
