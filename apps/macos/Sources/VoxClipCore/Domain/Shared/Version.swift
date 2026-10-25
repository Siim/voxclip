import Foundation

/// Numeric component comparison and prerelease ordering; architecture §13.1.
public func compareVersions(_ left: String, _ right: String) -> ComparisonResult {
    func components(_ text: String) -> ([Int], Bool) {
        let clean = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = clean.split(separator: "-", maxSplits: 1)
        return ((parts.first ?? "").split(separator: ".").map { Int($0) ?? 0 }, parts.count > 1)
    }
    let (leftNumbers, leftPrerelease) = components(left)
    let (rightNumbers, rightPrerelease) = components(right)
    for index in 0..<max(leftNumbers.count, rightNumbers.count) {
        let lhs = index < leftNumbers.count ? leftNumbers[index] : 0
        let rhs = index < rightNumbers.count ? rightNumbers[index] : 0
        if lhs != rhs { return lhs < rhs ? .orderedAscending : .orderedDescending }
    }
    if leftPrerelease != rightPrerelease { return leftPrerelease ? .orderedAscending : .orderedDescending }
    return .orderedSame
}
