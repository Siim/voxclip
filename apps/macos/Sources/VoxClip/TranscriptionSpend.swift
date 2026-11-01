import Foundation
import VoxClipCore

/// App-owned daily estimates (not provider invoices). Canceled or failed uploads retain an upper bound.
actor TranscriptionSpend {
    struct Total: Codable, Sendable { var amount = 0.0; var uncertain = false }
    private struct Document: Codable { var schema = "voxclip-transcription-spend/1"; var days: [String: Total] = [:] }
    private let url: URL
    private var document: Document?
    init(locations: DataLocations) { url = locations.root.appendingPathComponent("transcription-spend.json") }
    private func day(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
    private func load() -> Document {
        if let document { return document }
        let value = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Document.self, from: $0) }
        let result = value?.schema == "voxclip-transcription-spend/1" ? value! : Document()
        document = result
        return result
    }
    func total(at date: Date = Date()) -> Total { load().days[day(date)] ?? Total() }
    func record(_ amount: Double, uncertain: Bool, at date: Date = Date()) -> Total {
        guard amount.isFinite, amount >= 0 else { return total(at: date) }
        var value = load(), total = value.days[day(date)] ?? Total()
        total.amount += amount; total.uncertain = total.uncertain || uncertain
        value.days[day(date)] = total; document = value
        // Only estimates are stored, never keys, media paths or provider payloads.
        if let data = try? JSONEncoder().encode(value) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: [.atomic])
        }
        return total
    }
}
