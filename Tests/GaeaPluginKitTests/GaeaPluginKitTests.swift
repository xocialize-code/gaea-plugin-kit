import Foundation
import GaeaPluginKit
import GaeaProtocol
import MLXToolKit
import Testing

@Suite("manifest generation")
struct ManifestTests {
    /// The kit writes the examples' manifests from code: same JSON, and the validator accepts it.
    @Test(arguments: ["demo.json", "z-image.json"])
    func generatesExample(name: String) throws {
        let definition = name == "demo.json" ? demoDefinition() : zImageDefinition()
        let generated = try definition.manifest().encoded()
        let example = try Data(contentsOf: Spec.manifest(name))
        #expect(try Replay.parse(String(decoding: generated, as: UTF8.self))
            == Replay.parse(String(decoding: example, as: UTF8.self)))

        let file = FileManager.default.temporaryDirectory.appending(path: "gaea-\(UUID().uuidString)-\(name)")
        try generated.write(to: file)
        let (status, output) = try Spec.validate(["--manifest", file.path])
        #expect(status == 0, "\(output)")
    }

    @Test func declaresTheLinkedEngine() throws {
        var definition = demoDefinition()
        definition.declaresEngine = true
        let manifest = try definition.manifest()
        #expect(manifest.engine == PluginManifest.EngineRef(version: "0.72.0", contract: "1.57.0"))
        #expect(GaeaPluginKitInfo.engineContract == "1.57.0")
    }

    @Test func rejectsAnotherTeam() {
        var definition = demoDefinition()
        definition.team = "F84FKGN358"
        #expect(throws: GPPError.self) { try definition.manifest() }
    }

    @Test func rejectsAnEngineModelWithoutSurfaces() {
        var definition = demoDefinition()
        definition.models = [.engine(PackageRegistration(manifest: demoPackageManifest) { _ in fatalError() },
                                     id: "demo-matmul", title: "x",
                                     lanes: [LaneDefinition(id: "fp32", default: true, configuration: Bundled())],
                                     operations: [])]
        #expect(throws: GPPError.self) { try definition.manifest() }
    }
}

/// z-image-generate.gpp's plugin reads its stored preset once configured.
let readPreset: @Sendable (WorkerContext, Bool) async throws -> Void = { context, initial in
    guard initial else { return }
    let preset = try await context.storage.get("presets", "studio-portrait")
    #expect(preset == ["x-zimage.shift": 2.5])
}

@Suite("GPP replay of examples/v1/gpp", .serialized)
struct ReplayTests {
    /// Replay, then check every line of the session with tools/validate.py --transcript.
    func replay(_ name: String, _ definition: GaeaPluginDefinition) async throws {
        let replay = try Replay(transcript: Spec.transcript(name))
        try await replay.run(definition)
        let (status, output) = try Spec.validate(["--transcript", try replay.writeSession().path])
        #expect(status == 0, "\(output)")
    }

    @Test func demoSession() async throws {
        try await replay("demo-session.gpp", demoDefinition())
    }

    @Test func zImageGenerate() async throws {
        try await replay("z-image-generate.gpp", zImageDefinition(onConfigure: readPreset))
    }

    @Test func storageAndErrors() async throws {
        try await replay("storage-and-errors.gpp", zImageDefinition { context, initial in
            guard initial else { return }
            let s = context.storage
            try await s.put("presets", "studio-portrait", ["x-zimage.shift": 2.5])
            try await s.put("presets", "night", ["x-zimage.shift": 4])
            let first = try await s.query("presets", limit: 1)
            #expect(first.items.map(\.key) == ["night"] && first.more)
            let rest = try await s.query("presets", after: "night", limit: 10)
            #expect(rest.items.map(\.key) == ["studio-portrait"] && !rest.more)
            try await s.delete("presets", "night")
            let gone = try await s.get("presets", "night")
            #expect(gone == JSONValue?.none)
            await #expect(throws: GPPError.self) { try await s.put("cache", "huge", "…") }
        })
    }
}

