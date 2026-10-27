// DCMediaTests — writes the generated media inputs for the oracle into `<fixtures>/media/inputs`. Runs only
// with DCMEDIA_WRITE_INPUTS=1, then `Tools/oracle/media-vectors/run.sh` writes what deckcraft-media says
// about them (see Packages/DCMedia/PORT-NOTES.md).
import DCTestSupport
import Foundation
import Testing

@Suite struct FixtureWriterTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DCMEDIA_WRITE_INPUTS"] == "1"))
    func writeOracleInputs() async throws {
        let dir = TestMedia.inputsDir
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, bytes) in try await TestMedia.allInputs() {
            try Data(bytes).write(to: dir.appending(path: name))
        }
    }
}
