import CryptoKit
import Darwin
import Foundation
import VoxClipCore

/// The native exporter owns publication. This value contains a new staged MP4 and sidecar bytes only.
public struct VoiceLabStagedDisclosure: Sendable {
    public let mp4URL: URL
    public let sidecarFilename: String
    public let sidecarData: Data
    public let sha256: String
}

/// Writes the standard ISO BMFF XMP UUID after native muxing, then hashes the final staged MP4.
public enum VoiceLabDisclosureWriter {
    public static let digitalSourceType = "http://cv.iptc.org/newscodes/digitalsourcetype/compositeWithTrainedAlgorithmicMedia"
    private static let xmpUUID: [UInt8] = [0xbe, 0x7a, 0xcf, 0xcb, 0x97, 0xa9, 0x42, 0xe8,
                                           0x9c, 0x71, 0x99, 0x94, 0x91, 0xe3, 0xaf, 0xac]

    public static func xmpPacket() -> Data {
        Data("""
        <?xpacket begin="\u{feff}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:Iptc4xmpExt="http://iptc.org/std/Iptc4xmpExt/2008-02-29/" Iptc4xmpExt:DigitalSourceType="\(digitalSourceType)"/></rdf:RDF></x:xmpmeta>
        <?xpacket end="w"?>
        """.utf8)
    }

    /// The caller supplies its actual app version and final export file name, then transactionally publishes both returned artifacts.
    public static func stage(sourceMP4: URL, stagedMP4: URL, finalFilename: String,
                             project: Project, prepared: VoiceLabPreparedRender, appVersion: String,
                             createdAt: Date = Date()) throws -> VoiceLabStagedDisclosure {
        try stage(sourceMP4: sourceMP4, stagedMP4: stagedMP4, finalFilename: finalFilename, project: project,
                  prepared: prepared, appVersion: appVersion, createdAt: createdAt, afterCopy: nil)
    }

