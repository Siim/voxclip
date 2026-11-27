import Foundation
import Testing
import VoxClipCore

@Suite struct HarnessChatToolsTests {
    private func setup() throws -> (JSONValue, Project, SharedResources) {
        let root = try FixtureLoader.sharedRoot()
        let fixture = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("fixtures/agent-chat/tool-cases.json")))
        let path = try #require(fixture[ai: "project"].aiString)
        let project = try JSONProjectStore.decode(Data(contentsOf: root.appendingPathComponent(path)))
        return (fixture, project, SharedResources(root: root))
    }

    @Test func offersQuoteTheSameLocalPricesAsProposals() async throws {
        let (fixture, project, shared) = try setup()
        let timeline = fixture[ai: "savedCalls"][ai: "propose_timeline"]
        let proposed = try await HarnessTools.call(.proposeTimeline, arguments: timeline, project: project, shared: shared)
        let prices = try #require(proposed.fields["pricedActions"]?.aiArray)
        var ids = Set<UUID>()
        for (index, vector) in try #require(fixture[ai: "offers"].aiArray).enumerated() {
            let offered = try await HarnessTools.call(.offer, arguments: vector[ai: "arguments"], project: project, shared: shared)
            #expect(offered.fields["quote"] == vector[ai: "quote"])
            #expect(offered.fields["quote"] == prices[index][ai: "price"])
            let id = try #require(offered.fields["offerId"]?.aiString.flatMap(UUID.init(uuidString:)))
            #expect(ids.insert(id).inserted)
        }
        await #expect(throws: HarnessError.self) {
            try await HarnessTools.call(.offer, arguments: .object(["kind": .string("generateMusic"), "target": .string("clip-2f1c"), "approved": .bool(true)]),
                                        project: project, shared: shared)
        }
    }

    @Test func liveProposalReturnsRevisionAndLabelAndLinkDoesNotEdit() async throws {
        let (fixture, project, shared) = try setup()
        let timeline = try #require(fixture[ai: "savedCalls"][ai: "propose_timeline"].aiObject)
        let revision = fixture[ai: "revision"]
        let metadata = try #require(revision.aiObject)
        let input: JSONValue = .object(["timelines": .array([.object(timeline.merging(["label": metadata["label"]!]) { first, _ in first })]),
                                        "revises": revision[ai: "revises"]])
        let proposal = try await HarnessTools.call(.proposeTimeline, arguments: input, project: project, shared: shared)
        #expect(proposal.fields["revises"] == revision[ai: "revises"])
        #expect(proposal.fields["labels"] == .array([revision[ai: "label"]]))
        #expect(proposal.fields["proposal"]?[ai: "timelines"] == .array([.object(timeline)]))
        let point = fixture[ai: "pointTo"]
        let link = try await HarnessTools.call(.pointTo, arguments: point[ai: "arguments"], project: project, shared: shared)
        #expect(link.fields["label"] == point[ai: "label"])
        #expect(link.fields["target"] == point[ai: "arguments"][ai: "target"])
        #expect(link.proposal == nil)
    }

    @Test func folderSearchReturnsAnOpaqueIdUsableInATimeline() async throws {
        let (_, project, shared) = try setup()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("Calm Piano.wav"))
        let music = HarnessMusicLibrary(folder: directory) { candidate, projectID in
            ProjectMusic(id: candidate.id, clipId: nil,
                         asset: MusicAsset(file: "\(projectID)/calm.wav", sha256: String(repeating: "a", count: 64), durationSeconds: 15),
                         source: candidate.source, title: candidate.title, license: candidate.license)
        }
        let search = try await HarnessTools.call(.findMusic, arguments: .object(["mood": .string("calm piano"), "lengthSeconds": .number(10)]),
                                                 project: project, shared: shared, music: music)
        let track = try #require(search.fields["tracks"]?.aiArray?.first)
        let id = try #require(track[ai: "id"].aiString)
        #expect(track[ai: "title"] == .string("Calm Piano"))
        #expect(!id.contains(directory.path))
        let proposal = try await HarnessTools.call(.proposeTimeline,
            arguments: .object(["clipId": .string("clip-2f1c"), "reason": .string("Use the free track."), "music": .object(["trackId": .string(id)])]),
            project: project, shared: shared, music: music)
        #expect(proposal.preparedMusic.map(\.id) == [id])
        #expect(proposal.fields["pricedActions"] == .array([]))
    }
}
