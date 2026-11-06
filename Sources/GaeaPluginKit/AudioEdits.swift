import Foundation
import GaeaProtocol
import MLXToolKit

// MES Audio's `edit_speech` and `separate` (Audio §3.3, §3.6; media-engine-spec v0.10.0, RFC 0006) as the engine's
// canonical requests, for every plugin that wraps a speech editor or a separator (Gaea G5 order 4). MESKit has already
// gated the request by the offer's `supports` (the kinds, labels, cues, placements, stems and picks it lists); this maps
// what is left, the plugin's own vocabulary, and snaps values to the package's grids (§1.9).

/// What one speech-edit model calls the MES labels, and the grids it takes values on. An empty map passes labels as
/// they are; an empty grid takes any value.
public struct SpeechEditVocabulary: Sendable {
    /// MES emotion label → the package's.
    public var emotions: [String: String]
    /// MES style label → the package's.
    public var styles: [String: String]
    /// MES cue → the package's nonverbal sound, for edge cues (`addNonverbal`) and `remove_cue`.
    public var sounds: [String: String]
    public var speedFactors: [Double]
    public var pitchSemitones: [Int]
    public var volumeDecibels: [Int]

    public init(emotions: [String: String] = [:], styles: [String: String] = [:], sounds: [String: String] = [:],
                speedFactors: [Double] = [], pitchSemitones: [Int] = [], volumeDecibels: [Int] = []) {
        self.emotions = emotions; self.styles = styles; self.sounds = sounds
        self.speedFactors = speedFactors; self.pitchSemitones = pitchSemitones; self.volumeDecibels = volumeDecibels
    }
}

/// Where an `add_cue` edit puts its cue (Audio §3.3, RFC 0006 `cue_placement`).
public enum CuePlacement: Sendable, Equatable {
    /// At the take's start, or its end.
    case edge(atEnd: Bool)
    /// Inline: the take's transcript with the cue where it goes.
    case inline(transcript: String)
}

/// An MES edit as the engine's operation, with the warnings mapping it gave (a value snapped to a grid) and the take's
/// new transcript when the plugin can tell it.
public struct MappedSpeechEdit: Sendable {
    public var operation: SpeechEditOperation
    public var warnings: [Warning]
    public var newTranscript: String?

    public init(operation: SpeechEditOperation, warnings: [Warning] = [], newTranscript: String? = nil) {
        self.operation = operation; self.warnings = warnings; self.newTranscript = newTranscript
    }
}

public enum SpeechEdits {
    /// A request's refusal of its edit, as GPP's `invalid_request` naming `edit` (MESKit gates most before the run).
    public static func refusal(_ message: String, param: String = "edit", mesCode: String? = nil) -> GPPError {
        var detail: [String: JSONValue] = ["param": .string(param)]
        if let mesCode { detail["mes_code"] = .string(mesCode) }
        return GPPError(.invalidRequest, message, detail: detail)
    }

