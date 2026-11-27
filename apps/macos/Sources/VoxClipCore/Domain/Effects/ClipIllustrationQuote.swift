import Foundation

public struct ClipIllustrationQuote: Decodable, Sendable {
    public let endpoint: URL
    public let size: Int
    public let usdPerImage: Decimal
    public var price: String { "$" + NSDecimalNumber(decimal: usdPerImage).stringValue }

    public static func load(shared: SharedResources) throws -> Self {
        let url = shared.root.appendingPathComponent("data/clip-illustration.json")
        let quote = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard quote.endpoint.absoluteString == "https://fal.run/fal-ai/flux/schnell", quote.size == 768,
              quote.usdPerImage > 0, quote.usdPerImage <= Decimal(string: "0.01")! else { throw ClipEffectError.invalidEntry("illustration quote") }
        return quote
    }
}
