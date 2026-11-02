import Foundation

public enum ContextDemoPreparationError: Error, Equatable, Sendable {
    case invalidURL, unsafeURL, invalidPlan, approvalRequired, approvalExpired, stalePlan
    case invalidDirectory, projectUnreadable, projectChanged, invalidCommand, commandFailed

    public var userMessage: String {
        switch self {
        case .invalidURL: "Enter a complete HTTP or HTTPS page URL."
        case .unsafeURL: "Use HTTPS, or a loopback HTTP preview, without embedded credentials or secret query parameters."
        case .invalidPlan: "This demonstration exceeds the supported action or time limits. Review a shorter plan."
        case .approvalRequired: "Review and approve this exact demonstration plan before starting."
        case .approvalExpired: "This approval has expired. Review the plan again."
        case .stalePlan: "The target or narration changed. Prepare and review a new plan."
        case .invalidDirectory: "Select a local project folder, not a symbolic link or a protected credentials folder."
        case .projectUnreadable: "The selected project facts could not be read safely. No commands were run."
        case .projectChanged: "The project facts changed. Inspect and approve a new plan before running commands."
        case .invalidCommand: "Review an absolute executable and bounded arguments. Shell bridges and dependency downloads are not supported."
        case .commandFailed: "The approved project command failed. No additional commands were run."
        }
    }
}

public enum ContextDemoURLPolicy {
    public static func validate(_ rawValue: String) throws -> URL {
        guard !rawValue.isEmpty, rawValue.utf8.count <= 4096,
              !rawValue.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              let components = URLComponents(string: rawValue),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty,
              let url = components.url else { throw ContextDemoPreparationError.invalidURL }
        let loopback = ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)
        guard components.user == nil, components.password == nil,
              scheme == "https" || loopback,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              !(components.fragment?.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ?? false),
              !(components.queryItems ?? []).contains(where: { item in
                  let name = item.name.lowercased().replacingOccurrences(of: "-", with: "_")
                  return ["key", "auth", "sig", "code"].contains(name)
                      || ["token", "secret", "password", "credential", "authorization", "api_key", "apikey", "signature", "session", "jwt", "bearer"].contains(where: { name.contains($0) })
              }),
              !["token=", "secret=", "key=", "password=", "auth=", "code=", "session=", "jwt=", "sig="].contains(where: {
                  components.fragment?.lowercased().contains($0) ?? false
              }) else { throw ContextDemoPreparationError.unsafeURL }
        return url
    }
}

public enum ContextDemoWebAction: Equatable, Sendable {
    case navigate(URL)
    case scroll(verticalPixels: Int)
    case followLink(elementID: String, destination: URL)
    case pause(milliseconds: Int)

    public var reviewDescription: String {
        switch self {
        case .navigate(let url): "Open \(url.absoluteString)"
        case .scroll(let pixels): "Scroll vertically by \(pixels) pixels"
        case .followLink(let elementID, let destination): "Follow link with ID ‘\(elementID)’ to \(destination.absoluteString)"
        case .pause(let milliseconds): "Wait \(milliseconds) milliseconds"
        }
    }
}

public struct ContextDemoWebPlan: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let revision: String
    public let actions: [ContextDemoWebAction]
    public let approvedNavigationURLs: Set<URL>
    public let navigationTimeoutSeconds: Int
    public let maximumDurationSeconds: Int

    public static func prepare(url: String, revision: String,
                               actions: [ContextDemoWebAction] = [],
                               navigationTimeoutSeconds: Int = 15) throws -> Self {
        let initial = try ContextDemoURLPolicy.validate(url)
        guard !revision.isEmpty, revision.utf8.count <= 512, actions.count < 12,
              (1...20).contains(navigationTimeoutSeconds) else { throw ContextDemoPreparationError.invalidPlan }
        let steps: [ContextDemoWebAction] = [.navigate(initial)] + actions
        var destinations: Set<URL> = [initial]
        var maximumSeconds = 0
        for action in steps {
            switch action {
            case .navigate(let destination):
                destinations.insert(try ContextDemoURLPolicy.validate(destination.absoluteString))
                maximumSeconds += navigationTimeoutSeconds
            case .followLink(let elementID, let destination):
                guard !elementID.isEmpty, elementID.utf8.count <= 128,
                      !elementID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw ContextDemoPreparationError.invalidPlan
                }
                destinations.insert(try ContextDemoURLPolicy.validate(destination.absoluteString))
                maximumSeconds += navigationTimeoutSeconds + 2
            case .scroll(let pixels):
                guard (-3000...3000).contains(pixels), pixels != 0 else { throw ContextDemoPreparationError.invalidPlan }
                maximumSeconds += 2
            case .pause(let milliseconds):
                guard (1...5000).contains(milliseconds) else { throw ContextDemoPreparationError.invalidPlan }
                maximumSeconds += (milliseconds + 999) / 1000
            }
        }
        guard maximumSeconds <= 90 else { throw ContextDemoPreparationError.invalidPlan }
        return Self(id: UUID(), revision: revision, actions: steps,
                    approvedNavigationURLs: destinations, navigationTimeoutSeconds: navigationTimeoutSeconds,
                    maximumDurationSeconds: maximumSeconds)
    }
}

public struct ContextDemoWebApproval: Sendable {
    private let plan: ContextDemoWebPlan
    private let approvedAt: Date
    private let expiresAt: Date

    public static func approve(plan: ContextDemoWebPlan, currentRevision: String,
                               now: Date = Date()) throws -> Self {
        guard plan.revision == currentRevision else { throw ContextDemoPreparationError.stalePlan }
        return Self(plan: plan, approvedAt: now, expiresAt: now.addingTimeInterval(300))
    }

    public func validate(plan: ContextDemoWebPlan, currentRevision: String, now: Date = Date()) throws {
        guard self.plan == plan else { throw ContextDemoPreparationError.approvalRequired }
        guard plan.revision == currentRevision else { throw ContextDemoPreparationError.stalePlan }
        guard now >= approvedAt, now < expiresAt else { throw ContextDemoPreparationError.approvalExpired }
    }
}
