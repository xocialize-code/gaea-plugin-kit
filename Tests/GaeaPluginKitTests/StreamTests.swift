import Foundation
import GaeaPluginKit
import GaeaProtocol
import Testing

/// A tone "speaker" for audio.speak: three chunks of a tenth of a second at 24 kHz when the host asks to stream
/// `audio`, else the same samples as one value (the WAV is the host's business).
final class FakeTone: PluginModel, @unchecked Sendable {
    static let chunk = 2400

    func prepare(lane: LaneDefinition, context: WorkerContext) async throws {}
    func unload() async {}

    func run(_ job: Job, context: RunContext) async throws -> RunResult {
        let samples = (0..<(3 * Self.chunk)).map { Float(sin(Double($0) * 2 * .pi * 440 / 24000)) * 0.5 }
        guard job.streams("audio") else {
            return RunResult(outputs: [.value("audio", .int(Int64(samples.count)))])
        }
        for i in 0..<3 {
            try context.checkCancellation()
            try context.emit("audio", samples: Array(samples[(i * Self.chunk)..<((i + 1) * Self.chunk)]), sampleRate: 24000,
                             final: i == 2)
        }
        return RunResult(outputs: [.streamed("audio")], effective: ["voice": "tone-a", "asset": .string(job.asset("voice_ref") ?? "none")])
    }
}

let toneOffer = PluginManifest.Offer(
    operation: "audio.speak", profile: "audio",
    model: ["id": "tone", "title": "Tone", "license": ["spdx": "Apache-2.0", "commercial_use": true],
            "memory_class": "small", "speed_class": "fast", "quality_tiers": ["draft", "standard", "best"],
            "supports": ["stream": true, "voices": 1, "default_voice": true, "seed": false, "sample_rate": 24000, "channels": 1],
            "limits": ["max_text_chars": 500]],
    voices: [["id": "tone-a", "title": "Tone A", "languages": ["en-US"], "tags": ["calm"]]])

/// The assets a plugin was told to forget.
final class Removed: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    func add(_ id: String) { lock.lock(); ids.append(id); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return ids }
}

func toneDefinition(removed: Removed? = nil) -> GaeaPluginDefinition {
    GaeaPluginDefinition(
        id: "com.xocialize.gaea.tone", version: "0.1.0", team: "CFZS6RXUCP",
        repo: "https://github.com/xocialize-code/gaea-plugin-tone", title: "Tone", license: "Apache-2.0",
        executable: "gaea-tone-worker", declaresEngine: false,
        models: [.custom(id: "tone", title: "Tone", manifest: demoPackageManifest,
                         lanes: [LaneDefinition(id: "fp32", default: true, configuration: Bundled())], make: { FakeTone() })],
        offers: [toneOffer],
        onAssetRemoved: { asset in removed?.add(asset) })
}

@Suite("Streamed outputs")
struct StreamTests {
    @Test func aStreamedRunSendsPCMChunksThenAStreamedResult() async throws {
        let removed = Removed()
        let definition = toneDefinition(removed: removed)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "gaea-stream-\(UUID().uuidString)")
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
        await send(#"{"type":"run","id":"h2","job":"job_s","operation":"audio.speak","model":"tone","lane":"fp32","inputs":{"text":"\#(tmp.path)/text.txt","voice_ref":"\#(tmp.path)/ref.wav"},"params":{"voice":"tone-a"},"streams":["audio"],"assets":{"text":[null],"voice_ref":"ast_123"},"output_dir":"\#(out)"}"#)
        var chunks: [JSONValue] = []
        var m = try await next()
        while m["type"] == "progress" { m = try await next() }
        while m["type"] == "chunk" {
            chunks.append(m)
            m = try await next()
        }
        #expect(m["type"] == "result", "\(m)")
        #expect(m["outputs"] == [["name": "audio", "streamed": true]])
        #expect(m["effective"]?["asset"] == "ast_123")
        #expect(try await next()["type"] == "memory")
        #expect(chunks.count == 3)
        for (i, chunk) in chunks.enumerated() {
            #expect(chunk["index"]?.intValue == i && chunk["output"] == "audio" && chunk["encoding"] == "pcm_f32le")
            #expect(chunk["sample_rate"] == 24000 && chunk["channels"] == 1)
            #expect((chunk["final"] == true) == (i == 2))
            let path = try #require(chunk["path"]?.stringValue)
            #expect(path.hasPrefix(out + "/"))
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)).count == FakeTone.chunk * 4)
        }

        await send(#"{"type":"asset_removed","id":"h3","asset":"ast_123"}"#)
        for _ in 0..<50 where removed.all.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(removed.all == ["ast_123"])
        // An unknown run field is still refused: the schema is closed.
        await worker.handle(line: #"{"type":"run","id":"h4","job":"job_t","operation":"audio.speak","model":"tone","lane":"fp32","inputs":{},"params":{},"stream":["audio"],"output_dir":"\#(out)"}"#)
        let refused = try Replay.parse(try #require(await lines.pop(timeout: .seconds(10))))
        #expect(refused["code"] == "invalid_request")

        let file = tmp.appending(path: "stream.gpp")
        try ("# manifest: \(manifest.path)\n" + session.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let (status, output) = try Spec.validate(["--transcript", file.path])
        #expect(status == 0, "\(output)\n\(session.joined(separator: "\n"))")
    }

    @Test func offerVoicesRoundTrip() throws {
        let back = try JSONDecoder().decode(PluginManifest.Offer.self, from: JSONEncoder().encode(toneOffer))
        #expect(back.voices?.first?["id"] == "tone-a")
        #expect(back.model["supports"]?["voices"] == 1)
    }
}
