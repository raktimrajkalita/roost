import SwiftUI
import AppKit

// A design harness for the reply UI: `Roost --preview` opens an ordinary window with every
// state on screen at once. The notch panel only shows one state at a time and only when a
// real session happens to be in it, which makes iterating on the visuals painfully slow.
//
// This is developer scaffolding, not a feature. It never runs unless the flag is passed.

/// Notes typed against each card, saved to a file so feedback survives closing the window
/// and can be read back without you having to retype it into chat.
final class PreviewNotes: ObservableObject {
    @Published var notes: [String: String] = [:]
    @Published var savedAt: String = ""

    static let path = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".claude-notch/preview-feedback.md")

    func binding(_ key: String) -> Binding<String> {
        Binding(get: { self.notes[key] ?? "" },
                set: { self.notes[key] = $0 })
    }

    func save() {
        let written = notes.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        var out = "# Roost preview feedback\n\n"
        if written.isEmpty {
            out += "_no notes_\n"
        } else {
            for key in written.keys.sorted() {
                out += "## \(key)\n\(written[key]!)\n\n"
            }
        }
        try? out.write(toFile: Self.path, atomically: true, encoding: .utf8)
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        savedAt = "saved \(f.string(from: Date())) · \(written.count) note(s)"
    }
}

/// Stand-in sessions. Nothing here touches the state directory or any terminal.
private func previewSession(_ name: String, status: String, message: String,
                            kind: String, lastAction: String = "") -> Session {
    var s = Session(id: name, project: name, status: status, lastAction: lastAction,
                    updated: Date().timeIntervalSince1970, itermSession: "",
                    termProgram: "Apple_Terminal", displayName: name)
    s.tty = "/dev/ttys000"
    s.message = message
    s.promptKind = kind
    s.doneAt = Date().timeIntervalSince1970 - 45
    return s
}

private let shortReply = "Build is green. All 12 tests pass."

private let longReply = """
Fixed. The panel was closing because the hover loop had no idea the reply view was open, \
so the moment the pointer left the notch it started the collapse timer.

The latch is one clause in `tick()`, next to the one search already had. While `replyingTo` \
is set the panel counts as wanted, regardless of where the pointer is.

Worth knowing: this also means a stuck reply view would pin the panel open forever, so the \
click-away monitor and esc both have to clear it. Both do.
"""

private let permissionPrompt =
    "Claude needs your permission to use Bash\n\nrm -rf /Users/jay/roost/.build\n\n" +
    "Choose an option below to continue."

/// One labelled card, so several states can sit side by side.
private struct PreviewCard: View {
    let title: String
    let session: Session
    let state: SendState
    @ObservedObject var notes: PreviewNotes
    var choices: [ITerm.PromptChoice] = []
    @State private var draft: String
    @FocusState private var focused: Bool

    init(title: String, session: Session, state: SendState,
         notes: PreviewNotes, choices: [ITerm.PromptChoice] = [], draft: String = "") {
        self.title = title
        self.session = session
        self.state = state
        self.notes = notes
        self.choices = choices
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(.white.opacity(0.35))
            ReplyView(session: session, draft: $draft, focused: $focused, state: state,
                      messageHeight: replyMessageHeight(for: session),
                      choices: choices,
                      onSend: {}, onCancel: {})
                .padding(.vertical, 11)
                .frame(width: 380)
                .background(Color.black.opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08), lineWidth: 1))
            NoteField(text: notes.binding(title), onCommit: notes.save)
        }
    }
}

/// One note per card. Enter saves the whole file, so feedback is never lost to a stray close.
private struct NoteField: View {
    @Binding var text: String
    var onCommit: () -> Void
    var body: some View {
        TextField("note on this one…", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...4)
            .font(.system(size: 11.5))
            .foregroundColor(.white.opacity(0.8))
            .onSubmit(onCommit)
            .onChange(of: text) { _ in onCommit() }   // never lose a note to closing the window
            .padding(.horizontal, 9).padding(.vertical, 6)
            .frame(width: 380, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(text.isEmpty ? .white.opacity(0.07) : .white.opacity(0.18), lineWidth: 1))
    }
}

