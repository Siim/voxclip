import Foundation
import Testing
@testable import VoxClipCore
@testable import VoxClipMedia

/// The lip-sync window's upload size (voice-lab §9): the source as oriented, within the compositor's 1920-pixel bound.
@Suite struct LipsyncUploadSizeTests {
    @Test func aFourKSourceIsSentAtTheCompositorBound() throws {
        // MVP45: the user's DJI 4K clip was refused before upload, every Try Again.
        #expect(try LipsyncWindowPreparation.uploadSize(MediaVideo(width: 3840, height: 2160, frameRate: 29.97, rotationDegrees: 0))
                == PixelSize(width: 1920, height: 1080))
        #expect(try LipsyncWindowPreparation.uploadSize(MediaVideo(width: 3840, height: 2160, frameRate: 30, rotationDegrees: 90))
                == PixelSize(width: 1080, height: 1920))
    }

    @Test func aSourceWithinTheBoundKeepsItsSize() throws {
        #expect(try LipsyncWindowPreparation.uploadSize(MediaVideo(width: 1920, height: 1080, frameRate: 60, rotationDegrees: 0))
                == PixelSize(width: 1920, height: 1080))
        #expect(try LipsyncWindowPreparation.uploadSize(MediaVideo(width: 320, height: 180, frameRate: 30, rotationDegrees: 0))
                == PixelSize(width: 320, height: 180))
    }

    @Test func aRateOrSizeTheProviderCannotTakeIsRefused() {
        #expect(throws: LipsyncPreparationError.unsupportedVideo) {
            try LipsyncWindowPreparation.uploadSize(MediaVideo(width: 1920, height: 1080, frameRate: 120, rotationDegrees: 0))
        }
        #expect(throws: LipsyncPreparationError.unsupportedVideo) {
            try LipsyncWindowPreparation.uploadSize(MediaVideo(width: 8, height: 8, frameRate: 30, rotationDegrees: 0))
        }
    }
}
