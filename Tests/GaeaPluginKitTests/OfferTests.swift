import Foundation
import GaeaProtocol
import Testing

@Suite("Offer fields")
struct OfferTests {
    @Test func decomposeLimitsAndSupports() throws {
        let offer = PluginManifest.Offer(operation: "image.decompose", profile: "image", model: ["id": "layers"],
                                         limits: PluginManifest.Limits(maxLayerCount: 12), supports: ["composite": true])
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(offer)) as? [String: Any])
        #expect((json["limits"] as? [String: Any])?["max_layer_count"] as? Int == 12)
        #expect((json["supports"] as? [String: Bool]) == ["composite": true])
        let back = try JSONDecoder().decode(PluginManifest.Offer.self, from: JSONEncoder().encode(offer))
        #expect(back.limits?.maxLayerCount == 12 && back.supports == ["composite": true])
    }

    @Test func absentFieldsStayAbsent() throws {
        let offer = PluginManifest.Offer(operation: "image.generate", profile: "image", model: ["id": "m"])
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(offer)) as? [String: Any])
        #expect(json["supports"] == nil)
    }
}
