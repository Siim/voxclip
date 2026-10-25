import Testing
import VoxClipCore

@Test("mac-editing") func macEditing() throws {
    #expect(try isFillerText("umm!"))
    #expect(toFixed1(1.25) == "1.3")
    #expect(!EditingFixtures.files.isEmpty)
}
