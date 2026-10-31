import Foundation
import GaeaProtocol
import MLXToolKit
import Testing
@testable import GaeaPluginKit

/// GPP-1 §3.2.1 and §3.3 (Gaea AB-T-0400): the weights' volume on `prepared`, a volume below a lane's floor as
/// `storage_below_floor`, and previews on `progress`.
final class FakeFramer: PluginModel, @unchecked Sendable {
    func prepare(lane: LaneDefinition, context: WorkerContext) async throws {}
    func unload() async {}

    func run(_ job: Job, context: RunContext) async throws -> RunResult {
        context.progress("denoise", step: 3, of: 8)
        let frame = job.outputDir.appending(path: "preview-3.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: frame)
        context.preview(frame)
        let out = job.outputDir.appending(path: "video-0.mp4")
        try Data([0, 0, 0, 24]).write(to: out)
        return RunResult(outputs: [.file("video", out, mediaType: "video/mp4")])
    }
}

@Suite("Storage and previews")
struct StorageAndPreviewTests {
    @Test func aVolumeBelowTheFloorIsStorageBelowFloor() {
        let error = GPPWorker.translate(PackageError.weightsVolumeBelowFloor("USB at 300 MB/s; the lane needs 1 GB/s"))
        #expect(error.code == .storageBelowFloor)
        #expect(error.message.contains("1 GB/s"))
    }

    @Test func theVolumeRidesPrepared() {
        let volume = VolumeCharacterization(volumePath: "/Volumes/DEV_VOL1", protocolName: "USB", isRemovable: true,
                                            freeBytes: nil, sustainedReadBytesPerSecond: 450_000_000,
                                            probedFile: nil, measuredAt: Date())
        let storage = GPPWorker.storage(volume, [])
        #expect(storage == ["volume": "/Volumes/DEV_VOL1", "read_bytes_per_s": 450_000_000, "protocol": "USB",
                            "removable": true])
        #expect(GPPWorker.storage(nil, []) == nil)
    }

    @Test func aPreviewRidesProgressAndTheSessionValidates() async throws {
        let definition = GaeaPluginDefinition(
            id: "com.xocialize.gaea.framer", version: "0.1.0", team: "CFZS6RXUCP",
            repo: "https://github.com/xocialize-code/gaea-plugin-framer", title: "Framer", license: "Apache-2.0",
            executable: "gaea-framer-worker", declaresEngine: false,
            models: [.custom(id: "framer", title: "Framer", manifest: demoPackageManifest,
                             lanes: [LaneDefinition(id: "fp32", default: true, configuration: Bundled())], make: { FakeFramer() })],
            offers: [PluginManifest.Offer(operation: "image.generate", profile: "image", model: ["id": "framer"])])
        let tmp = FileManager.default.temporaryDirectory.appending(path: "gaea-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let manifest = tmp.appending(path: "manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(try definition.manifest()).write(to: manifest)

        let lines = LineQueue()
        var session: [String] = []
        let worker = GPPWorker(definition: definition, manifest: try Data(contentsOf: manifest),
                               connection: GPPConnection { lines.push(String(decoding: $0.dropLast(), as: UTF8.self)) },
                               engineFactory: fakeEngineFactory, onExit: { _ in })
        func send(_ line: String) async { session.append("H " + line); await worker.handle(line: line) }
        func next() async throws -> JSONValue {
            let line = try #require(await lines.pop(timeout: .seconds(10)))
            session.append("W " + line)
            return try Replay.parse(line)
        }

        await worker.sendHello()
        _ = try await next()
        await send(#"{"type":"configure","id":"h1","budget":{"ceilingBytes":8000000000,"wiresWeights":false},"models_root":"\#(tmp.path)/models","cache_root":"\#(tmp.path)/cache","settings":{}}"#)
        _ = try await next()
        let out = tmp.appending(path: "job").path
        await send(#"{"type":"run","id":"h2","job":"job_p","operation":"image.generate","model":"framer","lane":"fp32","inputs":{},"params":{},"output_dir":"\#(out)"}"#)
        var previews: [JSONValue] = []
        var m = try await next()
        while m["type"] == "progress" {
            if m["preview"] != nil { previews.append(m) }
            m = try await next()
        }
        #expect(m["type"] == "result", "\(m)")
        _ = try await next()   // memory
        #expect(previews.count == 1)
        #expect(previews.first?["preview"]?["media_type"] == "image/png")
        #expect(previews.first?["preview"]?["path"]?.stringValue == out + "/preview-3.png")
        #expect(previews.first?["step"] == 3 && previews.first?["of"] == 8)

        let file = tmp.appending(path: "preview.gpp")
        try ("# manifest: \(manifest.path)\n" + session.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let (status, output) = try Spec.validate(["--transcript", file.path])
        #expect(status == 0, "\(output)\n\(session.joined(separator: "\n"))")
    }
}
