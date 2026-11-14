import Foundation
import GaeaProtocol
import ImageIO
import MLXToolKit

// MES Mesh's `mesh.generate_part` (a part made to fit a body: Gaea AB-T-0482, asked of MES in AB-A-0280) as the engine's
// `CharacterPartRequest` (contract 1.63.0, mlx-engine-swift 0.78.0), for every plugin that wraps a character-part
// package (HairDeck first). What Gaea has done before the run (GPP-1 §3.3.4): checked `subject_box`, made the image
// upright (a PNG or JPEG), checked the body is a GLB, and set `params.background`, `part`, `physics` and `texture`.

/// A `mesh.generate_part` job as the engine's request, with what to report as `effective`.
public struct MappedCharacterPart: Sendable {
    public var request: CharacterPartRequest
    /// `part`, `physics`, `texture`, the box as the client wrote it, and the seed when the job has one.
    public var effective: [String: JSONValue]
    /// The box in pixels of the image the worker received, `[x0, y0, x1, y1]`, when the request has one.
    public var pixelBox: [Float]? { request.subjectBox }
}

public enum CharacterParts {
    public static let operation = "mesh.generate_part"

    /// Whether the picture is already cut out (`params.background` is `alpha`): its alpha is the matte. Otherwise it is
    /// `remove`: the picture is opaque, and the model cuts the character out itself (a companion matting model).
    public static func isCutOut(_ params: [String: JSONValue]) -> Bool { params["background"]?.stringValue == "alpha" }

    /// The engine request for a job: `inputs.image` and `inputs.body` read from their files.
    public static func request(_ job: Job, metaData: MetaData = [:]) throws -> MappedCharacterPart {
        guard let image = job.input("image") else { throw refusal("mesh.generate_part needs the picture.", param: "image") }
        return try request(image: Data(contentsOf: image), body: job.input("body").map { try Data(contentsOf: $0) },
                           params: job.params, seed: job.seed, metaData: metaData)
    }

    /// The engine request from the picture's bytes, the body's and the job's params.
    ///
    /// - `subject_box` `{x, y, width, height}` (shares of the upright image, origin top-left) becomes `[x0, y0, x1, y1]`
    ///   in the image's own pixels, grown to whole pixels and kept inside the image.
    /// - `body` becomes a `Mesh` (a GLB; a `.vrm` is one), `part` the part's tag, `physics` `springBones`, and
    ///   `texture` `colors` (`atlas` true, `none` false).
    public static func request(image: Data, body: Data?, params: [String: JSONValue], seed: UInt64?,
                               metaData: MetaData = [:]) throws -> MappedCharacterPart {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw refusal("The picture isn't an image this model can read.", param: "image")
        }
        let format: Image.Format
        if image.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            format = .png
        } else if image.starts(with: [0xFF, 0xD8]) {
            format = .jpeg
        } else {
            throw refusal("The picture reaches a worker as a PNG or JPEG (GPP-1 §3.3.4).", param: "image")
        }
        var effective: [String: JSONValue] = [:]
        var box: [Float]?
        if let asked = params["subject_box"] {
            box = try pixelBox(asked, width: width, height: height)
            effective["subject_box"] = asked
        }
        var colors: Bool?
        if let texture = params["texture"]?.stringValue {
            switch texture {
            case "atlas": colors = true
            case "none": colors = false
            default: throw refusal("texture is atlas or none for a part.", param: "texture")
            }
            effective["texture"] = .string(texture)
        }
        let part = params["part"]?.stringValue
        if let part { effective["part"] = .string(part) }
        let physics = params["physics"]?.boolValue
        if let physics { effective["physics"] = .bool(physics) }
        if let seed { effective["seed"] = .int(Int64(clamping: seed)) }
        let request = CharacterPartRequest(
            image: Image(format: format, data: image, width: width, height: height), subjectBox: box,
            body: body.map { Mesh(data: $0) }, part: part.map { CharacterPartKind(rawValue: $0) }, seed: seed,
            springBones: physics, colors: colors, metaData: metaData)
        if let problem = request.shapeProblem { throw refusal(problem, param: "subject_box") }
        return MappedCharacterPart(request: request, effective: effective)
    }

    /// A normalized box as `[x0, y0, x1, y1]` in pixels of a `width` × `height` image: the left and top edges rounded
    /// down, the right and bottom up, all kept inside the image, and at least one pixel each way.
    public static func pixelBox(_ box: JSONValue, width: Int, height: Int) throws -> [Float] {
        guard let x = box["x"]?.doubleValue, let y = box["y"]?.doubleValue,
              let w = box["width"]?.doubleValue, let h = box["height"]?.doubleValue,
              [x, y, w, h].allSatisfy(\.isFinite), w > 0, h > 0, x >= 0, y >= 0, x < 1, y < 1 else {
            throw refusal("subject_box is {x, y, width, height}, shares of the image from its top-left corner, with some area.",
                          param: "subject_box")
        }
        let (fw, fh) = (Double(width), Double(height))
        let x0 = min((x * fw + 1e-6).rounded(.down), fw - 1), y0 = min((y * fh + 1e-6).rounded(.down), fh - 1)
        let x1 = max(x0 + 1, min(((x + w) * fw - 1e-6).rounded(.up), fw)), y1 = max(y0 + 1, min(((y + h) * fh - 1e-6).rounded(.up), fh))
        return [Float(x0), Float(y0), Float(x1), Float(y1)]
    }

    /// The response's item as the job's `mesh` output, written as the model made it: Gaea stamps and previews it and
    /// never moves it. A part that wasn't fitted to the body it was given is the model's error.
    public static func outputs(_ response: CharacterPartResponse, hadBody: Bool = true, outputDir: URL) throws -> [Output] {
        if hadBody, !response.fittedToBody {
            throw GPPError(.modelError, "The model returned a part it didn't fit to the body.")
        }
        let url = outputDir.appending(path: "mesh.glb")
        try response.mesh.data.write(to: url)
        return [.file("mesh", url, mediaType: "model/gltf-binary")]
    }

    static func refusal(_ message: String, param: String) -> GPPError { SpeechEdits.refusal(message, param: param) }
}