/// Paths of the protocol the examples don't walk: refusals, busy, and a shutdown during a run.
@Suite("GPP edge cases")
struct EdgeCaseTests {
    @Test func refusalsBusyAndShutdownDuringARun() async throws {
        let lines = LineQueue()
        let exited = LineQueue()
        var session: [String] = []
        let worker = GPPWorker(definition: demoDefinition(), manifest: try Data(contentsOf: Spec.manifest("demo.json")),
                               connection: GPPConnection { lines.push(String(decoding: $0.dropLast(), as: UTF8.self)) },
                               engineFactory: fakeEngineFactory, onExit: { exited.push("\($0)") })
        let tmp = FileManager.default.temporaryDirectory.appending(path: "gaea-edge-\(UUID().uuidString)").path
        func send(_ line: String) async { session.append("H " + line); await worker.handle(line: line) }
        func expect(_ type: String, code: String? = nil) async throws -> JSONValue {
            let line = try #require(await lines.pop(timeout: .seconds(10)))
            session.append("W " + line)
            let m = try Replay.parse(line)
            #expect(m["type"]?.stringValue == type, "\(line)")
            if let code { #expect(m["code"]?.stringValue == code, "\(line)") }
            return m
        }

        await worker.sendHello()
        _ = try await expect("hello")
        await send(#"{"type":"memory.query","id":"h1"}"#)
        _ = try await expect("error", code: "invalid_request")       // before configure
        await send(#"{"type":"configure","id":"h2","budget":{"ceilingBytes":8000000000,"wiresWeights":false},"models_root":"\#(tmp)/models","cache_root":"\#(tmp)/cache","settings":{}}"#)
        _ = try await expect("configured")
        // Lines no host that reads the manifest would send: answered, and kept out of the validated session.
        func probe(_ line: String, _ code: String, re: String?) async throws {
            await worker.handle(line: line)
            let m = try Replay.parse(try #require(await lines.pop(timeout: .seconds(10))))
            #expect(m["type"] == "error" && m["code"]?.stringValue == code && m["re"]?.stringValue == re, "\(m)")
        }
        try await probe(#"{"type":"teleport","id":"h3"}"#, "protocol", re: nil)
        try await probe(#"{"type":"prepare","id":"h4","model":"demo-matmul","lane":"fp32","extra":1}"#, "invalid_request", re: "h4")
        try await probe(#"{"type":"prepare","id":"h5","model":"demo-matmul","lane":"int4"}"#, "unknown_model", re: "h5")
        try await probe(#"{"type":"run","id":"h6","job":"job_a","operation":"x-gaea.demo.other","model":"demo-matmul","lane":"fp32","inputs":{},"params":{},"output_dir":"\#(tmp)/a"}"#, "unsupported_operation", re: "h6")
        await send(#"{"type":"run","id":"h7","job":"job_b","operation":"x-gaea.demo.matmul","model":"demo-matmul","lane":"fp32","inputs":{},"params":{"iterations":500},"output_dir":"\#(tmp)/b"}"#)
        let progress = try await expect("progress")
        #expect(progress["step"] == 1)
        await send(#"{"type":"run","id":"h8","job":"job_c","operation":"x-gaea.demo.matmul","model":"demo-matmul","lane":"fp32","inputs":{},"params":{},"output_dir":"\#(tmp)/c"}"#)
        _ = try await expect("error", code: "busy")
        await send(#"{"type":"shutdown","id":"h9"}"#)
        let cancelled = try await expect("error", code: "cancelled")
        #expect(cancelled["re"] == "h7")
        #expect(await exited.pop(timeout: .seconds(10)) == "0")

        let file = URL(fileURLWithPath: tmp + ".gpp")
        try ("# manifest: \(Spec.manifest("demo.json").path)\n" + session.joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        let (status, output) = try Spec.validate(["--transcript", file.path])
        #expect(status == 0, "\(output)\n\(session.joined(separator: "\n"))")
    }

    @Test func spooledOutputsAreFilesUnderOutputDir() async throws {
        // An engine response's artifacts land in output_dir as files named after their field.
        let replay = try Replay(transcript: Spec.transcript("z-image-generate.gpp"))
        try await replay.run(zImageDefinition(onConfigure: readPreset))
        let result = try #require(replay.session.first { $0.hasPrefix("W ") && $0.contains(#""type":"result""#) })
        let m = try Replay.parse(String(result.dropFirst(2)))
        let path = try #require(m["outputs"]?.arrayValue?.first?["path"]?.stringValue)
        #expect(path.hasSuffix("/out/image-0.png"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == tinyPNG)
    }
}
