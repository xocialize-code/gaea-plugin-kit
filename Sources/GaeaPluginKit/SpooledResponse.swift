import Foundation
import GaeaProtocol
import MLXToolKit

/// Turns an engine response into GPP outputs: the envelope is encoded with
/// `CapabilityWire.encoder(spool:)` aimed at the run's `output_dir`, so every artifact (image, audio,
/// matte, mesh, video) is written there as a file and the JSON carries its path. Each file becomes a
/// path output; every other top-level field becomes a value output.
enum SpooledResponse {
    /// `counts` carries the files already written per field across a job's calls, so a second
    /// call's `image` is `image-1`, not a second `image-0`.
    static func outputs(_ envelope: CapabilityResponseEnvelope, outputDir: URL,
                        names: [String: String], counts: inout [String: Int]) throws -> [Output] {
        let spool = ArtifactSpool(directory: outputDir)
        let data = try CapabilityWire.encoder(spool: spool).encode(envelope)
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let response = root["response"]?.objectValue else { return [] }

        var outputs: [Output] = []
        for key in response.keys.sorted() {
            let value = response[key]!
            let name = names[key] ?? snakeCase(key)
            var files: [(path: String, format: String?)] = []
            collectFiles(value, into: &files)
            if files.isEmpty {
                outputs.append(.value(name, value))
                continue
            }
            for file in files {
                // The spool names files by UUID; give them the field's name and their index.
                let index = counts[key, default: 0]
                counts[key] = index + 1
                let source = URL(fileURLWithPath: file.path)
                let target = outputDir.appending(path: "\(key)-\(index).\(source.pathExtension)")
                if source != target {
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: source, to: target)
                }
                outputs.append(.file(name, target, mediaType: mediaType(forExtension: source.pathExtension)))
            }
        }
        return outputs
    }

    /// Every `{"file": …}` artifact in a value, depth first.
    private static func collectFiles(_ value: JSONValue, into files: inout [(path: String, format: String?)]) {
        switch value {
        case .object(let o):
            if let path = o["file"]?.stringValue {
                files.append((path, o["format"]?.stringValue))
            } else {
                for key in o.keys.sorted() { collectFiles(o[key]!, into: &files) }
            }
        case .array(let a):
            for v in a { collectFiles(v, into: &files) }
        default:
            break
        }
    }

    static func mediaType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "wav": "audio/wav"
        case "mp3": "audio/mpeg"
        case "flac": "audio/flac"
        case "m4a", "aac": "audio/mp4"
        case "mp4": "video/mp4"
        case "mov": "video/quicktime"
        case "glb": "model/gltf-binary"
        case "obj": "model/obj"
        case "usdz": "model/vnd.usdz+zip"
        default: "application/octet-stream"
        }
    }

    static func snakeCase(_ key: String) -> String {
        var out = ""
        for ch in key {
            if ch.isUppercase {
                if !out.isEmpty { out.append("_") }
                out.append(Character(ch.lowercased()))
            } else {
                out.append(ch)
            }
        }
        return GPP.isName(out) ? out : GPP.stageName(out)
    }
}
