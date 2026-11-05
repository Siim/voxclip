#if DEBUG
import AppKit
import SwiftUI
@testable import VoxClip

/// Offscreen PNGs for a package's review, written only when `VOXCLIP_REVIEW_CAPTURES` names a folder: the tests that set up
/// a state draw it as it is (dark appearance, the window background), so nothing is staged for the picture alone.
@MainActor enum ReviewCaptures {
    static var folder: URL? {
        ProcessInfo.processInfo.environment["VOXCLIP_REVIEW_CAPTURES"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func capture(_ view: some View, name: String, size: CGSize) async throws {
        guard let folder else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .top)
            .background(DesignValues.color("bg.window")))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(origin: .zero, size: size)
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); await Task.yield() }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
    }

    static func write(_ image: CGImage, name: String) throws {
        guard let folder else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
    }
}
#endif
