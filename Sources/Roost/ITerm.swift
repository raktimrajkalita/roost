import Foundation
import AppKit

/// iTerm2 integration via AppleScript: fetch each session's tab name, and focus
/// a session by its unique id. Runs off the main thread so it never blocks the UI.
enum ITerm {

    /// uuid -> cleaned tab name (status glyph and trailing "(node)" stripped)
    static func fetchNames(_ completion: @escaping ([String: String]) -> Void) {
        let script = """
        set d to tab
        set lf to linefeed
        tell application "iTerm2"
          set out to ""
          repeat with w in windows
            repeat with t in tabs of w
              repeat with sess in sessions of t
                set out to out & (unique id of sess) & d & (name of sess) & lf
              end repeat
            end repeat
          end repeat
          return out
        end tell
        """
        runAppleScript(script) { result in
            var map: [String: String] = [:]
            for line in (result ?? "").split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1)
                guard parts.count == 2 else { continue }
                if let name = clean(String(parts[1])) {
                    map[String(parts[0])] = name
                }
            }
            DispatchQueue.main.async { completion(map) }
        }
    }

    /// Focus the iTerm2 session whose unique id matches (uuid from ITERM_SESSION_ID).
    static func focus(uuid: String) {
        let script = """
        tell application "iTerm2"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              repeat with sess in sessions of t
                if (unique id of sess) is "\(uuid)" then
                  select w
                  select t
                  select sess
                  return
                end if
              end repeat
            end repeat
          end repeat
        end tell
        """
        runAppleScript(script, completion: { _ in })
    }

    // MARK: helpers

    private static func clean(_ raw: String) -> String? {
        var n = raw
        // drop trailing job like " (node)"
        if let r = n.range(of: #"\s*\([^()]*\)\s*$"#, options: .regularExpression) {
            n.removeSubrange(r)
        }
        // drop a leading status glyph + space (first token if it's non-alphanumeric)
        if let first = n.first, !first.isLetter, !first.isNumber,
           let sp = n.firstIndex(of: " ") {
            n = String(n[n.index(after: sp)...])
        }
        n = n.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? nil : n
    }

    private static func runAppleScript(_ source: String, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var error: NSDictionary?
            let out = NSAppleScript(source: source)?.executeAndReturnError(&error)
            completion(out?.stringValue)
        }
    }
}
