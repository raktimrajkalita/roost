import Foundation
import AppKit

/// iTerm2 integration via AppleScript: fetch each session's tab name, and focus
/// a session by its unique id. Runs off the main thread so it never blocks the UI.
enum ITerm {

    /// Session display names: iTerm session names keyed by unique id (glyph + trailing
    /// "(job)" stripped), plus Terminal.app custom titles (the user's rename) keyed by tty.
    /// Both scripts are guarded by `is running` so a background refresh never launches a
    /// terminal that's closed.
    static func fetchNames(_ completion: @escaping ([String: String]) -> Void) {
        let itermScript = """
        set d to tab
        set lf to linefeed
        set out to ""
        if application "iTerm2" is running then
          tell application "iTerm2"
            repeat with w in windows
              repeat with t in tabs of w
                repeat with sess in sessions of t
                  set out to out & (unique id of sess) & d & (name of sess) & lf
                end repeat
              end repeat
            end repeat
          end tell
        end if
        return out
        """
        let terminalScript = """
        set d to tab
        set lf to linefeed
        set out to ""
        if application "Terminal" is running then
          tell application "Terminal"
            repeat with w in windows
              repeat with t in tabs of w
                set ct to ""
                try
                  set ct to custom title of t
                end try
                if ct is not missing value and ct is not "" then
                  set out to out & (tty of t) & d & ct & lf
                end if
              end repeat
            end repeat
          end tell
        end if
        return out
        """
        runAppleScript(itermScript) { itermOut in
            var map: [String: String] = [:]
            for line in (itermOut ?? "").split(separator: "\n") {          // iTerm: keyed by unique id
                let parts = line.split(separator: "\t", maxSplits: 1)
                if parts.count == 2, let name = clean(String(parts[1])) {
                    map[String(parts[0])] = name
                }
            }
            runAppleScript(terminalScript) { termOut in
                for line in (termOut ?? "").split(separator: "\n") {       // Terminal: user's custom title, keyed by tty
                    let parts = line.split(separator: "\t", maxSplits: 1)
                    if parts.count == 2 {
                        let title = String(parts[1]).trimmingCharacters(in: .whitespaces)
                        if !title.isEmpty { map[String(parts[0])] = title }
                    }
                }
                DispatchQueue.main.async { completion(map) }
            }
        }
    }

    /// Focus the terminal session behind a row — routes by which app it's running in.
    static func focus(session: Session) {
        switch session.termProgram {
        case "iTerm.app":
            if let uuid = session.itermUUID { focusITerm(uuid: uuid) } else { raiseApp("iTerm") }
        case "Apple_Terminal":
            if !session.tty.isEmpty { focusTerminal(tty: session.tty) } else { raiseApp("Terminal") }
        default:
            // other terminals (VS Code, Ghostty, Warp) have no per-tab focus path yet
            if let uuid = session.itermUUID { focusITerm(uuid: uuid) }
            else if !session.tty.isEmpty { focusTerminal(tty: session.tty) }
        }
    }

    /// Focus an iTerm2 session by its unique id (from ITERM_SESSION_ID).
    static func focusITerm(uuid: String) {
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

    /// Focus a Terminal.app tab by its tty (e.g. /dev/ttys005) — Terminal's stable per-tab id.
    /// `set index of w to 1` is what reliably raises the right window when several are open.
    static func focusTerminal(tty: String) {
        let script = """
        tell application "Terminal"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(tty)" then
                set selected of t to true
                set frontmost of w to true
                set index of w to 1
                return
              end if
            end repeat
          end repeat
        end tell
        """
        runAppleScript(script, completion: { _ in })
    }

    /// Last resort: bring the terminal app forward without picking a specific tab.
    static func raiseApp(_ app: String) {
        runAppleScript("tell application \"\(app)\" to activate", completion: { _ in })
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
