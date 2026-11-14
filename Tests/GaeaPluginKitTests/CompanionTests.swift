import Foundation
import GaeaProtocol
import MLXToolKit
import Testing
@testable import GaeaPluginKit

/// A model composing with another engine model of its plugin (`ModelDefinition.companions`, kit 0.12.0, Gaea AB-T-0467):
/// its lanes list the companion's weights, and preparing it downloads and loads the companion first.
@Suite("Companions")
struct CompanionTests {
    static let matteRepo = "mlx-community/Fake-Matte"

    static func definition(companions: [String] = ["fake-matte"], charged: Bool = false) -> GaeaPluginDefinition {
        let matte = ModelDefinition.engine(FakeZImagePackage.self, id: "fake-matte", title: "Matte",
                                           lanes: [LaneDefinition(id: "bf16", default: true,
                                                                  configuration: FakeZImageConfiguration(quant: .bf16, repo: matteRepo))],
                                           operations: [])
        let main = ModelDefinition.engine(FakeZImagePackage.self, id: "z-image-turbo", title: "Z-Image Turbo",
                                          lanes: [LaneDefinition(id: "int4", default: true, configuration: FakeZImageConfiguration(quant: .int4))],
                                          operations: [zImageGenerate]).composing(companions, charged: charged)
        return GaeaPluginDefinition(
            id: "com.xocialize.gaea.companion-test", version: "0.1.0", team: "CFZS6RXUCP",
            repo: "https://github.com/xocialize-code/gaea-plugin-companion-test", title: "Companion test",
            summary: "A model that composes with a second one.", license: "MIT", executable: "gaea-companion-test-worker",
            models: [main, matte],
            offers: [PluginManifest.Offer(operation: "image.generate", profile: "image",
                                          model: ["id": "z-image-turbo", "title": "Z-Image Turbo", "license": apache,
                                                  "memory_class": "large", "speed_class": "fast", "quality_tiers": ["standard"]])])
    }

    @Test func lanesListTheCompanionsWeights() throws {
        let manifest = try Self.definition().manifest()
        let main = try #require(manifest.models.first { $0.id == "z-image-turbo" })
        #expect(main.lanes[0].resolved.weightSources.map(\.repo) == ["mlx-community/Z-Image-Turbo-bf16", Self.matteRepo])
        let matte = try #require(manifest.models.first { $0.id == "fake-matte" })
        #expect(matte.lanes[0].resolved.weightSources.map(\.repo) == [Self.matteRepo])
    }

    /// Uncharged (the default), a lane's memory is the model's own figures: they were measured with the companion in.
    @Test func anUnchargedCompanionLeavesTheLanesMemoryAlone() throws {
        let definition = Self.definition()
        let main = try #require(definition.model("z-image-turbo"))
        let own = main.resolved(try #require(main.defaultLane))
        let lane = try #require(try definition.manifest().models.first { $0.id == "z-image-turbo" }).lanes[0].resolved
        #expect(lane.persistentBytes == own.persistentBytes)
        #expect(lane.peakTransientBytes == own.peakTransientBytes)
    }

    /// Charged (0.13.1), the lane holds both: persistent bytes summed, the peak transient the larger of the two; the
    /// companion's own entry is unchanged.
    @Test func aChargedCompanionsMemoryIsAddedToTheLane() throws {
        let definition = Self.definition(charged: true)
        let main = try #require(definition.model("z-image-turbo"))
        let matte = try #require(definition.model("fake-matte"))
        let own = main.resolved(try #require(main.defaultLane))
        let companion = matte.resolved(try #require(matte.defaultLane))
        #expect(companion.persistentBytes > 0)
        let manifest = try definition.manifest()
        let lane = try #require(manifest.models.first { $0.id == "z-image-turbo" }).lanes[0].resolved
        #expect(lane.persistentBytes == own.persistentBytes + companion.persistentBytes)
        #expect(lane.peakTransientBytes == max(own.peakTransientBytes, companion.peakTransientBytes))
        #expect(lane.weightSources.map(\.repo) == ["mlx-community/Z-Image-Turbo-bf16", Self.matteRepo])
        let matteLane = try #require(manifest.models.first { $0.id == "fake-matte" }).lanes[0].resolved
        #expect(matteLane.persistentBytes == companion.persistentBytes)
    }

    @Test func anUnknownCompanionIsRefused() {
        #expect(throws: (any Error).self) { try Self.definition(companions: ["nobody"]).manifest() }
        #expect(throws: (any Error).self) { try Self.definition(companions: ["z-image-turbo"]).manifest() }
    }

    @Test func preparingDownloadsAndLoadsTheCompanionFirst() async throws {
        let definition = Self.definition()
        let lines = LineQueue()
        let worker = GPPWorker(definition: definition, manifest: try JSONEncoder().encode(definition.manifest()),
                               connection: GPPConnection { lines.push(String(decoding: $0.dropLast(), as: UTF8.self)) },
                               engineFactory: fakeEngineFactory, onExit: { _ in })
        let tmp = FileManager.default.temporaryDirectory.appending(path: "gaea-companion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        func next(_ type: String) async throws -> JSONValue {
            while true {
                let line = try #require(await lines.pop(timeout: .seconds(20)))
                let m = try Replay.parse(line)
                if m["type"]?.stringValue == type { return m }
                if m["type"]?.stringValue == "error" { Issue.record("\(line)"); return m }
            }
        }
        await worker.sendHello()
        _ = try await next("hello")
        await worker.handle(line: #"{"type":"configure","id":"c1","budget":{"ceilingBytes":80000000000,"wiresWeights":false},"models_root":"\#(tmp.path)/models","cache_root":"\#(tmp.path)/cache","settings":{}}"#)
        _ = try await next("configured")
        await worker.handle(line: #"{"type":"prepare","id":"p1","model":"z-image-turbo","lane":"int4"}"#)
        _ = try await next("prepared")
        let root = tmp.appending(path: "models")
        for repo in ["mlx-community/Z-Image-Turbo-bf16", Self.matteRepo] {
            let marker = FakeMaterializer.marker(WeightSource(role: "snapshot", repo: repo, revision: "main", matching: []), root)
            #expect(FileManager.default.fileExists(atPath: marker.path), "\(repo) downloaded")
        }
    }
}
