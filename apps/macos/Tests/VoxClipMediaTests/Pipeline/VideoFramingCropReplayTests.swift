import CoreGraphics
import Foundation
import Testing
@testable import VoxClipMedia

/// Shared changed-duration crop vectors (video-framing-cases.json): the compositor's aspect crop and the zoomed face crop
/// for Match video (1.12×) and cut punch-ins (1.06×). The vectors use top-left coordinates; Core Image's are bottom-left.
@Suite struct VideoFramingCropReplayTests {
    private struct Document: Decodable {
        struct CropCase: Decodable {
            let id: String
            let source: [Int]
            let output: [Int]
            let zoom: Double
            let faceX: Double
            let faceY: Double
            let aspectCrop: [Double]
            let crop: [Double]
        }
        let schema: String
        let cropCaseCount: Int
        let cropCases: [CropCase]
    }

    @Test func cropRectanglesMatchTheSharedVectors() throws {
        let fixture = try FixtureLoader.decode(Document.self, at: "fixtures/voice-lab/video-framing-cases.json")
        #expect(fixture.schema == "voxclip-video-framing/1")
        #expect(fixture.cropCaseCount == fixture.cropCases.count && fixture.cropCases.count == 5)
        for row in fixture.cropCases {
            let source = CGRect(x: 0, y: 0, width: Double(row.source[0]), height: Double(row.source[1]))
            let aspect = FrameCompositor.centerCrop(source: source,
                output: CGSize(width: Double(row.output[0]), height: Double(row.output[1])))
            let crop = CompositionFrameGeometry.faceCrop(in: source, aspectCrop: aspect, scale: row.zoom,
                faceX: row.faceX, faceY: row.faceY)
            for (actual, expected) in [(aspect, row.aspectCrop), (crop, row.crop)] {
                let topLeft: [Double] = [actual.minX, source.height - actual.maxY, actual.width, actual.height]
                #expect(zip(topLeft, expected).allSatisfy { abs($0 - $1) <= 1e-9 }, "\(row.id): \(topLeft) vs \(expected)")
            }
        }
    }
}
