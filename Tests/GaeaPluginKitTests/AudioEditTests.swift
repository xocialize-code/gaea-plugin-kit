import Foundation
@testable import GaeaPluginKit
import GaeaProtocol
import MLXToolKit
import Testing

/// MES edit_speech and separate as the engine's requests (Audio §3.3, §3.6; RFC 0006).
@Suite("Audio edits")
struct AudioEditTests {
    let auk = SpeechEditVocabulary(
        emotions: ["happy": "happy", "afraid": "fearful", "calm": "calm"], styles: ["whisper": "whisper", "normal": "normal"],
        sounds: ["breath": "breath", "laugh": "laugh", "cough": "cough", "hum": "humming"],
        speedFactors: [0.5, 0.75, 1.25, 1.5, 2.0], pitchSemitones: [-3, -2, -1, 1, 2, 3], volumeDecibels: [-15, -10, -5, 5, 10, 15])

    func op(_ edit: JSONValue, transcript: String? = nil) throws -> MappedSpeechEdit {
        try SpeechEdits.operation(edit, vocabulary: auk, transcript: transcript)
    }

    @Test func everyKindMapsToItsOperation() throws {
        #expect(try op(["kind": "emotion", "emotion": "afraid"]).operation == .emotion("fearful"))
        #expect(try op(["kind": "style", "style": "whisper"]).operation == .style("whisper"))
        #expect(try op(["kind": "denoise"]).operation == .denoise)
        #expect(try op(["kind": "dereverb"]).operation == .dereverberate)
        #expect(try op(["kind": "trim_silence"]).operation == .trimSilence)
        #expect(try op(["kind": "de_accent"]).operation == .deAccent)
        #expect(try op(["kind": "timbre", "description": "a deep older voice"]).operation == .timbre(description: "a deep older voice"))
        #expect(try op(["kind": "replace_text", "text": "cat", "with": "dog"]).operation == .replaceWords(original: "cat", new: "dog"))
        #expect(try op(["kind": "insert_text", "text": "very", "anchor": "big", "position": "before"]).operation
            == .insertWords(text: "very", anchor: "big", before: true))
        #expect(try op(["kind": "remove_text", "text": "really"]).operation == .removeWords(text: "really", anchor: nil, before: false))
        #expect(try op(["kind": "add_cue", "cue": "hum", "at": "start"]).operation == .addNonverbal(sound: "humming", atEnd: false))
        #expect(try op(["kind": "remove_cue", "cue": "laugh"]).operation == .removeNonverbal(sound: "laugh"))
        #expect(try op(["kind": "remove_cue"]).operation == .removeNonverbal(sound: nil))
    }

    @Test func valuesSnapToTheGridWithAWarning() throws {
        let fast = try op(["kind": "speed", "factor": 1.4])
        #expect(fast.operation == .speed(factor: 1.5) && fast.warnings.map(\.code) == ["param_adjusted"])
        #expect(try op(["kind": "speed", "factor": 1.25]).warnings.isEmpty)
        #expect(try op(["kind": "pitch", "semitones": 5]).operation == .pitch(semitones: 3))
        #expect(try op(["kind": "volume", "gain_db": -6]).operation == .volume(dB: -5))
        let free = try SpeechEdits.operation(["kind": "speed", "factor": 1.4])
        #expect(free.operation == .speed(factor: 1.4) && free.warnings.isEmpty)
    }

    @Test func refusalsNameTheEdit() throws {
        #expect(throws: GPPError.self) { try op(["kind": "emotion", "emotion": "melancholic"]) }
        #expect(throws: GPPError.self) { try op(["kind": "timbre"]) }
        #expect(throws: GPPError.self) { try op(["kind": "add_cue", "cue": "laugh", "text": "Hi [laugh] there"]) }
        #expect(throws: GPPError.self) { try op(["kind": "add_cue", "cue": "sob", "at": "end"]) }
        #expect(throws: GPPError.self) { try op(["kind": "insert_text", "text": "a", "anchor": "b", "position": "inside"]) }
        #expect(throws: GPPError.self) { try op(["kind": "teleport"]) }
        #expect(throws: GPPError.self) { try SpeechEdits.operation(nil) }
    }

    @Test func contentEditsGiveTheNewTranscript() throws {
        let said = "The big cat sat on the mat."
        #expect(try op(["kind": "replace_text", "text": "cat", "with": "dog"], transcript: said).newTranscript == "The big dog sat on the mat.")
        #expect(try op(["kind": "insert_text", "text": "very", "anchor": "big", "position": "before"], transcript: said).newTranscript
            == "The very big cat sat on the mat.")
        #expect(try op(["kind": "remove_text", "text": "big"], transcript: said).newTranscript == "The cat sat on the mat.")
        #expect(try op(["kind": "add_cue", "cue": "laugh", "at": "end"], transcript: said).newTranscript == "The big cat sat on the mat. [laugh]")
        #expect(try op(["kind": "replace_text", "text": "cat", "with": "dog"]).newTranscript == nil)
    }

    @Test func aPluginCanAddCuesItsOwnWay() throws {
        let mapped = try SpeechEdits.operation(["kind": "add_cue", "cue": "laugh", "text": "Great [laugh] weather."]) { cue, placement in
            guard case .inline(let transcript) = placement else { throw GPPError(.invalidRequest, "inline only") }
            return MappedSpeechEdit(operation: .paralinguistic(targetTranscript: transcript.replacingOccurrences(of: "[\(cue)]", with: "[Laughter]")),
                                    newTranscript: transcript)
        }
        #expect(mapped.operation == .paralinguistic(targetTranscript: "Great [Laughter] weather.") && mapped.newTranscript == "Great [laugh] weather.")
    }

    @Test func separationRequestsAndOutputs() throws {
        let r = try AudioSeparations.request(mixture: Data([1, 2]), params: ["stems": ["speaker", "singing"], "speaker": ["saying": "hello there"]],
                                             metaData: ["seed": .int(4)])
        #expect(r.stems == ["speaker", "singing"] && r.speaker == .saying("hello there") && r.metaData["seed"] == .int(4))
        #expect(try AudioSeparations.request(mixture: Data(), params: ["stems": ["speaker"], "speaker": ["ordinal": 2]]).speaker == .ordinal(2))
        #expect(throws: GPPError.self) { try AudioSeparations.request(mixture: Data(), params: ["stems": ["speaker"]]) }
        #expect(throws: GPPError.self) { try AudioSeparations.request(mixture: Data(), params: [:]) }
        #expect(throws: GPPError.self) { try AudioSeparations.request(mixture: Data(), params: ["stems": ["speaker"], "speaker": ["ordinal": 0]]) }

        let dir = FileManager.default.temporaryDirectory.appending(path: "kit-separate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let response = AudioSeparationResponse(stems: ["singing": Audio(format: .wav, data: Data([9]), sampleRate: 24000, channels: 1),
                                                       "speaker": Audio(format: .wav, data: Data([8]), sampleRate: 24000, channels: 1)])
        let outputs = try AudioSeparations.outputs(response, stems: ["speaker", "singing"], outputDir: dir)
        #expect(outputs.map(\.json).compactMap { $0["name"]?.stringValue } == ["speaker", "singing"])
        #expect(try Data(contentsOf: dir.appending(path: "speaker.wav")) == Data([8]))
        #expect(throws: GPPError.self) { try AudioSeparations.outputs(response, stems: ["voices"], outputDir: dir) }
    }

    /// A 16-bit mono WAV of `frames` frames at `rate`, every sample `value`.
    func wav(frames: Int, rate: Int, value: Int16 = 1000) -> Data {
        var d = Data("RIFF".utf8)
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        u32(36 + frames * 2); d.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(frames * 2)
        for _ in 0..<frames { withUnsafeBytes(of: value.littleEndian) { d.append(contentsOf: $0) } }
        return d
    }

    /// AuK's 20 ms frames: a 5.553375 s mixture separated into 5.54 s stems (AB-T-0455). Each stem is fitted to the
    /// mixture's length at its own rate; one far off is the model's error.
    @Test func stemsAreTheMixturesLength() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "kit-fit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mixture = wav(frames: 133_281, rate: 24000)
        func stem(_ frames: Int, rate: Int = 24000) -> Audio { Audio(format: .wav, data: wav(frames: frames, rate: rate), sampleRate: rate, channels: 1) }
        let response = AudioSeparationResponse(stems: ["speaker": stem(132_960), "singing": stem(133_300), "voices": stem(266_562, rate: 48000)])
        _ = try AudioSeparations.outputs(response, stems: ["speaker", "singing", "voices"], mixture: mixture, outputDir: dir)
        for (name, frames) in [("speaker", 133_281), ("singing", 133_281), ("voices", 266_562)] {
            let out = try #require(PCMWave(Data(contentsOf: dir.appending(path: "\(name).wav"))))
            #expect(out.frames == frames, "\(name)")
        }
        let speaker = try #require(PCMWave(Data(contentsOf: dir.appending(path: "speaker.wav"))))
        let samples = speaker.data[speaker.dataStart...]
        #expect(samples.prefix(2) == Data([0xE8, 0x03]) && samples.suffix(2) == Data([0, 0]))  // kept, then silence
        #expect(speaker.data.count == 44 + 133_281 * 2)
        let short = AudioSeparationResponse(stems: ["speaker": stem(96_000)])
        #expect(throws: GPPError.self) { try AudioSeparations.outputs(short, stems: ["speaker"], mixture: mixture, outputDir: dir) }
        // Without the mixture a stem is written as it came.
        _ = try AudioSeparations.outputs(short, stems: ["speaker"], outputDir: dir)
        #expect(PCMWave(try Data(contentsOf: dir.appending(path: "speaker.wav")))?.frames == 96_000)
    }
}
