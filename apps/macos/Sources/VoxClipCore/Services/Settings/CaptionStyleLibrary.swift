import Foundation

extension CaptionResources {
    public static func load(shared: SharedResources) throws -> CaptionResources {
        do {
            func data(_ path: String) throws -> Data { try Data(contentsOf: shared.root.appendingPathComponent(path)) }
            return try .init(fontManifest: data("fonts/fonts.json"), caseMap: data("caption-styles/casemap.json"),
                stopwords: data("caption-styles/stopwords.json"), emojiKeywords: data("caption-styles/emoji-keywords.json"))
        } catch { throw VoxClipError.sharedResourcesMissing }
    }
}

public struct CaptionStyleLibrary: Sendable {
    public let styles: [CaptionStyle]

    public init(shared: SharedResources) throws {
        do {
            let directory = shared.root.appendingPathComponent("caption-styles/styles", isDirectory: true)
            let resources = try CaptionResources.load(shared: shared)
            let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
            let styles = try urls.map { url in
                let style = try JSONDecoder().decode(CaptionStyle.self, from: Data(contentsOf: url))
                try resources.validate(style: style)
                return style
            }
            guard Set(styles.map(\.id)).count == styles.count else { throw CaptionFailure.invalid("Duplicate caption style") }
            self.styles = styles.sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
        } catch let error as VoxClipError { throw error }
        catch let error as CaptionFailure { throw error }
        catch { throw VoxClipError.sharedResourcesMissing }
    }

    public func style(id: String) -> CaptionStyle? { styles.first { $0.id == id } }
}