    /// The engine operation for an MES `edit` (§3.3). `addCue` makes an `add_cue` the model's own way; without it an
    /// edge cue is `addNonverbal` of the vocabulary's sound, and an inline one is refused. `transcript` is the take's,
    /// for the new transcript of a content edit.
    public static func operation(
        _ edit: JSONValue?, vocabulary: SpeechEditVocabulary = .init(), transcript: String? = nil,
        addCue: ((_ cue: String, _ placement: CuePlacement) throws -> MappedSpeechEdit)? = nil
    ) throws -> MappedSpeechEdit {
        guard let edit, let kind = edit["kind"]?.stringValue else { throw refusal("audio.edit_speech needs an edit with its kind.") }
        func field(_ name: String) throws -> String {
            guard let value = edit[name]?.stringValue, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw refusal("A \(kind) edit needs \(name).")
            }
            return value
        }
        func label(_ value: String, in map: [String: String], what: String) throws -> String {
            if map.isEmpty { return value }
            guard let mapped = map[value] else { throw refusal("This model has no \(what) \(value).", mesCode: "unsupported_parameter") }
            return mapped
        }
        let said = transcript?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        switch kind {
        case "emotion":
            return MappedSpeechEdit(operation: .emotion(try label(try field("emotion"), in: vocabulary.emotions, what: "emotion")))
        case "style":
            return MappedSpeechEdit(operation: .style(try label(try field("style"), in: vocabulary.styles, what: "style")))
        case "denoise": return MappedSpeechEdit(operation: .denoise)
        case "dereverb": return MappedSpeechEdit(operation: .dereverberate)
        case "trim_silence": return MappedSpeechEdit(operation: .trimSilence)
        case "de_accent": return MappedSpeechEdit(operation: .deAccent)
        case "timbre": return MappedSpeechEdit(operation: .timbre(description: try field("description")))
        case "replace_text":
            let original = try field("text"), new = try field("with")
            return MappedSpeechEdit(operation: .replaceWords(original: original, new: new),
                                    newTranscript: said.flatMap { replacing(original, with: new, in: $0) })
        case "insert_text":
            let text = try field("text"), anchor = try field("anchor")
            let position = edit["position"]?.stringValue ?? "after"
            guard ["before", "after"].contains(position) else { throw refusal("An insert_text edit's position is before or after.") }
            let before = position == "before"
            return MappedSpeechEdit(operation: .insertWords(text: text, anchor: anchor, before: before),
                                    newTranscript: said.flatMap { inserting(text, at: anchor, before: before, in: $0) })
        case "remove_text":
            let text = try field("text")
            return MappedSpeechEdit(operation: .removeWords(text: text, anchor: nil, before: false),
                                    newTranscript: said.flatMap { replacing(text, with: "", in: $0) })
        case "speed":
            guard let factor = edit["factor"]?.doubleValue, factor > 0 else { throw refusal("A speed edit needs a factor above 0.") }
            let (snapped, warning) = snap(factor, to: vocabulary.speedFactors, field: "factor")
            return MappedSpeechEdit(operation: .speed(factor: snapped), warnings: warning.map { [$0] } ?? [])
        case "pitch":
            guard let semitones = edit["semitones"]?.doubleValue else { throw refusal("A pitch edit needs semitones.") }
            let (snapped, warning) = snap(semitones, to: vocabulary.pitchSemitones.map(Double.init), field: "semitones")
            return MappedSpeechEdit(operation: .pitch(semitones: Int(snapped.rounded())), warnings: warning.map { [$0] } ?? [])
        case "volume":
            guard let gain = edit["gain_db"]?.doubleValue else { throw refusal("A volume edit needs gain_db.") }
            let (snapped, warning) = snap(gain, to: vocabulary.volumeDecibels.map(Double.init), field: "gain_db")
            return MappedSpeechEdit(operation: .volume(dB: Int(snapped.rounded())), warnings: warning.map { [$0] } ?? [])
        case "add_cue":
            let cue = try field("cue")
            let placement: CuePlacement
            if let inline = edit["text"]?.stringValue {
                placement = .inline(transcript: inline)
            } else {
                let at = edit["at"]?.stringValue ?? "end"
                guard ["start", "end"].contains(at) else { throw refusal("An add_cue edit's at is start or end.") }
                placement = .edge(atEnd: at == "end")
            }
            if let addCue { return try addCue(cue, placement) }
            guard case .edge(let atEnd) = placement else {
                throw refusal("This model adds a cue at the start or the end only.", mesCode: "unsupported_parameter")
            }
            let sound = try label(cue, in: vocabulary.sounds, what: "cue")
            return MappedSpeechEdit(operation: .addNonverbal(sound: sound, atEnd: atEnd),
                                    newTranscript: said.map { atEnd ? "\($0) [\(cue)]" : "[\(cue)] \($0)" })
        case "remove_cue":
            let cue = edit["cue"]?.stringValue
            return MappedSpeechEdit(operation: .removeNonverbal(sound: try cue.map { try label($0, in: vocabulary.sounds, what: "cue") }))
        default:
            throw refusal("This model doesn't make \(kind) edits.", mesCode: "unsupported_parameter")
        }
    }

    /// `value` snapped to the nearest step of `grid` (Audio §1.9), with `param_adjusted` when it moved. An empty grid
    /// takes the value as it is.
    public static func snap(_ value: Double, to grid: [Double], field: String) -> (Double, Warning?) {
        guard let nearest = grid.min(by: { abs($0 - value) < abs($1 - value) }), abs(nearest - value) > 1e-9 else { return (value, nil) }
        return (nearest, Warning(code: "param_adjusted", message: "The edit's \(field) \(format(value)) is \(format(nearest)), the model's nearest step.",
                                 param: "edit"))
    }

    static func format(_ value: Double) -> String { value == value.rounded() ? String(Int(value)) : String(value) }

    /// The transcript with the first occurrence of `text` replaced (removed when `with` is empty), or nil when it isn't
    /// there. Spaces around a removal collapse to one.
    static func replacing(_ text: String, with new: String, in transcript: String) -> String? {
        guard let range = transcript.range(of: text) else { return nil }
        var out = transcript.replacingCharacters(in: range, with: new)
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// The transcript with `text` before or after the first occurrence of `anchor`, or nil when the anchor isn't there.
    static func inserting(_ text: String, at anchor: String, before: Bool, in transcript: String) -> String? {
        guard let range = transcript.range(of: anchor) else { return nil }
        return before ? transcript.replacingCharacters(in: range, with: "\(text) \(anchor)")
            : transcript.replacingCharacters(in: range, with: "\(anchor) \(text)")
    }
}

// MARK: - Separation

public enum AudioSeparations {
    /// The engine request for a `separate` job (§3.6): the mixture, the stems Gaea's plan names (`params.stems`), and the
    /// speaker pick.
    public static func request(mixture: Data, params: [String: JSONValue], metaData: MetaData = [:]) throws -> AudioSeparationRequest {
        let stems = params["stems"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard !stems.isEmpty else { throw SpeechEdits.refusal("audio.separate needs at least one stem.", param: "stems") }
        var pick: SpeakerSelection?
        if let speaker = params["speaker"] {
            if let n = speaker["ordinal"]?.intValue {
                guard n >= 1 else { throw SpeechEdits.refusal("speaker.ordinal is 1 or more.", param: "speaker") }
                pick = .ordinal(n)
            } else if let words = speaker["saying"]?.stringValue, !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pick = .saying(words)
            } else {
                throw SpeechEdits.refusal("speaker is {ordinal: n} or {saying: text}.", param: "speaker")
            }
        }
        if stems.contains("speaker"), pick == nil {
            throw SpeechEdits.refusal("The speaker stem needs a speaker pick.", param: "speaker")
        }
        return AudioSeparationRequest(audio: Audio(format: .wav, data: mixture, sampleRate: nil, channels: nil),
                                      stems: stems.map { Stem(rawValue: $0) }, speaker: pick, metaData: metaData)
    }

    /// The response's stems as the job's outputs, one WAV each named by its stem, in the order asked (§3.6). A stem the
    /// package didn't return is the model's error.
    public static func outputs(_ response: AudioSeparationResponse, stems: [String], outputDir: URL) throws -> [Output] {
        try stems.map { stem in
            guard let audio = response.stems[Stem(rawValue: stem)] else {
                throw GPPError(.modelError, "The model returned no \(stem) stem.")
            }
            let url = outputDir.appending(path: "\(stem).wav")
            try audio.data.write(to: url)
            return .file(stem, url, mediaType: "audio/wav")
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
