// DCAppTests — the app's launch arguments. Ported from deckcraft `apps/deckcraft/src/main.rs`'s tests.
import Testing
@testable import DCApp

@Suite struct LaunchTests {
    // main.rs: help_exits_instead_of_opening_a_file (the run case)
    @Test func controlSampleAndFiles() {
        let l = Launch(arguments: ["--sample", "--control", "4242", "talk.pptx"], environmentPort: 9)
        #expect(l.controlPort == 4242)
        #expect(l.files == ["talk.pptx"])
        #expect(l.sample)
        #expect(!l.show)
    }

    // main.rs: finder_process_serial_number_is_not_a_file
    @Test func finderProcessSerialNumberIsNotAFile() {
        #expect(Launch(arguments: ["-psn_0_1234567", "talk.pptx"]).files == ["talk.pptx"])
    }

    @Test func appKitArgumentsAreNotFiles() {
        #expect(Launch(arguments: ["-NSDocumentRevisionsDebugMode", "YES", "a.deckcraft"]).files == ["a.deckcraft"])
    }

    @Test func documentTypes() {
        #expect(DocumentTypes.type(forExtension: "PPTX") == DocumentTypes.pptx)
        #expect(DocumentTypes.format(DocumentTypes.deckcraft) == "deckcraft")
        #expect(DocumentTypes.format(DocumentTypes.potx) == nil)
    }
}