/// Rows, so the new reply affordance can be checked against the existing controls.
/// Hover a row to see them.
private struct RowStrip: View {
    @ObservedObject var notes: PreviewNotes
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("ROWS — hover to reveal the controls")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(.white.opacity(0.35))
            VStack(spacing: 3) {
                RowView(session: previewSession("waiting on you", status: "waiting",
                                                message: permissionPrompt, kind: "permission",
                                                lastAction: "Claude needs your permission to use Bash"),
                        onFocus: { _ in }, onMute: { _ in }, onDismiss: { _ in },
                        onKeep: { _ in }, onReply: { _ in })
                RowView(session: previewSession("a long session name that runs on", status: "done",
                                                message: shortReply, kind: "input",
                                                lastAction: "Claude: Build is green. All 12 tests pass."),
                        onFocus: { _ in }, onMute: { _ in }, onDismiss: { _ in },
                        onKeep: { _ in }, onReply: { _ in })
                RowView(session: previewSession("still working", status: "thinking",
                                                message: "", kind: "",
                                                lastAction: "Read NotchController.swift"),
                        onFocus: { _ in }, onMute: { _ in }, onDismiss: { _ in },
                        onKeep: { _ in }, onReply: { _ in })
            }
            .frame(width: 380)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08), lineWidth: 1))
            NoteField(text: notes.binding("ROWS"), onCommit: notes.save)
        }
    }
}

struct PreviewGallery: View {
    @StateObject private var notes = PreviewNotes()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Roost reply view")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                    Text("type a note under any card, enter saves")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }

                HStack(spacing: 10) {
                    Button(action: notes.save) {
                        Text("Save notes")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(Capsule().fill(Color(red: 0.48, green: 0.64, blue: 1.0)))
                    }
                    .buttonStyle(.plain)
                    Text(notes.savedAt.isEmpty ? PreviewNotes.path : notes.savedAt)
                        .font(.system(size: 10.5))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1).truncationMode(.head)
                }

                RowStrip(notes: notes)

                PreviewCard(title: "finished, short reply",
                            session: previewSession("aina main", status: "done",
                                                    message: shortReply, kind: "input"),
                            state: .idle, notes: notes)

                PreviewCard(title: "finished, long reply (scrolls past 9 lines)",
                            session: previewSession("roost", status: "done",
                                                    message: longReply, kind: "input"),
                            state: .idle, notes: notes)

                PreviewCard(title: "permission prompt, options read off the terminal",
                            session: previewSession("myproj", status: "waiting",
                                                    message: permissionPrompt, kind: "permission"),
                            state: .idle, notes: notes,
                            choices: [
                                .init(offset: 0, label: "1. Yes", digit: 1),
                                .init(offset: 1, label: "2. Yes, and don't ask again for rm commands", digit: 2),
                                .init(offset: 2, label: "3. No, and tell Claude what to do differently", digit: 3)])

                PreviewCard(title: "unnumbered selector — answered with arrow keys",
                            session: previewSession("myproj", status: "waiting",
                                                    message: "Quick safety check: is this a project you trust?",
                                                    kind: "permission"),
                            state: .idle, notes: notes,
                            choices: [
                                .init(offset: 0, label: "No, exit", digit: nil),
                                .init(offset: 1, label: "Yes, I trust this folder", digit: nil)])

                PreviewCard(title: "permission prompt with nothing readable on screen",
                            session: previewSession("myproj", status: "waiting",
                                                    message: permissionPrompt, kind: "permission"),
                            state: .idle, notes: notes)

                PreviewCard(title: "nothing captured yet",
                            session: previewSession("quiet session", status: "done",
                                                    message: "", kind: "input"),
                            state: .idle, notes: notes)

                PreviewCard(title: "sending", session: previewSession("aina main", status: "done",
                                                                     message: shortReply, kind: "input"),
                            state: .sending, notes: notes, draft: "looks good, ship it")

                PreviewCard(title: "sent", session: previewSession("aina main", status: "done",
                                                                   message: shortReply, kind: "input"),
                            state: .sent, notes: notes)

                PreviewCard(title: "refused by the tty guard",
                            session: previewSession("aina main", status: "done",
                                                    message: shortReply, kind: "input"),
                            state: .failed("that tab is at a shell prompt, not in Claude"), notes: notes)
            }
            .padding(30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(red: 0.07, green: 0.07, blue: 0.08))
    }
}

final class PreviewController: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 900),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Roost — reply view preview"
        window.contentView = NSHostingView(rootView: PreviewGallery())
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}
