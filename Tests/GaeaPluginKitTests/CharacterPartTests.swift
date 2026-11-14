import CoreGraphics
import Foundation
@testable import GaeaPluginKit
import GaeaProtocol
import ImageIO
import MLXToolKit
import Testing
import UniformTypeIdentifiers

/// MES `mesh.generate_part` as the engine's `CharacterPartRequest` (Gaea AB-T-0482, contract 1.63.0).
@Suite("Character parts")
struct CharacterPartTests {
    static func picture(_ width: Int, _ height: Int, type: UTType = .png) -> Data {
        let pixels = [UInt8](repeating: 200, count: width * height * 4)
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        _ = CGImageDestinationFinalize(dest)
        return data as Data
    }

    let body = Data("glTF-a-body".utf8)
    let box: JSONValue = ["x": 0.25, "y": 0.125, "width": 0.5, "height": 0.25]

    @Test func theRequestGaeaSendsBecomesTheEngines() throws {
        let params: [String: JSONValue] = ["subject_box": box, "part": "hair", "physics": true, "texture": "atlas",
                                           "background": "remove", "quality": "standard"]
        let mapped = try CharacterParts.request(image: Self.picture(640, 960), body: body, params: params, seed: 7)
        let r = mapped.request
        #expect(r.subjectBox == [160, 120, 480, 360])
        #expect(r.image?.format == .png && r.image?.width == 640 && r.image?.height == 960)
        #expect(r.body?.data == body && r.body?.format == .glb)
        #expect(r.part == .hair && r.seed == 7 && r.springBones == true && r.colors == true && r.pointCloud == nil)
        #expect(r.shapeProblem == nil)
        #expect(mapped.effective == ["subject_box": box, "part": "hair", "physics": true, "texture": "atlas", "seed": 7])
        #expect(!CharacterParts.isCutOut(params) && CharacterParts.isCutOut(["background": "alpha"]))
        // The declaration HairDeck makes admits it.
        let hairdeck = CharacterPartControls(parts: [.hair], inputs: [.image], features: [.subjectBox, .bodyFit, .springBones, .colors],
                                             requiresSubjectBox: true)
        #expect(hairdeck.refusal(for: r) == nil)
    }

    @Test func physicsAndTextureOff() throws {
        let mapped = try CharacterParts.request(image: Self.picture(64, 64, type: .jpeg), body: body,
                                                params: ["subject_box": box, "physics": false, "texture": "none"], seed: nil)
        #expect(mapped.request.springBones == false && mapped.request.colors == false && mapped.request.image?.format == .jpeg)
        #expect(mapped.request.part == nil && mapped.request.seed == nil)
        #expect(mapped.effective["texture"] == "none" && mapped.effective["seed"] == nil)
    }

    @Test func theBoxGrowsToWholePixelsInsideTheImage() throws {
        func px(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ width: Int = 100, _ height: Int = 50) throws -> [Float] {
            try CharacterParts.pixelBox(["x": .double(x), "y": .double(y), "width": .double(w), "height": .double(h)], width: width, height: height)
        }
        #expect(try px(0, 0, 1, 1) == [0, 0, 100, 50])
        #expect(try px(0.1, 0.2, 0.3, 0.4) == [10, 10, 40, 30], "exact shares stay exact")
        #expect(try px(0.105, 0.21, 0.29, 0.38) == [10, 10, 40, 30], "edges round outwards")
        #expect(try px(0.999, 0.999, 0.001, 0.001) == [99, 49, 100, 50], "at least a pixel, inside the image")
        #expect(try px(0.5, 0.5, 0.9, 0.9) == [50, 25, 100, 50], "a box past the edge is cut to the image")
        #expect(try px(1.0 / 3, 0, 1.0 / 3, 1, 3, 3) == [1, 0, 2, 3])
        for bad in [(0.1, 0.1, 0.0, 0.5), (-0.1, 0.1, 0.5, 0.5), (1.0, 0.1, 0.5, 0.5), (0.1, 0.1, Double.nan, 0.5)] {
            #expect(throws: GPPError.self) { try px(bad.0, bad.1, bad.2, bad.3) }
        }
        #expect(throws: GPPError.self) { try CharacterParts.pixelBox([10, 10, 40, 30], width: 100, height: 50) }
    }

    @Test func refusals() throws {
        #expect(throws: GPPError.self) { try CharacterParts.request(image: Data("not a picture".utf8), body: body, params: [:], seed: nil) }
        #expect(throws: GPPError.self) {
            try CharacterParts.request(image: Self.picture(8, 8, type: .tiff), body: body, params: [:], seed: nil)
        }
        #expect(throws: GPPError.self) {
            try CharacterParts.request(image: Self.picture(8, 8), body: body, params: ["texture": "vertex_colors"], seed: nil)
        }
    }

    @Test func theItemIsWrittenAsTheModelMadeIt() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "kit-part-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = Data("glTF-an-item".utf8)
        let outputs = try CharacterParts.outputs(CharacterPartResponse(mesh: Mesh(data: item), part: .hair, fittedToBody: true), outputDir: dir)
        #expect(outputs.count == 1)
        #expect(try Data(contentsOf: dir.appending(path: "mesh.glb")) == item)
        #expect(throws: GPPError.self) {
            try CharacterParts.outputs(CharacterPartResponse(mesh: Mesh(data: item), part: .hair, fittedToBody: false), outputDir: dir)
        }
    }
}
