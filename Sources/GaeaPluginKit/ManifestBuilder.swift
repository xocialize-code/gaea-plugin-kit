import Foundation
import GaeaProtocol
import MLXToolKit

/// The versions this kit build writes into hello and the manifest.
public enum GaeaPluginKitInfo {
    /// This kit's version (`hello.kit.version`).
    public static let version = "0.1.1"
    /// The mlx-engine-swift release the kit is built and tested against. SwiftPM may resolve a later
    /// 0.x patch; the contract below is read from the linked MLXToolKit itself.
    public static let engineVersion = "0.72.0"
    /// The engine contract the linked MLXToolKit defines.
    public static var engineContract: String {
        let v = ContractVersion.current
        return "\(v.major).\(v.minor).\(v.patch)"
    }
}

extension GaeaPluginDefinition {
    /// The manifest this definition describes. `models[]` is MLXToolKit's own `PackageManifest` and
    /// `ResolvedLane` per lane, as tools/manifest-gen writes them.
    public func manifest() throws -> PluginManifest {
        try check()
        return PluginManifest(
            id: id, version: version, minGaea: minGaea, team: team, repo: repo, title: title, summary: summary,
            license: license, executable: executable,
            engine: declaresEngine
                ? PluginManifest.EngineRef(version: GaeaPluginKitInfo.engineVersion,
                                           contract: GaeaPluginKitInfo.engineContract)
                : nil,
            models: models.map { model in
                PluginManifest.Model(id: model.id, title: model.title, package: model.manifest,
                                     lanes: model.lanes.map {
                                         PluginManifest.Lane(id: $0.id, default: $0.isDefault,
                                                             resolved: model.resolved($0))
                                     })
            },
            offers: offers, helpers: helpers, settings: settings, storage: storage)
    }

    /// The rules a definition can break before the validator ever sees it.
    func check() throws {
        var problems: [String] = []
        if team != GPP.trustedTeam {
            problems.append("team \(team) is not \(GPP.trustedTeam), the only team Gaea v1 trusts (G-22)")
        }
        for model in models {
            if model.lanes.filter(\.isDefault).count != 1 {
                problems.append("model \(model.id) needs exactly one default lane")
            }
            if case .engine(_, let operations) = model.backing {
                if model.manifest.capabilities.isEmpty {
                    problems.append("engine model \(model.id) declares no surfaces, so the engine can't prepare it; make it .custom")
                }
                for op in operations.keys where !serves(op, model: model.id) {
                    problems.append("model \(model.id) maps \(op), which no offer or helper names")
                }
            }
        }
        for offer in offers where model(offer.modelID ?? "") == nil {
            problems.append("offer \(offer.operation) names model \(offer.modelID ?? "?"), which isn't declared")
        }
        for helper in helpers where model(helper.model) == nil {
            problems.append("helper \(helper.operation) names model \(helper.model), which isn't declared")
        }
        if !problems.isEmpty {
            throw GPPError(.internal, "Invalid plugin definition: " + problems.joined(separator: "; "))
        }
    }

    /// Settings with every manifest default filled in, then `values` over them.
    func settings(merging values: [String: JSONValue]) -> [String: JSONValue] {
        var merged: [String: JSONValue] = [:]
        for setting in settings {
            if let d = setting.schema["default"] { merged[setting.key] = d }
        }
        merged.merge(values) { _, new in new }
        return merged
    }
}
