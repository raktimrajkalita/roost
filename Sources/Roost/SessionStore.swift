import Foundation

/// One Claude Code session, as reported into ~/.claude-notch/state/<id>.json
struct Session: Identifiable {
    let id: String          // state filename, e.g. "0e11dc….json"
    var project: String     // cwd basename (fallback name)
    var status: String      // thinking | done | waiting | idle
    var lastAction: String
    var updated: Double
    var itermSession: String
    var termProgram: String
    var tty: String = ""    // controlling tty (e.g. /dev/ttys005) — Terminal.app's per-tab id
    var doneAt: Double = 0  // when it finished — the done indicator resolves once from here, then rests
    var displayName: String // resolved iTerm tab name, or project
    var muted: Bool = false
    var message: String = ""          // full reply or prompt text — what the reply view shows
    var transcriptPath: String = ""
    var promptKind: String = ""       // permission | input | idle | ""
    var attached: Bool = false        // its tty really is a terminal tab we can type into
    var renamed: Bool = false         // displayName came from you, not the terminal

    var itermUUID: String? {
        guard let range = itermSession.range(of: ":") else { return nil }
        return String(itermSession[range.upperBound...])
    }

    /// Whether Roost can offer a reply box for this row.
    ///
    /// Only one requirement: the session is in a terminal window we can type into. Status
    /// deliberately does NOT gate this. Gating on waiting/done hid the field whenever a
    /// session was working, which is most of the time, and Claude Code queues input while
    /// it works anyway, so there was nothing to protect against.
    ///
    /// This is an affordance test, not a safety check. The tty guard on the send path is
    /// what decides whether typing is actually safe at that moment.
    var replyable: Bool { attached }

    /// A numbered selector wants a digit, not prose.
    var wantsDigit: Bool { promptKind == "permission" }

    var statusGlyph: String {
        switch status {
        case "done": return "✓"
        case "waiting": return "!"
        case "thinking": return "◐"
        default: return "○"
        }
    }
}

/// Reads and watches the state directory the Python reporter writes to.
/// This is the whole data layer — identical source of truth as the Hammerspoon build.
final class SessionStore {
    private(set) var sessions: [Session] = []       // what the panel shows (filtered)
    private(set) var allSessions: [Session] = []    // every session on disk, for search
    var onChange: (() -> Void)?

