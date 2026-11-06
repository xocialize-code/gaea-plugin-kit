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
}