    static func stage(sourceMP4: URL, stagedMP4: URL, finalFilename: String,
                      project: Project, prepared: VoiceLabPreparedRender, appVersion: String,
                      createdAt: Date, afterCopy: ((URL) throws -> Void)?) throws -> VoiceLabStagedDisclosure {
        try prepared.verify(project: project, scope: prepared.outputPlan.scope, labelPosition: prepared.disclosure.position)
        guard prepared.disclosure.required, !prepared.selectedSegmentRecipes.isEmpty,
              !appVersion.isEmpty, !appVersion.contains("/"), !appVersion.contains("\\"),
              finalFilename.lowercased().hasSuffix(".mp4"), !finalFilename.contains("\\"),
              finalFilename == URL(fileURLWithPath: finalFilename).lastPathComponent,
              sourceMP4.standardizedFileURL != stagedMP4.standardizedFileURL else { throw VoiceLabDisclosureError.invalidMP4 }
        guard !FileManager.default.fileExists(atPath: stagedMP4.path) else { throw VoiceLabDisclosureError.destinationExists }
        let parent = open(stagedMP4.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw VoiceLabDisclosureError.invalidMP4 }
        defer { close(parent) }
        let operation = try VoiceLabAssetRecovery.Operation(parent: parent)
        defer { operation.discard() }
        do {
            let input = try FileHandle(forReadingFrom: sourceMP4)
            defer { try? input.close() }
            try validateMP4(input)
            try input.seek(toOffset: 0)
            let descriptor = openat(operation.descriptor, "marked.mp4", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else {
                if errno == EEXIST { throw VoiceLabDisclosureError.destinationExists }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? output.close() }
            var hash = SHA256()
            while true {
                try Task.checkCancellation()
                let block = try input.read(upToCount: 1_048_576) ?? Data()
                if block.isEmpty { break }
                try output.write(contentsOf: block)
                hash.update(data: block)
            }
            let packet = xmpPacket()
            var box = Data()
            let length = UInt32(8 + 16 + packet.count)
            box.append(contentsOf: withUnsafeBytes(of: length.bigEndian, Array.init))
            box.append(contentsOf: "uuid".utf8)
            box.append(contentsOf: xmpUUID)
            box.append(packet)
            try output.write(contentsOf: box)
            hash.update(data: box)
            try output.synchronize()
            try Task.checkCancellation()
            try afterCopy?(stagedMP4.deletingLastPathComponent().appendingPathComponent(operation.name))
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            let sidecar = try sidecar(project: project, prepared: prepared, filename: finalFilename,
                                      hash: digest, appVersion: appVersion, createdAt: createdAt)
            guard renameatx_np(operation.descriptor, "marked.mp4", parent, stagedMP4.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw VoiceLabDisclosureError.destinationExists }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return VoiceLabStagedDisclosure(mp4URL: stagedMP4,
                sidecarFilename: finalFilename + ".provenance.json", sidecarData: sidecar, sha256: digest)
        }
    }

    private static func validateMP4(_ file: FileHandle) throws {
        let length = try file.seekToEnd()
        func scan(_ start: UInt64, _ end: UInt64, depth: Int) throws -> Set<String> {
            guard depth <= 4 else { throw VoiceLabDisclosureError.invalidMP4 }
            var cursor = start
            var kinds = Set<String>()
            while cursor < end {
                guard end - cursor >= 8 else { throw VoiceLabDisclosureError.invalidMP4 }
                try file.seek(toOffset: cursor)
                let header = try file.read(upToCount: 16) ?? Data()
                guard header.count >= 8 else { throw VoiceLabDisclosureError.invalidMP4 }
                let size32 = header.prefix(4).reduce(UInt64(0)) { $0 * 256 + UInt64($1) }
                let kind = String(decoding: header[4..<8], as: UTF8.self)
                // Size zero extends to EOF. Appending would hide the new UUID inside that box.
                guard size32 != 0 else { throw VoiceLabDisclosureError.invalidMP4 }
                let headerSize: UInt64 = size32 == 1 ? 16 : 8
                guard header.count >= Int(headerSize) else { throw VoiceLabDisclosureError.invalidMP4 }
                let boxSize = size32 == 1 ? header[8..<16].reduce(UInt64(0)) { $0 * 256 + UInt64($1) } : size32
                guard boxSize >= headerSize, boxSize <= end - cursor else {
                    throw VoiceLabDisclosureError.invalidMP4
                }
                if kind == "XMP_" { throw VoiceLabDisclosureError.existingXMP }
                if kind == "uuid" {
                    guard boxSize >= headerSize + 16 else { throw VoiceLabDisclosureError.invalidMP4 }
                    try file.seek(toOffset: cursor + headerSize)
                    if Array(try file.read(upToCount: 16) ?? Data()) == xmpUUID { throw VoiceLabDisclosureError.existingXMP }
                }
                if kind == "moov" || kind == "udta" || kind == "meta" {
                    let extra: UInt64 = kind == "meta" ? 4 : 0
                    guard boxSize >= headerSize + extra else { throw VoiceLabDisclosureError.invalidMP4 }
                    _ = try scan(cursor + headerSize + extra, cursor + boxSize, depth: depth + 1)
                }
                kinds.insert(kind)
                cursor += boxSize
            }
            return kinds
        }
        let found = try scan(0, length, depth: 0)
        guard found.isSuperset(of: ["ftyp", "moov", "mdat"]) else { throw VoiceLabDisclosureError.invalidMP4 }
    }

    private static func sidecar(project: Project, prepared: VoiceLabPreparedRender, filename: String,
                                hash: String, appVersion: String, createdAt: Date) throws -> Data {
        func timestamp(_ date: Date) throws -> String {
            guard let text = UTCTimestamp.string(from: date) else {
                throw EncodingError.invalidValue(date, EncodingError.Context(codingPath: [], debugDescription: "Timestamp outside years 0001-9999"))
            }
            return text
        }
        var segments: [[String: Any]] = []
        var consent: [[String: Any]] = []
        for selected in prepared.selectedSegmentRecipes {
            guard let segment = project.voiceLab.segments.first(where: { $0.id == selected.segmentId }),
                  let asset = project.voiceLab.assets?.first(where: { $0.id == selected.recipe.audio.assetId }) else {
                throw VoiceLabDisclosureError.invalidMP4
            }
            let provenance = selected.recipe.provenance
            var item: [String: Any] = [
                "segmentId": segment.id, "kind": segment.kind.rawValue,
                "outputStart": Double(selected.piece.outputStartSample) / prepared.outputPlan.sampleRate,
                "outputEnd": Double(selected.piece.outputEndSample) / prepared.outputPlan.sampleRate,
                "candidateIndex": segment.selectedCandidateIndex,
                "assetSha256": asset.sha256,
                "provider": provenance.provider, "endpoint": provenance.endpoint,
                "model": provenance.model, "voice": selected.recipe.voiceSource.rawValue,
                "voiceId": provenance.voiceId, "seed": selected.recipe.seed,
                "generatedAt": try timestamp(provenance.createdAt)
            ]
            if let text = segment.text?.new { item["text"] = text }
            if let region = provenance.region { item["region"] = region }
            if let request = provenance.requestId { item["requestId"] = request }
            var qa: [String: Any] = [:]
            if let score = selected.recipe.qa.speakerScore { qa["speakerScore"] = score }
            if let threshold = selected.recipe.qa.speakerThreshold { qa["speakerThreshold"] = threshold }
            if let model = selected.recipe.qa.speakerModel { qa["speakerModel"] = model }
            if let passed = selected.recipe.qa.speakerPassed { qa["speakerPassed"] = passed }
            if !qa.isEmpty { item["verification"] = qa }
            if let record = provenance.consentRecordId {
                item["consentRecordId"] = record
                if !consent.contains(where: { $0["recordId"] as? String == record }) {
                    var identity: [String: Any] = ["recordId": record]
                    if let verified = selected.recipe.consentVerifiedAt { identity["verifiedAt"] = try timestamp(verified) }
                    consent.append(identity)
                }
            }
            segments.append(item)
        }
        let disclosure = prepared.disclosure
        let value: [String: Any] = [
            "schema": "voxclip-provenance/1",
            "app": ["name": "VoxClip", "version": appVersion, "platform": "macos"],
            "export": ["file": filename, "sha256": hash, "durationSeconds": prepared.outputPlan.duration,
                       "createdAt": try timestamp(createdAt)],
            "source": ["contentKey": project.media.source.contentKey,
                       "durationSeconds": project.media.source.durationSeconds],
            "scope": scopeValue(prepared.outputPlan.scope),
            "edits": ["cutWords": project.edits.cutWordIds.count, "cutPauses": project.edits.cutPauseIds.count,
                      "corrections": project.edits.corrections.count],
            "aiSegments": segments,
            "disclosure": ["required": disclosure.required, "persistent": disclosure.persistent,
                           "labelIntervals": disclosure.intervals.map { [$0.start, $0.end] },
                           "postText": disclosure.postText ?? "", "c2pa": false],
            "consent": consent
        ]
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
    }

    private static func scopeValue(_ scope: VoiceLabOutputScope) -> [String: String] {
        switch scope { case .full: ["kind": "full"]
        case .clip(let id): ["kind": "clip", "clipId": id] }
    }
}