    /// Search every session ever reported — including ones long dormant and dropped from the panel.
    func search(_ query: String) -> [Session] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return allSessions.filter {
            $0.displayName.lowercased().contains(q)
            || $0.project.lowercased().contains(q)
            || $0.lastAction.lowercased().contains(q)
        }
    }

    private let stateDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude-notch/state")
    private let muteDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude-notch/mutes")
    private let nameDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude-notch/names")
    private var dismissedDoneBefore: Double = 0   // done rows finished before this are hidden (cleared by a refresh)
    private var dismissedBefore: [String: Double] = [:]   // per-session dismiss — hidden until its next update
    private var keptIds: Set<String> = []                 // pulled back onto the panel from search
    private var pollTimer: Timer?
    private var names: [String: String] = [:]   // iTerm uuid -> cleaned tab name
    private var liveTabs: Set<String> = []      // ttys / session ids that are real tabs

    // MARK: lifecycle

    func start() {
        reload()
        refreshNames()
        // simple, reliable 1s poll (FSEvents can come later)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.reload()
        }
        // names change rarely; refresh every 4s
        Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.refreshNames()
        }
    }

    /// Force a full re-fetch: clear all currently-done rows, re-read state + re-pull iTerm tab names.
    /// Done rows stay hidden until a NEW completion arrives (done_at after this moment).
    func forceRefresh() {
        dismissedDoneBefore = Date().timeIntervalSince1970
        reload()
        refreshNames()
    }

    /// Dismiss one session from the panel; it comes back the moment that session next updates.
    func dismiss(id: String) {
        keptIds.remove(id)                                // ✕ overrides a keep
        dismissedBefore[id] = Date().timeIntervalSince1970
        reload()
    }

    /// Pull a session back onto the panel from search — the inverse of dismiss. It's exempt from
    /// the dormancy cutoff and from any earlier dismissal until you ✕ it or Roost restarts.
    func keep(id: String) {
        keptIds.insert(id)
        dismissedBefore.removeValue(forKey: id)
        reload()
    }

    func isKept(_ id: String) -> Bool { keptIds.contains(id) }

    /// Give a session your own name, or clear it back to the terminal's.
    ///
    /// Stored per session rather than per tab: a tab title is whatever Claude Code last set
    /// it to and gets overwritten, whereas a name you chose should outlast that.
    func rename(id: String, to name: String) {
        let fid = (id as NSString).deletingPathExtension
        let path = (nameDir as NSString).appendingPathComponent(fid)
        let fm = FileManager.default
        try? fm.createDirectory(atPath: nameDir, withIntermediateDirectories: true)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { try? fm.removeItem(atPath: path) }
        else { try? trimmed.write(toFile: path, atomically: true, encoding: .utf8) }
        reload()
    }

    /// Toggle the per-session mute flag the reporter checks before playing the chime.
    func toggleMute(id: String) {
        let fid = (id as NSString).deletingPathExtension
        let path = (muteDir as NSString).appendingPathComponent(fid)
        let fm = FileManager.default
        try? fm.createDirectory(atPath: muteDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: path) { try? fm.removeItem(atPath: path) }
        else { fm.createFile(atPath: path, contents: nil) }
        reload()
    }

    var menuBarTitle: String {
        var t = 0, d = 0, w = 0
        for s in sessions {
            switch s.status {
            case "thinking": t += 1
            case "done": d += 1
            case "waiting": w += 1
            default: break
            }
        }
        var parts: [String] = []
        if w > 0 { parts.append("!\(w)") }
        if t > 0 { parts.append("◐\(t)") }
        if d > 0 { parts.append("✓\(d)") }
        return parts.isEmpty ? "○" : parts.joined(separator: " ")
    }

    // MARK: reading state

    private func reload() {
        let fm = FileManager.default
        let now = Date().timeIntervalSince1970
        var out: [Session] = []
        var everything: [Session] = []

        guard let files = try? fm.contentsOfDirectory(atPath: stateDir) else {
            if !sessions.isEmpty { sessions = []; allSessions = []; onChange?() }
            return
        }

        for f in files where f.hasSuffix(".json") {
            let path = (stateDir as NSString).appendingPathComponent(f)
            guard let data = fm.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let updated = (obj["updated"] as? Double) ?? now

            var status = (obj["status"] as? String) ?? "idle"
            let lastAction = (obj["last_action"] as? String) ?? ""
            let low = lastAction.lowercased()
            if status == "waiting" && low.contains("waiting for") { status = "done" }   // idle ping, not a prompt
            if status == "thinking" && now - updated > 300 { status = "done" }           // silent 5 min -> idle

            let project = (obj["project"] as? String) ?? "session"
            let iterm = (obj["iterm_session"] as? String) ?? ""
            var s = Session(
                id: f, project: project, status: status, lastAction: lastAction,
                updated: updated, itermSession: iterm,
                termProgram: (obj["term_program"] as? String) ?? "",
                displayName: project
            )
            s.tty = (obj["tty"] as? String) ?? ""
            s.doneAt = (obj["done_at"] as? Double) ?? updated
            s.message = (obj["message"] as? String) ?? ""
            s.transcriptPath = (obj["transcript_path"] as? String) ?? ""
            s.promptKind = (obj["prompt_kind"] as? String) ?? ""
            // A tty alone proves nothing: background sessions run on a daemon-owned pty
            // that belongs to no window. Only a tty the terminal itself lists can be typed into.
            s.attached = (s.itermUUID.map { liveTabs.contains($0) } ?? false)
                      || (!s.tty.isEmpty && liveTabs.contains(s.tty))
            if let uuid = s.itermUUID, let name = names[uuid] { s.displayName = name }   // iTerm session name
            else if !s.tty.isEmpty, let name = names[s.tty] { s.displayName = name }      // Terminal.app custom title (rename)
            let fid = (f as NSString).deletingPathExtension
            // A name you chose wins over anything the terminal reports.
            if let custom = try? String(contentsOfFile: (nameDir as NSString).appendingPathComponent(fid),
                                        encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               !custom.isEmpty {
                s.displayName = custom
                s.renamed = true
            }
            s.muted = fm.fileExists(atPath: (muteDir as NSString).appendingPathComponent(fid))

            everything.append(s)                                  // search sees every session, however old

            // visibility filters — these only affect the panel list, never search.
            // A kept session skips them all: you asked for it explicitly.
            if !keptIds.contains(f) {
                if now - updated > 20 * 60 { continue }               // drop dormant (>20 min)
                if let d = dismissedBefore[f], updated <= d { continue }   // dismissed; back on its next update
                if status == "done" && s.doneAt < dismissedDoneBefore { continue }   // a refresh cleared it
            }
            out.append(s)
        }

        let order = ["waiting": 1, "thinking": 2, "done": 3]
        out.sort { (order[$0.status] ?? 9, -$0.updated) < (order[$1.status] ?? 9, -$1.updated) }
        everything.sort { $0.updated > $1.updated }
        allSessions = everything

        if !sameOrder(out, sessions) {
            sessions = out
            onChange?()
        } else {
            sessions = out   // keep fresh values even if the visible shape is unchanged
        }
    }

    private func sameOrder(_ a: [Session], _ b: [Session]) -> Bool {
        guard a.count == b.count else { return false }
        for i in a.indices {
            if a[i].id != b[i].id || a[i].status != b[i].status
                || a[i].lastAction != b[i].lastAction || a[i].displayName != b[i].displayName
                || a[i].muted != b[i].muted
                || a[i].message != b[i].message || a[i].promptKind != b[i].promptKind
                || a[i].attached != b[i].attached || a[i].renamed != b[i].renamed { return false }
        }
        return true
    }

    // MARK: iTerm tab names (placeholder — wired to AppleScript next)

    private func refreshNames() {
        ITerm.fetchNames { [weak self] map, live in
            guard let self else { return }
            if map != self.names || live != self.liveTabs {
                self.names = map
                self.liveTabs = live
                self.reload()
            }
        }
    }
}
