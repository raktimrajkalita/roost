import AppKit
import Foundation

/// Self-update over the same path people install by: pull, rebuild, reinstall.
///
/// Roost is distributed as source (clone + `./build-app.sh --install`), so there's no release
/// feed to poll and no notarised bundle to swap in. Instead `build-app.sh` stamps the commit and
/// the source directory into Info.plist, and this asks GitHub how far `main` has moved since.
enum Updater {
    static let repo = "raktimrajkalita/roost"

    /// The commit this app was built from (stamped by build-app.sh).
    static var localCommit: String {
        (Bundle.main.object(forInfoDictionaryKey: "RoostCommit") as? String) ?? ""
    }

    /// The clone it was built from — only usable if it's still a git repo on this disk.
    static var sourcePath: String? {
        guard let p = Bundle.main.object(forInfoDictionaryKey: "RoostSourcePath") as? String,
              FileManager.default.fileExists(atPath: (p as NSString).appendingPathComponent(".git"))
        else { return nil }
        return p
    }

    struct Failure: Error { let message: String }

    struct Available {
        let count: Int          // commits main is ahead of this build
        let notes: [String]     // their subject lines, oldest first
    }

    // MARK: check

    /// Asks GitHub to compare this build's commit against main. `nil` means already current.
    static func check(_ done: @escaping (Result<Available?, Failure>) -> Void) {
        guard !localCommit.isEmpty else {
            return done(.failure(Failure(message: "This build has no commit stamp — rebuild with ./build-app.sh.")))
        }
        guard let url = URL(string:
            "https://api.github.com/repos/\(repo)/compare/\(localCommit)...main") else {
            return done(.failure(Failure(message: "Bad update URL.")))
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 12
        URLSession.shared.dataTask(with: req) { data, _, err in
            DispatchQueue.main.async {
                if let err { return done(.failure(Failure(message: err.localizedDescription))) }
                guard let data,
                      let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return done(.failure(Failure(message: "Couldn't read GitHub's reply."))) }
                // an unknown commit (e.g. a local-only build) comes back as a plain message
                guard o["ahead_by"] != nil else {
                    return done(.failure(Failure(message: (o["message"] as? String) ?? "GitHub couldn't compare this build.")))
                }
                let ahead = (o["ahead_by"] as? Int) ?? 0
                guard ahead > 0 else { return done(.success(nil)) }
                let commits = (o["commits"] as? [[String: Any]]) ?? []
                let notes = commits.compactMap { c -> String? in
                    guard let m = (c["commit"] as? [String: Any])?["message"] as? String else { return nil }
                    return m.split(separator: "\n").first.map(String.init)
                }
                done(.success(Available(count: ahead, notes: notes)))
            }
        }.resume()
    }

    // MARK: install

    /// Pull, rebuild and reinstall from a detached script, because `build-app.sh --install`
    /// kills and relaunches Roost — the updater has to outlive the app it's replacing.
    /// Refuses to touch a repo with uncommitted work, and only fast-forwards.
    static func install(from repoPath: String, done: @escaping (String?) -> Void) {
        let log = NSTemporaryDirectory() + "roost-update.log"
        // Progress is real, not timed: SwiftPM prints "[N/M] Compiling …", so the compile phase
        // has a true fraction. The short phases either side get fixed weights.
        let script = """
        #!/bin/bash
        exec > "\(log)" 2>&1
        set -e
        PROG="$HOME/.claude-notch/update-progress"
        cd \(shQuote(repoPath))
        if [ -n "$(git status --porcelain)" ]; then
          echo "DIRTY"
          echo "-1" > "$PROG"
          osascript -e 'display notification "Uncommitted changes in the source folder — update skipped." with title "Roost"' || true
          exit 3
        fi
        echo 2 > "$PROG"
        git fetch --quiet origin main
        echo 8 > "$PROG"
        git merge --ff-only --quiet origin/main
        echo 12 > "$PROG"
        ./build-app.sh --install 2>&1 | while IFS= read -r line; do
          echo "$line"
          case "$line" in
            \\[*/*\\]*)
              frac="${line%%]*}"; frac="${frac#[}"
              n="${frac%%/*}"; m="${frac##*/}"
              if [ -n "$m" ] && [ "$m" -gt 0 ] 2>/dev/null; then
                echo $(( 12 + n * 73 / m )) > "$PROG"
              fi ;;
            *assembling*) echo 87 > "$PROG" ;;
            *signing*)    echo 92 > "$PROG" ;;
            *installing*) echo 97 > "$PROG" ;;
          esac
        done
        echo 100 > "$PROG"
        # marker: the next launch reads this and shows "updated" in the panel
        touch "$HOME/.claude-notch/updated"
        """
        let path = NSTemporaryDirectory() + "roost-update.sh"
        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        } catch {
            return done("Couldn't stage the updater: \(error.localizedDescription)")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [path]
        // detach: this process is about to be killed by the script it started
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return done("Couldn't start the updater: \(error.localizedDescription)") }
        done(nil)
    }

    static var progressPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude-notch/update-progress")
    }

    /// Percent written by the running updater; nil if it hasn't reported yet, -1 if it bailed.
    static func readProgress() -> Int? {
        guard let s = try? String(contentsOfFile: progressPath, encoding: .utf8) else { return nil }
        return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
