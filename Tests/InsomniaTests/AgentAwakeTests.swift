import XCTest
@testable import Insomnia

final class AgentAwakeTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("agent-awake-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testMissingDirectoryIsInactive() {
        XCTAssertFalse(AgentAwake.isActive(holds: dir))
    }

    func testEmptyDirectoryIsInactive() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertFalse(AgentAwake.isActive(holds: dir))
    }

    func testHiddenFilesAreIgnored() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent(".DS_Store").path, contents: nil)
        XCTAssertFalse(AgentAwake.isActive(holds: dir))
    }

    func testAHoldMakesItActive() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("session-1").path, contents: Data("123\n".utf8))
        XCTAssertTrue(AgentAwake.isActive(holds: dir))
    }

    /// A relocated layout (tests, INSOMNIA_HOME) never reads the user's
    /// ~/.claude, so a session there restores sleep as before.
    @MainActor
    func testRelocatedManagerIgnoresAgentHolds() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        let m = h.makeManager()
        await m.start(duration: 3600)
        _ = await m.end(reason: .user)
        XCTAssertEqual(h.guardFake.calls.last, "disablesleep 0")
    }
}
