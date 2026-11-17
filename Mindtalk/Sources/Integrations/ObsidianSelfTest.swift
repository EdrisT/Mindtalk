#if DEBUG
import Foundation

// MARK: - Mindtalk --obsidian-test
//
// The Obsidian integration against a vault in a throwaway folder: the folders Mindtalk
// makes, a meeting's text and json as the command line prints them, two meetings that
// want the same name, a meeting renamed (its folder and files follow), the mark that
// says a meeting has changed since it was written, and a thought from Tankar as a note.
//
// A test run is `previewing` (Settings.swift), so nothing a test does is kept in the
// settings and no meeting of yours is written into a vault you use: the vault here is
// made for the run and thrown away after it.
//
//   Mindtalk --obsidian-test                        a vault under the system's temp folder
//   Mindtalk --obsidian-test --vault <path>         there instead, and left where it is
//
// The meeting part needs a meeting that has been through its final pass; without one the
// rest still runs and the run says so.

enum ObsidianSelfTest {
    @MainActor static func run(arguments: [String]) async -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print(ok ? "  ok   \(what)" : "  FAIL \(what)")
            if !ok { failures += 1 }
        }
        let disk = FileManager.default
        let made: Bool
        let vault: URL
        if let path = Self.argument("--vault", in: arguments) {
            vault = URL(fileURLWithPath: path)
            made = !disk.fileExists(atPath: vault.path)
        } else {
            vault = disk.temporaryDirectory.appendingPathComponent("mindtalk-obsidian-\(UUID().uuidString.prefix(8))")
            made = true
        }
        try? disk.createDirectory(at: vault, withIntermediateDirectories: true)
        print("obsidian: vault \(vault.path)")

        // This run asks for writing, and only into the folder named above.
        Obsidian.testing = true
        Obsidian.shared.forgetForTesting()

        let obsidian = Obsidian.shared
        obsidian.setVault(vault)
        obsidian.enable(true)
        let meetings = vault.appendingPathComponent(Obsidian.defaultMeetings)
        let notes = vault.appendingPathComponent(Obsidian.defaultNotes)
        check(disk.fileExists(atPath: meetings.path), "the meetings folder was made")
        check(disk.fileExists(atPath: notes.path), "the notes folder was made")

        // A name Obsidian and the filesystem both take.
        let cleaned = ObsidianFiles.safe("Styrelsemöte/2026 #1 [ny] | viktig: stort")
        check(!cleaned.contains(where: { "/#[]|\n\u{0}".contains($0) }), "a name Obsidian takes: \"\(cleaned)\"")

        let store = MeetingStore.shared
        store.loadNow()
        let meeting = store.meetings.first { $0.refined && $0.finished && !$0.words.isEmpty }
        if let meeting {
            // Nothing goes into the vault before you ask for it: the card only offers.
            obsidian.observe(meeting)
            check(obsidian.state(meeting) == .fresh, "an unwritten meeting only waits to be asked")
            check(!disk.fileExists(atPath: meetings.appendingPathComponent(ObsidianFiles.name(of: meeting)).path),
                  "nothing was written on its own")
            check(obsidian.export(meeting), "the meeting was written")
            let name = ObsidianFiles.name(of: meeting)
            let folder = meetings.appendingPathComponent(name)
            let textURL = folder.appendingPathComponent("\(name) · transcript.md")
            let jsonURL = folder.appendingPathComponent("\(name).json")
            check(disk.fileExists(atPath: textURL.path), "its folder is \"\(name)\" and the text is inside it")
            check(!disk.fileExists(atPath: folder.appendingPathComponent("\(name).md").path),
                  "the plain \"\(name).md\" is left free for a summary")

            let text = (try? String(contentsOf: textURL, encoding: .utf8)) ?? ""
            let lines = text.components(separatedBy: "\n")
            print("    head: \(lines.first ?? "")")
            print("    line: \(lines.dropFirst(2).first ?? "")")
            check(!lines.isEmpty, "the text has a head line")
            check(text.contains("] "), "the text has its [mm:ss] turns")
            let json = (try? String(contentsOf: jsonURL, encoding: .utf8)) ?? ""
            let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
            check(object["id"] as? String == meeting.id.uuidString, "the json names the meeting")
            check(object["date"] != nil && object["speakers"] != nil, "the json has its date and its speakers")
            check(obsidian.state(meeting) == .current, "the card says the meeting is written")
            check(obsidian.canWrite == true, "Mindtalk knows it may write in the vault")

            // Two meetings on the same day with the same name: the second gets " (1)".
            var twin = meeting
            twin.id = UUID()
            check(obsidian.export(twin), "a second meeting of the same name was written")
            check(disk.fileExists(atPath: meetings.appendingPathComponent("\(name) (1)").path), "its folder is \"\(name) (1)\"")

            // Renamed: the folder and its files follow, and until it is written again the
            // card says the meeting has changed.
            var renamed = meeting
            renamed.title = "Omdöpt möte"
            obsidian.observe(renamed)
            check(obsidian.state(renamed) == .changed, "the card says the meeting has changed")
            check(obsidian.export(renamed), "the renamed meeting was written again")
            let moved = ObsidianFiles.name(of: renamed)
            check(disk.fileExists(atPath: meetings.appendingPathComponent(moved).appendingPathComponent("\(moved) · transcript.md").path),
                  "the folder followed the name: \"\(moved)\"")
            check(!disk.fileExists(atPath: folder.path), "the old folder is gone")
            check(obsidian.state(renamed) == .current, "and the card says it is written again")

            // The folder deleted in the vault while Mindtalk wasn't looking: nothing notices,
            // and the next press makes it again.
            try? disk.removeItem(at: meetings.appendingPathComponent(moved))
            obsidian.observe(renamed)
            check(obsidian.state(renamed) == .current, "a folder deleted behind its back goes unnoticed")
            check(obsidian.export(renamed), "the press writes it anyway")
            check(disk.fileExists(atPath: meetings.appendingPathComponent(moved).appendingPathComponent("\(moved) · transcript.md").path),
                  "and its folder is made again: \"\(moved)\"")
        } else {
            print("  -- no finished meeting: the meeting part was skipped")
        }

        // A thought from Tankar, as a note of its own: one file in the notes folder.
        let thought = Thought(text: "En tanke för testet", date: Date())
        obsidian.syncThoughts([thought])
        var writtenNotes = (try? disk.contentsOfDirectory(atPath: notes.path)) ?? []
        check(writtenNotes.contains { $0.hasSuffix(".md") }, "a thought became a note: \(writtenNotes.first ?? "(nothing)")")
        if let trouble = obsidian.trouble { print("    trouble: \(trouble)") }

        // The same words on the same day twice: the file gets " (1)", like a folder does.
        var again = thought
        again.id = UUID()
        obsidian.syncThoughts([thought, again])
        writtenNotes = (try? disk.contentsOfDirectory(atPath: notes.path)) ?? []
        check(writtenNotes.contains { $0.contains(" (1).md") }, "the same thought twice: \(writtenNotes.joined(separator: ", "))")

        // A vault Mindtalk is not let into: the card has to know, and have the way out to say.
        let locked = disk.temporaryDirectory.appendingPathComponent("mindtalk-obsidian-locked-\(UUID().uuidString.prefix(8))")
        try? disk.createDirectory(at: locked, withIntermediateDirectories: true)
        try? disk.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        obsidian.setVault(locked)
        check(obsidian.canWrite == false, "a vault it may not write in is noticed")
        check(obsidian.trouble != nil, "and the card says what to do: \(obsidian.trouble ?? "(nothing)")")
        try? disk.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        try? disk.removeItem(at: locked)
        obsidian.setVault(vault)

        if made { try? disk.removeItem(at: vault) } else { print("obsidian: left in \(vault.path)") }
        print(failures == 0 ? "obsidian: all good" : "obsidian: \(failures) thing(s) wrong")
        return failures == 0 ? 0 : 1
    }

    private static func argument(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
#endif
