import Foundation

/// Coexistence with ~/.claude/hooks/agent-awake.sh, which holds
/// `pmset -a disablesleep 1` while a Claude Code agent is working. A file in
/// `holds` is one working session; the `ours` marker tells the hook it owns
/// the setting and must clear it when the last hold goes.
enum AgentAwake {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/agent-awake", isDirectory: true)
    static var holds: URL { root.appendingPathComponent("holds", isDirectory: true) }
    static var ownedMarker: URL { root.appendingPathComponent("ours") }

    static func isActive(holds: URL = holds) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: holds.path)) ?? []
        return names.contains { !$0.hasPrefix(".") }
    }

    /// Leave SleepDisabled set and make the hook responsible for clearing it.
    static func handOff() {
        FileManager.default.createFile(atPath: ownedMarker.path, contents: nil)
    }
}
