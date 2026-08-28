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
    /// Set the window's `selected tab` directly, then raise it. Do NOT also set `index of w to 1`:
    /// reordering the window list fights `frontmost` and reliably lands on the wrong window when
    /// more than one is open.
    static func focusTerminal(tty: String) {
        let script = """
        tell application "Terminal"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(tty)" then
                set selected tab of w to t
                set frontmost of w to true
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

    // MARK: sending

    /// Outcome of a send attempt, so the panel can say what went wrong instead of failing silently.
    enum SendResult: Equatable {
        case ok
        case refused(String)
    }

    /// Foreground processes we're happy to see sharing the tty with claude. Claude Code
    /// spawns caffeinate itself; it never reads stdin, so it can't swallow a reply.
    private static let benignNeighbours: Set<String> = ["caffeinate"]

    /// Is it safe to type into this tty right now?
    ///
    /// `claude` must hold the foreground process group. Two failure modes this catches:
    /// at an idle shell prompt the shell itself holds the `+`, so injected text would be
    /// EXECUTED as a shell command; and if some other program is in the foreground it
    /// would swallow the text as its own stdin. Both have been observed, neither is
    /// recoverable once it happens, so this fails closed.
    static func foregroundCheck(tty: String) -> SendResult {
        guard !tty.isEmpty else { return .refused("no terminal recorded for this session") }
        let dev = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-t", dev, "-o", "stat=,command="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return .refused("couldn't inspect that terminal") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        var foreground: [String] = []
        for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
            // ps pads its columns, so split on whitespace rather than slicing prefixes —
            // slicing silently yields empty names and every check then passes by accident.
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let stat = fields.first, stat.contains("+"), fields.count > 1 else { continue }
            var name = String(fields[1])
            if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
            if name.hasPrefix("-") { name.removeFirst() }        // login shells arrive as -zsh
            if !name.isEmpty { foreground.append(name) }
        }

        if foreground.isEmpty { return .refused("that terminal isn't running anything") }
        let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "tcsh", "login"]
        if foreground.contains(where: { shells.contains($0) }) {
            return .refused("that tab is at a shell prompt, not in Claude")
        }
        guard foreground.contains("claude") else {
            return .refused("\(foreground.joined(separator: ", ")) is in the foreground, not Claude")
        }
        let strangers = foreground.filter { $0 != "claude" && !benignNeighbours.contains($0) }
        if !strangers.isEmpty {
            return .refused("\(strangers.joined(separator: ", ")) is reading that terminal")
        }
        return .ok
    }

    /// Type a reply into the session's terminal tab.
    ///
    /// Deliberately two steps. Claude Code's TUI treats injected text as a paste and
    /// absorbs its trailing newline, so the text lands in the prompt box UNSENT; a
    /// separate bare newline is what submits it. Verified on Terminal.app: one call
    /// stages, the second sends.
    static func send(text: String, to session: Session, submit: Bool = true,
                     completion: @escaping (SendResult) -> Void) {
        let body = text.split(whereSeparator: { $0.isNewline || $0 == "\r" })
                       .joined(separator: " ")
                       .trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { completion(.refused("nothing to send")); return }

        DispatchQueue.global(qos: .userInitiated).async {
            let check = foregroundCheck(tty: session.tty)
            if case .refused = check {
                DispatchQueue.main.async { completion(check) }
                return
            }
            let script: String
            switch session.termProgram {
            case "iTerm.app":
                guard let uuid = session.itermUUID else {
                    DispatchQueue.main.async { completion(.refused("no iTerm session id")) }
                    return
                }
                script = itermSendScript(uuid: uuid, body: body, submit: submit)
            default:
                script = terminalSendScript(tty: session.tty, body: body, submit: submit)
            }
            var error: NSDictionary?
            let out = NSAppleScript(source: script)?.executeAndReturnError(&error)
            let value = out?.stringValue ?? ""
            DispatchQueue.main.async {
                if error != nil { completion(.refused("the terminal refused the message")) }
                else if value != "ok" { completion(.refused("couldn't find that tab any more")) }
                else { completion(.ok) }
            }
        }
    }

    private static func terminalSendScript(tty: String, body: String, submit: Bool) -> String {
        let sendReturn = submit ? "\n          delay 0.35\n          do script \"\" in t" : ""
        return """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(escaped(tty))" then
                do script "\(escaped(body))" in t\(sendReturn)
                return "ok"
              end if
            end repeat
          end repeat
        end tell
        return "gone"
        """
    }

    private static func itermSendScript(uuid: String, body: String, submit: Bool) -> String {
        let sendReturn = submit ? "\n              delay 0.35\n              tell sess to write text \"\" newline YES" : ""
        return """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with sess in sessions of t
                if (unique id of sess) is "\(escaped(uuid))" then
                  tell sess to write text "\(escaped(body))" newline NO\(sendReturn)
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
        end tell
        return "gone"
        """
    }

    /// AppleScript string literals need both of these escaped, in this order.
    private static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
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
