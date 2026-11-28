import Foundation

enum AgentOfferCatalog {
    static func make(id: String, fields: [String: JSONValue], project: Project) throws -> AgentTurn.Offer {
        guard let kind = fields["kind"]?.aiString.flatMap(AgentTurn.Offer.Kind.init(rawValue:)),
              let target = fields["target"]?.aiString, let amount = amount(fields["quote"]?.aiString) else {
            throw HarnessError.invalid("A local price isn't available for this offer.")
        }
        let label: String
        switch kind {
        case .generateMusic:
            let seconds = (try? HarnessProposal.renderedSeconds(in: project, clipID: target)).flatMap { $0.isFinite && $0 >= 0 && $0 < Double(Int.max) ? Int($0.rounded()) : nil }
            label = seconds.map { "Generate a track for \($0 / 60):\(String(format: "%02d", $0 % 60))" } ?? "Generate a track"
        case .illustration: label = "Generate an illustration"
        case .revoice: label = "Revoice in Rewrite"
        case .lipSync: label = "Lip sync in Rewrite"
        case .makeItPostable: label = "Make it postable"
        }
        let words = fields["words"]?.aiArray.compactMap(\.aiString)
        return .init(id: id, kind: kind, label: label, quoteUSD: currency(amount),
                     target: target, brief: fields["brief"]?.aiString, words: words)
    }

    static func amount(_ formatted: String?) -> Decimal? {
        guard let formatted else { return nil }
        let value = formatted.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "0123456789.").inverted)
        guard let amount = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), amount >= 0 else { return nil }
        return amount
    }

    static func currency(_ amount: Decimal) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), NSDecimalNumber(decimal: amount).doubleValue)
    }

    static func fields(_ offer: AgentTurn.Offer) -> [String: JSONValue] {
        var result: [String: JSONValue] = ["kind": .string(offer.kind.rawValue)]
        if let target = offer.target { result["target"] = .string(target) }
        if let brief = offer.brief { result["brief"] = .string(brief) }
        if let words = offer.words { result["words"] = .array(words.map(JSONValue.string)) }
        return result
    }
}

@MainActor public final class AgentOffers {
    public enum Receipt: Sendable, Equatable { case bought(assetID: String), cancelled }
    public enum Result: Sendable, Equatable {
        case unavailable, busy, overCap(Decimal), priceChanged, openedRewrite, bought(String), cancelled, failed
    }

    public struct Presentation: Sendable, Equatable {
        public let title: String
        public let canBuy: Bool
        public let topUpUSD: Decimal?
    }

    private let project: () -> Project
    private let update: (Project) -> Void
    private let shared: SharedResources
    private let capLeft: () -> Decimal?
    private let now: () -> Date
    private let openRewrite: (AgentTurn.Offer) -> Void
    private let purchase: (AgentTurn.Offer, Decimal) async throws -> Receipt
    private var buying: Set<String> = []

    public init(project: @escaping () -> Project, update: @escaping (Project) -> Void, shared: SharedResources,
                capLeft: @escaping () -> Decimal?, now: @escaping () -> Date = { Date() },
                openRewrite: @escaping (AgentTurn.Offer) -> Void = { _ in },
                purchase: @escaping (AgentTurn.Offer, Decimal) async throws -> Receipt) {
        self.project = project; self.update = update; self.shared = shared; self.capLeft = capLeft
        self.now = now; self.openRewrite = openRewrite; self.purchase = purchase
    }

    public static func presentation(_ offer: AgentTurn.Offer, capLeft: Decimal?) -> Presentation {
        let price = AgentOfferCatalog.amount(offer.quoteUSD)
        let prefix = switch offer.kind {
        case .revoice, .lipSync: "about "
        case .makeItPostable: "up to "
        default: ""
        }
        let left = capLeft.map { " · $\(AgentOfferCatalog.currency($0)) left" } ?? ""
        let topUp = price.flatMap { price in capLeft.flatMap { $0 < price ? price - $0 : nil } }
        return .init(title: "\(offer.label) · \(prefix)$\(offer.quoteUSD)\(left)",
                     canBuy: price != nil && capLeft != nil && topUp == nil && offer.state == .offered && offer.target != nil,
                     topUpUSD: topUp)
    }

    public func buy(offerId: String) async -> Result {
        let snapshot = project()
        guard let (turn, offer) = Self.find(offerId, in: snapshot), offer.state == .offered,
              let approved = AgentOfferCatalog.amount(offer.quoteUSD), offer.target != nil else { return .unavailable }
        guard buying.isEmpty else { return .busy }
        guard let left = capLeft() else { return .unavailable }
        if approved > left { return .overCap(approved - left) }
        buying.insert(offerId)
        defer { buying.remove(offerId) }
        do {
            let result = try HarnessChatTools.offer(AgentOfferCatalog.fields(offer), project: snapshot, shared: shared, postableCap: left)
            let current = try AgentOfferCatalog.make(id: offerId, fields: result.fields, project: snapshot)
            guard current.quoteUSD == offer.quoteUSD else {
                updateOffer(current, in: turn, projectID: snapshot.id)
                return .priceChanged
            }
            if offer.kind == .revoice || offer.kind == .lipSync {
                openRewrite(current)
                return .openedRewrite
            }
            switch try await purchase(current, approved) {
            case .cancelled: return .cancelled
            case .bought(let assetID):
                var bought = current
                bought.state = .bought; bought.assetId = assetID
                updateOffer(bought, in: turn, projectID: snapshot.id, event: .init(kind: .bought,
                    undoName: "Bought: \(current.label) · $\(current.quoteUSD)", target: offerId, at: now()))
                return .bought(assetID)
            }
        } catch is CancellationError { return .cancelled }
        catch {
            var failed = offer
            failed.state = .failed
            updateOffer(failed, in: turn, projectID: snapshot.id)
            return .failed
        }
    }

    private static func find(_ id: String, in project: Project) -> (String, AgentTurn.Offer)? {
        for turn in project.agentThread?.turns.reversed() ?? [].reversed() {
            if let offer = turn.offers.first(where: { $0.id == id }) { return (turn.id, offer) }
        }
        return nil
    }

    private func updateOffer(_ offer: AgentTurn.Offer, in turn: String, projectID: String, event: AgentTurn.Event? = nil) {
        var live = project()
        guard live.id == projectID, var thread = live.agentThread,
              let index = thread.turns.firstIndex(where: { $0.id == turn }),
              let item = thread.turns[index].offers.firstIndex(where: { $0.id == offer.id }) else { return }
        thread.turns[index].offers[item] = offer
        if let event { thread.turns[index].events.append(event) }
        live.agentThread = thread
        update(live)
    }
}
