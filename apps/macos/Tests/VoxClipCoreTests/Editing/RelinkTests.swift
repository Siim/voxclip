import Foundation
import Testing
@testable import VoxClipCore

@Suite struct RelinkTests {
    struct Fixture: Decodable {
        struct Case: Decodable {
            let id: String
            let size: Int64
            let key: String
            let duration: Double
            let storedDuration: Double?
            let confirmed: Bool
            let expected: String
        }
        let storedSize: Int64
        let storedKey: String
        let storedDuration: Double
        let cases: [Case]
    }

    @Test func sharedDecisions() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: FixtureLoader.data("fixtures/projects/relink-cases.json"))
        for item in fixture.cases {
            let actual = RelinkDecision.decide(storedSize: fixture.storedSize, storedKey: fixture.storedKey,
                storedDuration: item.storedDuration ?? fixture.storedDuration, size: item.size, key: item.key,
                duration: item.duration, confirmedDifferent: item.confirmed)
            #expect(actual.rawValue == item.expected, "\(item.id)")
        }
    }
}
