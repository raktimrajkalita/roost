import Foundation
import AppKit

/// iTerm2 integration via AppleScript: fetch each session's tab name, and focus
/// a session by its unique id. Runs off the main thread so it never blocks the UI.
enum ITerm {

    /// Session display names: iTerm session names keyed by unique id (glyph + trailing
    /// "(job)" stripped), plus Terminal.app custom titles (the user's rename) keyed by tty.
    /// Both scripts are guarded by `is running` so a background refresh never launches a
    /// terminal that's closed.
    /// Names, plus the set of ttys that are actually terminal tabs.
    ///
    /// The second half matters more than it looks. A session's tty is not necessarily a
    /// visible tab: Claude Code's daemon runs background sessions on a pty owned by
    /// `claude bg-spare`, which is a real tty device attached to no window at all. Those
    /// sessions can never receive typed input, so the panel must not offer it.
    /// Last known set of real terminal tabs, kept so the send path can look for a host
    /// without waiting on another AppleScript round trip.
    private(set) static var liveTabs: Set<String> = []

    static func fetchNames(_ completion: @escaping ([String: String], Set<String>) -> Void) {
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
                set out to out & (tty of t) & d & ct & lf
              end repeat
            end repeat
          end tell
        end if
        return out
        """
        runAppleScript(itermScript) { itermOut in
            var map: [String: String] = [:]
            var live: Set<String> = []
            for line in (itermOut ?? "").split(separator: "\n") {          // iTerm: keyed by unique id
                // omittingEmptySubsequences MUST be false: a tab with no custom title emits
                // "<tty>\t" with nothing after it, which otherwise collapses to one field
                // and the tab is never recorded as live.
                let parts = line.split(separator: "\t", maxSplits: 1,
                                       omittingEmptySubsequences: false)
                if parts.count == 2 {
                    live.insert(String(parts[0]))                     // iTerm session id
                    if let name = clean(String(parts[1])) { map[String(parts[0])] = name }
                }
            }
            runAppleScript(terminalScript) { termOut in
                for line in (termOut ?? "").split(separator: "\n") {       // Terminal: user's custom title, keyed by tty
                    // omittingEmptySubsequences MUST be false: a tab with no custom title emits
                // "<tty>\t" with nothing after it, which otherwise collapses to one field
                // and the tab is never recorded as live.
                let parts = line.split(separator: "\t", maxSplits: 1,
                                       omittingEmptySubsequences: false)
                    if parts.count == 2 {
                        let tty = String(parts[0])
                        live.insert(tty)                              // a real Terminal tab
                        let title = String(parts[1]).trimmingCharacters(in: .whitespaces)
                        if !title.isEmpty { map[tty] = title }
                    }
                }
                liveTabs = live
                DispatchQueue.main.async { completion(map, live) }
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

    // MARK: reading the screen

    /// One line of a selector the session is showing.
    ///
    /// `offset` is steps DOWN from whatever is currently highlighted, which is how an
    /// unnumbered list has to be addressed: there is no name to send, only movement.
    struct PromptChoice: Equatable, Identifiable {
        let offset: Int
        let label: String
        let digit: Int?          // nil when the list isn't numbered
        var id: Int { offset }
        var selected: Bool { offset == 0 }
    }

    /// The choices a selector is showing, read off the terminal itself.
    ///
    /// Claude Code's Notification payload carries only prose ("needs your permission to
    /// use Bash"), never the choices, so they exist nowhere except on screen.
    static func promptChoices(for session: Session, completion: @escaping ([PromptChoice]) -> Void) {
        readScreen(for: session) { screen in
            DispatchQueue.main.async { completion(parseChoices(screen ?? "")) }
        }
    }

    /// The ttys Terminal is showing right now.
    static func liveTabsSync() -> Set<String> {
        let script = """
        set d to linefeed
        set out to ""
        if application "Terminal" is running then
          tell application "Terminal"
            repeat with w in windows
              repeat with t in tabs of w
                set out to out & (tty of t) & d
              end repeat
            end repeat
          end tell
        end if
        return out
        """
        var error: NSDictionary?
        let out = NSAppleScript(source: script)?.executeAndReturnError(&error)
        let text = out?.stringValue ?? ""
        return Set(text.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
                       .filter { !$0.isEmpty })
    }

    /// Read a Terminal tab's buffer by tty. Synchronous: the send path already runs off the
    /// main thread and needs the answer before it can decide where to type.
    static func readScreenSync(tty: String) -> String {
        let script = """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(escaped(tty))" then return history of t
            end repeat
          end repeat
        end tell
        return ""
        """
        var error: NSDictionary?
        let out = NSAppleScript(source: script)?.executeAndReturnError(&error)
        return out?.stringValue ?? ""
    }

    /// Reduce text to what survives being printed: lowercase letters, digits and single
    /// spaces.
    ///
    /// The transcript holds source, the terminal shows rendering. "**Working and proven:**"
    /// is stored with its asterisks and drawn without them, so comparing the two literally
    /// can never match. Box drawing, bullets, indentation and wrapping all differ the same
    /// way. What both sides agree on is the words.
    static func fingerprint(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var space = true                       // leading space suppressed
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber { out.append(ch); space = false }
            else if !space { out.append(" "); space = true }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Phrases this session has recently said, as fingerprints, for recognising it on screen.
    ///
    /// Several per message and several messages deep, because a terminal only keeps the
    /// visible screen: anything older has scrolled away, and the newest message may be half
    /// drawn. Slices from across each one give the match somewhere to land.
    static func signatures(transcriptPath: String, limit: Int = 6) -> [String] {
        guard !transcriptPath.isEmpty,
              let handle = FileHandle(forReadingAtPath: transcriptPath) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 300_000 ? size - 300_000 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        guard let blob = String(data: data, encoding: .utf8) else { return [] }

        var out: [String] = []
        for line in blob.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let msg = (obj["message"] as? [String: Any]) ?? obj
            guard (msg["role"] as? String) == "assistant" else { continue }
            var text = ""
            if let str = msg["content"] as? String { text = str }
            else if let parts = msg["content"] as? [[String: Any]] {
                text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                            .joined(separator: " ")
            }
            let flat = fingerprint(text)
            if flat.count > 45 { out.append(flat) }
        }

        // Take the tail of the conversation, then several windows from each message.
        var marks: [String] = []
        for msg in out.suffix(limit) {
            let chars = Array(msg)
            for start in stride(from: 0, to: max(chars.count - 40, 1), by: 60) {
                marks.append(String(chars[start..<min(start + 40, chars.count)]))
            }
        }
        return marks
    }

    /// Which tab to actually type into.
    ///
    /// A session usually owns its tab, and then this is trivial. But `claude agents`
    /// multiplexes several sessions into ONE tab, each on its own daemon pty, so those
    /// sessions have a tty that belongs to no window. They are still reachable: whichever
    /// pane the multiplexer is showing receives what you type. The question is only whether
    /// the pane on screen is the one you clicked, and the screen answers it, because the
    /// session's own words are printed there.
    ///
    /// Checked at send time, never cached: the pane on screen can change between reading it
    /// and typing, and a stale answer types into someone else's conversation.
    static func hostTTY(for session: Session) -> String? {
        // Asked fresh, never from the cache. `liveTabs` is refreshed on a 4s cycle for the
        // panel's benefit, which is fine for labelling rows and wrong for deciding where to
        // type: a tab opened since the last refresh would be declared not to exist, and the
        // reply would be refused on a session sitting right there.
        let tabs = liveTabsSync()
        let marks = signatures(transcriptPath: session.transcriptPath)

        func shows(_ tab: String) -> Bool {
            let screen = fingerprint(readScreenSync(tty: tab))
            return marks.contains(where: { screen.contains($0) })
        }

        // Owning a tty is not the same as owning the tab it names. tty numbers are recycled:
        // close a session and open another, and a dormant row's recorded /dev/ttys001 now
        // belongs to somebody else's conversation. So the tab has to be showing this session's
        // own words before it is trusted. A session that has not said anything yet has nothing
        // to check against, and is taken at its word.
        if !session.tty.isEmpty, tabs.contains(session.tty) {
            if marks.isEmpty || shows(session.tty) { return session.tty }
        }

        guard !marks.isEmpty else { return nil }
        for tab in tabs where tab.hasPrefix("/dev/") && tab != session.tty {
            if shows(tab) { return tab }
        }
        return nil
    }

    static func readScreen(for session: Session, completion: @escaping (String?) -> Void) {
        let script: String
        switch session.termProgram {
        case "iTerm.app":
            guard let uuid = session.itermUUID else { completion(nil); return }
            script = """
            tell application "iTerm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with sess in sessions of t
                    if (unique id of sess) is "\(escaped(uuid))" then return text of sess
                  end repeat
                end repeat
              end repeat
            end tell
            return ""
            """
        default:
            script = """
            tell application "Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(escaped(session.tty))" then return history of t
                end repeat
              end repeat
            end tell
            return ""
            """
        }
        runAppleScript(script, completion: completion)
    }

    /// Anchor on the ❯ cursor and read forward. Reading BACKWARD would be guesswork: the
    /// line above a selector is prose ("Security guide"), indistinguishable from an option
    /// by shape alone, and mistaking one for an option shifts every offset by one, which is
    /// how you end up confirming the wrong answer.
    static func parseChoices(_ screen: String) -> [PromptChoice] {
        let lines = screen.suffix(4000).split(separator: "\n", omittingEmptySubsequences: false)
                          .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let cursor = lines.lastIndex(where: { $0.hasPrefix("❯") }) else { return [] }

        var out: [PromptChoice] = []
        for j in cursor..<lines.count {
            var line = lines[j]
            if j == cursor { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if line.isEmpty { break }
            if line.count > 120 { break }
            if line.contains("Enter to confirm") || line.contains("Esc to cancel") { break }

            var digit: Int? = nil
            let lead = line.prefix(while: { $0.isNumber })
            if !lead.isEmpty, line.dropFirst(lead.count).hasPrefix(".") { digit = Int(lead) }
            out.append(PromptChoice(offset: j - cursor, label: line, digit: digit))
        }
        return out.count >= 2 ? out : []      // a single line isn't a choice
    }

    /// Answer a selector by picking one of its lines.
    ///
    /// Re-reads the screen first and refuses if the list moved under us. The gap between
    /// showing you a choice and you clicking it is long enough for the session to have
    /// moved on, and a stale offset lands on whatever is there now.
    static func choose(_ choice: PromptChoice, in session: Session,
                       completion: @escaping (SendResult) -> Void) {
        let check = foregroundCheck(tty: session.tty)
        if case .refused = check { completion(check); return }

        promptChoices(for: session) { fresh in
            guard let now = fresh.first(where: { $0.offset == choice.offset }),
                  now.label == choice.label else {
                completion(.refused("that prompt changed, look again"))
                return
            }
            let payload: String
            if let d = now.digit {
                payload = "\"\(d)\""                                   // numbered: unambiguous
            } else if now.offset == 0 {
                payload = "\"\""                                       // already highlighted
            } else {
                // (ASCII character 27) & "[B" is a down arrow; do script's own return confirms.
                payload = Array(repeating: "((ASCII character 27) & \"[B\")", count: now.offset)
                              .joined(separator: " & ")
            }
            let script = """
            tell application "Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(escaped(session.tty))" then
                    do script \(payload) in t
                    return "ok"
                  end if
                end repeat
              end repeat
            end tell
            return "gone"
            """
            runAppleScript(script) { out in
                DispatchQueue.main.async {
                    completion(out == "ok" ? .ok : .refused("couldn't reach that tab"))
                }
            }
        }
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
        // Newlines are kept. Verified against the TUI: a multi-line paste arrives as one
        // prompt with its line breaks intact, not as several submitted lines. The trailing
        // submit is still sent either way; a redundant Enter on an empty box does nothing.
        let body = text.replacingOccurrences(of: "\r\n", with: "\n")
                       .replacingOccurrences(of: "\r", with: "\n")
                       .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { completion(.refused("nothing to send")); return }

        DispatchQueue.global(qos: .userInitiated).async {
            // Where the words actually have to go, which is not always this session's own tty.
            guard let host = hostTTY(for: session) else {
                DispatchQueue.main.async {
                    completion(.refused("this session isn't the one on screen · switch to it first"))
                }
                return
            }
            let check = foregroundCheck(tty: host)
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
                script = terminalSendScript(tty: host, body: body, submit: submit)
            }
            var error: NSDictionary?
            let out = NSAppleScript(source: script)?.executeAndReturnError(&error)
            let value = out?.stringValue ?? ""
            DispatchQueue.main.async {
                if error != nil { completion(.refused("the terminal refused the message")) }
                else if value != "ok" { completion(.refused("that session has no terminal window")) }
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

    /// Make a Swift string safe inside an AppleScript string literal.
    ///
    /// Order matters: backslashes first, then quotes. Newlines can't appear in an
    /// AppleScript literal at all, so they're spliced out into `& linefeed &` instead,
    /// which is what lets a multi-line reply survive the trip.
    private static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\" & linefeed & \"")
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
