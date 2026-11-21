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

    /// Today's 0.33 bits per pixel per frame is kept unless the upload would outgrow its budget (the size limit, and what a
    /// 2 Mbit/s uplink sends before the signed upload expires); then it is stepped down just enough. A 120 s 1080p60 window
    /// is ~1.5 GB at today's rate, over the 512 MiB limit; before, it uploaded and failed after the voice was paid.
    @Test func aLongHighRateWindowIsSteppedDownToFitItsUpload() throws {
        let size = PixelSize(width: 1920, height: 1080)
        let upload = LipsyncLimits.uploadSeconds(120)
        let long = LipsyncWindowPreparation.videoBitrate(size: size, fps: 60, uploadSeconds: upload)
        #expect(long.natural == Int((0.33 * 1920 * 1080 * 60).rounded()))
        #expect(long.bitrate < long.natural)
        #expect(Double(long.bitrate) * upload / 8 <= Double(LipsyncLimits.uploadBudgetBytes))
        // The step-down is the size check (preflight has no byte guard of its own): an upload stepped down to its budget
        // still fits the size limit with 2 % and 64 KB of container, and the 2 Mbit/s uplink sends it while its signed
        // upload outlives the job's deadline.
        let packed = Double(LipsyncLimits.uploadBudgetBytes) * 1.02 + 65_536
        #expect(packed <= Double(LipsyncLimits.maximumVideoBytes))
        #expect(packed / LipsyncLimits.assumedBytesPerSecond <= 3_600 - LipsyncLimits.deadlineSeconds - 120)
        for fps in [24.0, 30, 60] {
            for seconds in [3.0, 60, 120, 290] {
                let fitted = LipsyncWindowPreparation.videoBitrate(size: size, fps: fps, uploadSeconds: LipsyncLimits.uploadSeconds(seconds))
                #expect(Double(fitted.bitrate) * LipsyncLimits.uploadSeconds(seconds) / 8 <= Double(LipsyncLimits.uploadBudgetBytes))
            }
        }
        // A short phrase keeps today's quality.
        let short = LipsyncWindowPreparation.videoBitrate(size: size, fps: 30, uploadSeconds: LipsyncLimits.uploadSeconds(6))
        #expect(short.bitrate == short.natural)
        try LipsyncWindowPreparation.preflight(video: MediaVideo(width: 1920, height: 1080, frameRate: 60, rotationDegrees: 0), outputSeconds: 120)
        try LipsyncWindowPreparation.preflight(video: MediaVideo(width: 3840, height: 2160, frameRate: 29.97, rotationDegrees: 0), outputSeconds: 290)
    }

    /// The free checks a whole clip runs before paying for its voice: a source that can't be sent, or a voice outside the
    /// lip sync's 3 s to 5 min (its tail margin included), is refused on this Mac.
    @Test func preflightRefusesWhatTheLipSyncCannotTake() {
        #expect(throws: LipsyncPreparationError.unsupportedVideo) {
            try LipsyncWindowPreparation.preflight(video: MediaVideo(width: 1920, height: 1080, frameRate: 120, rotationDegrees: 0), outputSeconds: 20)
        }
        for seconds in [2.9, 295, Double.nan] {
            #expect(throws: LipsyncError.invalidInput) {
                try LipsyncWindowPreparation.preflight(video: MediaVideo(width: 1920, height: 1080, frameRate: 30, rotationDegrees: 0), outputSeconds: seconds)
            }
        }
    }
}
