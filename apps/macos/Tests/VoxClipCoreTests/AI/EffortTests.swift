import Foundation
import Testing
@testable import VoxClipCore

/// ai.md §2.1: every AI decision asks for extra high; a connector sends the highest level it supports at or below it.
struct EffortTests {
    @Test func decisionFeaturesAskForExtraHigh() {
        #expect(Effort.decision == .xhigh)
        #expect(Effort.allCases.map(\.rawValue) == ["low", "medium", "high", "xhigh", "max"])
        #expect(Effort.allCases.map(\.label) == ["low", "medium", "high", "extra high", "max"])
    }

    @Test func resolvesToTheHighestSupportedLevelAtOrBelowTheRequest() {
        #expect(Effort.resolved(.xhigh, supported: ["low", "medium", "high", "xhigh", "max"]) == .xhigh)
        #expect(Effort.resolved(.xhigh, supported: ["LOW", "MEDIUM", "HIGH"]) == .high)
        #expect(Effort.resolved(.max, supported: ["medium", "xhigh"]) == .xhigh)
        #expect(Effort.resolved(.xhigh, supported: ["minimal", "low"]) == .low)
        #expect(Effort.resolved(.low, supported: ["high"]) == nil)
        #expect(Effort.resolved(.xhigh, supported: []) == nil)
        #expect(Effort.resolved(nil, supported: ["high"]) == nil)
    }

    @Test func catalogDecisionEffortPerConnector() throws {
        let catalog = try LLMCatalog(shared: SharedResources(root: aiGoldenSharedRoot()))
        let expected: [ConnectorID: Effort?] = [
            .anthropic: .xhigh, .openai: .high, .gemini: .high, .xai: nil, .ollama: nil, .lmstudio: nil,
            .appleFoundation: nil, .claudeCode: .xhigh, .codex: .high,
        ]
        for id in ConnectorID.allCases { #expect(catalog.decisionEffort(for: id) == expected[id] ?? nil, "\(id.rawValue)") }
    }

    @Test func decisionFeaturesUseTheRaisedCatalogTimeouts() throws {
        let catalog = try LLMCatalog(shared: SharedResources(root: aiGoldenSharedRoot()))
        for feature in [LLMFeature.clipFinder, .aiTighten, .voiceRewrite] {
            #expect(catalog.timeout(for: .anthropic, feature: feature) == .seconds(360))
            #expect(catalog.timeout(for: .claudeCode, feature: feature) == .seconds(600))
            #expect(catalog.timeout(for: .codex, feature: feature) == .seconds(600))
        }
        #expect(catalog.timeout(for: .anthropic, feature: .test) == .seconds(30))
        #expect(catalog.timeout(for: .claudeCode, feature: .test) == .seconds(120))
    }
}
