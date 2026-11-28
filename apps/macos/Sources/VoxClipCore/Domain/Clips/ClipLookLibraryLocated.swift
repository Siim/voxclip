import Foundation

extension ClipLookLibrary {
    /// The looks of the shared files this process finds (`SharedResources.locate()`), read once; nil when they are missing
    /// or the file is broken. Core rules that apply a look by ID default to it.
    public static let located: ClipLookLibrary? = (try? SharedResources.locate()).flatMap { try? load(shared: $0) }
}
