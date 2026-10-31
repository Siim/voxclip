import Foundation
import Testing
@testable import VoxClipCore

/// voice-lab.md §3.1 for LLM sends, as amended by the user's decision of 2026-10-31: replays
/// shared/fixtures/voice-lab/llm-send-cost-cases.json (rules in llm-send-cost-README.md).
@Suite struct VoiceLabLLMSendCostTests {
    private struct Vectors: Decodable {
        struct Expected: Decodable { let kind: String; let text: String }
        struct Case: Decodable {
            let id: String; let connector: String; let group: String; let signIn: String?; let providerName: String
            let expected: Expected
        }
        let schema: String
        let cases: [Case]
    }
    private func vectors() throws -> Vectors {
        try JSONDecoder().decode(Vectors.self, from: FixtureLoader.data("fixtures/voice-lab/llm-send-cost-cases.json"))
    }
    private func signIn(_ value: String?) throws -> CLISignIn? {
        switch value {
        case nil: return nil
        case "plan"?: return .plan
        case "apiKey"?: return .apiKey
        case let other?: throw CocoaError(.coderInvalidValue, userInfo: [NSDebugDescriptionErrorKey: "sign-in \(other)"])
        }
    }

    @Test func everyConnectorAndSignInReplays() throws {
        let vectors = try vectors()
        #expect(vectors.schema == "voxclip-voice-lab-llm-send-cost-cases/1")
        for row in vectors.cases {
            let connector = try #require(ConnectorID(rawValue: row.connector), "\(row.id)")
            let state = try signIn(row.signIn)
            let expected: VoiceLabCostPresentation.Kind = row.expected.kind == "inline" ? .inline(row.expected.text) : .confirm(row.expected.text)
            let kind = VoiceLabCostPresentation.kind(forLLMSendTo: connector, signIn: state, providerName: row.providerName)
            #expect(kind == expected, "\(row.id)")
            #expect(VoiceLabCostPresentation.buttonTitle("Rewrite", kind: kind) == "Rewrite", "\(row.id) carries no amount")
        }
    }

    @Test func theTableCoversEveryConnectorWithEverySignInState() throws {
        let cases = try vectors().cases
        let covered = Set(cases.map { "\($0.connector)|\($0.signIn ?? "unknown")" })
        let required = Set(ConnectorID.allCases.flatMap { id in ["plan", "apiKey", "unknown"].map { "\(id.rawValue)|\($0)" } })
        #expect(covered == required)
        #expect(cases.count == required.count)
    }

    /// The plan's risk: a CLI on an API-key sign-in must never pass as "no extra cost".
    @Test func onlyAPlanSignInLetsACLISendWithoutAsking() {
        for connector in [ConnectorID.claudeCode, .codex] {
            #expect(VoiceLabCostPresentation.kind(forLLMSendTo: connector, signIn: .plan, providerName: "Anthropic") == .inline(""))
            for signIn in [CLISignIn.apiKey, nil] {
                #expect(VoiceLabCostPresentation.kind(forLLMSendTo: connector, signIn: signIn, providerName: "Anthropic")
                    == .confirm("VoxClip can't tell what this costs. Check Anthropic's pricing."), "\(connector) \(String(describing: signIn))")
            }
        }
        #expect(CLISignIn(rawValue: "api_key") == .apiKey && CLISignIn(rawValue: "plan") == .plan && CLISignIn(rawValue: "claude.ai") == nil)
    }
}
