import AppKit
import CryptoKit
import Foundation
import SwiftUI

// MARK: - Inställningar → Integrationer → Obsidian
//
// Obsidian is a folder of markdown files on this Mac: no server, no account, nothing
// to install. A meeting that has been through its final pass becomes a folder in the
// vault — the text as `mindtalk meeting <id> --text` prints it, and the meeting as
// json, the same object `--json` answers with. Thoughts from Tankar become notes in
// another folder.
//
// Written once, then not touched behind your back. A change anywhere in a meeting (a
// name, the title, a note, the date) is noticed and shown on that meeting's card
// under Möten, where a press writes it into the vault again. Rename the meeting and
// the folder and its two files follow. A meeting removed from Mindtalk keeps its
// files: they are yours now.
//
// Mindtalk is not sandboxed, so macOS asks nothing about writing to a folder — except
// ~/Desktop, ~/Documents and ~/Downloads, where a vault often lives. There is no way
// to ask beforehand, only to try: the write that macOS refuses is what says so, and
// the card then offers the privacy pane where the app can be allowed.
//
// What goes in the files — names, text, json, hashing — is ObsidianFiles below: no
// actor, so the self-test reads it without a window. Obsidian itself is the state on
// screen: whether it is on, where the vault is, and which meetings have changed since
// they were written.

// MARK: The files themselves

enum ObsidianFiles {
    private static var disk: FileManager { FileManager.default }

    /// The meeting's text exactly as `mindtalk meeting <id> --text` prints it.
    @MainActor static func text(_ record: MeetingRecord) -> String {
        let title = titled(record)
        let head = "\(title)  \(day(record.date)) \(clock(record.date))  \(length(Int(seconds(record).rounded())))"
        let lines = ClaudeTools.lines(of: record).map { ClaudeTools.render($0) }
        return ([head, ""] + (lines.isEmpty ? ["(nothing said)"] : lines)).joined(separator: "\n")
    }

    /// The meeting as json: the object `mindtalk meeting <id> --json` answers with.
    @MainActor static func json(_ record: MeetingRecord) -> String {
        let object = ClaudeTools.detail(record)
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// A thought as a note: what was said, and when.
    nonisolated static func text(of thought: Thought) -> String {
        let body = thought.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return "# \(day(thought.date)) \(clock(thought.date))\n\n\(body.isEmpty ? "(empty)" : body)\n"
    }

    /// The text and the json together, so a later change is seen.
    @MainActor static func hash(_ record: MeetingRecord) -> String {
        digest(text(record) + "\n" + json(record))
    }

    nonisolated static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Names

    /// "2026-11-05 Anna och Erik" — the day the meeting started, and its title.
    @MainActor static func name(of record: MeetingRecord) -> String {
        let base = safe("\(day(record.date)) \(titled(record))")
        return base.isEmpty ? day(record.date) : base
    }

    @MainActor static func name(of thought: Thought) -> String {
        let first = thought.text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first ?? ""
        let base = safe("\(day(thought.date)) \(first)")
        return base.isEmpty ? day(thought.date) : base
    }

    @MainActor private static func titled(_ record: MeetingRecord) -> String {
        record.title.isEmpty ? MeetingRecord.defaultTitle(for: record.date) : record.title
    }

    /// A name Obsidian and the filesystem both take: no slash, no newline, nothing that
    /// makes a wiki link or a heading, no trailing space or dot, and short enough to fit.
    nonisolated static func safe(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " -")
        for mark in ["\n", "\r", "\t", "#", "[", "]", "|", "^", "&", "%", "*", "\"", "<", ">", "?", "\u{0}"] {
            out = out.replacingOccurrences(of: mark, with: "")
        }
        out = out.replacingOccurrences(of: "  ", with: " ")
        out = out.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return String(out.prefix(120))
    }

    /// `base` under `parent`, with " (1)", " (2)"… after it when the name is taken — the
    /// way macOS and Windows put a second file of the same name beside the first. `own`
    /// is the place already belonging to this meeting, which is free to keep.
    nonisolated static func unique(_ parent: URL, _ base: String, insteadOf own: URL? = nil) -> URL {
        var candidate = parent.appendingPathComponent(base, isDirectory: true)
        var n = 1
        while candidate != own, disk.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base) (\(n))", isDirectory: true)
            n += 1
        }
        return candidate
    }

    /// The same rule for a file: the name is taken when a file of that name is already
    /// there, so the next one gets " (1)" — a thought said twice on one day.
    nonisolated static func uniqueFile(_ parent: URL, _ base: String, _ ext: String, insteadOf own: URL? = nil) -> URL {
        var candidate = parent.appendingPathComponent("\(base).\(ext)")
        var n = 1
        while candidate != own, disk.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    nonisolated static func relative(_ url: URL, under vault: URL) -> String {
        guard url.path.hasPrefix(vault.path) else { return url.lastPathComponent }
        return String(url.path.dropFirst(vault.path.count).dropFirst())
    }

    nonisolated static func exists(_ url: URL) -> Bool { disk.fileExists(atPath: url.path) }

    nonisolated static func create(_ folder: URL) throws {
        try disk.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    nonisolated static func move(_ from: URL, to: URL) throws { try disk.moveItem(at: from, to: to) }

    nonisolated static func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Dates, as the command line says them

    nonisolated static func day(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }
    nonisolated static func clock(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"; return f.string(from: date)
    }
    /// "42 min", "2 h 5 min" — as the CLI says a meeting's length.
    nonisolated static func length(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }
    nonisolated static func seconds(_ record: MeetingRecord) -> Double {
        record.duration > 0 ? record.duration : (record.words.last?.end ?? 0)
    }
}

// MARK: The integration

@MainActor
final class Obsidian: ObservableObject {
    static let shared = Obsidian()

    /// Where a meeting's two files are, and what was written in them.
    struct Written: Codable {
        /// The folder, from the vault's root: "Möten/2026-11-05 Anna och Erik".
        var folder: String
        /// The two files' names, so a rename finds them again.
        var text: String
        var json: String
        /// What was written; a change since then is seen by this.
        var hash: String
        var at: Date
    }

    /// What a meeting's card says about the vault.
    enum State {
        /// Nothing to show: the integration is off, or the meeting isn't ready for it.
        case off
        /// Not in the vault yet, but ready to be written.
        case fresh
        /// In the vault, as the meeting is now.
        case current
        /// In the vault, but Mindtalk has changed since it was written.
        case changed
    }

    static let defaultMeetings = "Meetings"
    static let defaultNotes = "Thoughts"

    @Published private(set) var enabled = false
    @Published private(set) var vault: URL?
    @Published private(set) var meetingsFolder = defaultMeetings
    @Published private(set) var notesFolder = defaultNotes
    /// Why Mindtalk couldn't write, in a few words; nil when it can.
    @Published private(set) var trouble: String?
    @Published private(set) var written: [UUID: Written] = [:]
    @Published private(set) var thoughts: [UUID: Written] = [:]
    /// Written meetings whose text or notes have changed since they were written.
    @Published private(set) var outOfDate: Set<UUID> = []
    /// Whether Mindtalk may write in the vault: nil until it has tried, then what the
    /// last try said. There is no permission to ask for beforehand — only one to be given.
    @Published private(set) var canWrite: Bool?

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: "obsidianOn")
        vault = Self.vaultFrom(defaults.data(forKey: "obsidianVault"))
        meetingsFolder = defaults.string(forKey: "obsidianMeetings") ?? Self.defaultMeetings
        notesFolder = defaults.string(forKey: "obsidianNotes") ?? Self.defaultNotes
        if let data = defaults.data(forKey: "obsidianWritten"),
           let read = try? JSONDecoder().decode([UUID: Written].self, from: data) { written = read }
        if let data = defaults.data(forKey: "obsidianThoughts"),
           let read = try? JSONDecoder().decode([UUID: Written].self, from: data) { thoughts = read }
        for id in written.keys where outOfDate.contains(id) { outOfDate.remove(id) }
    }

    #if DEBUG
    /// Only a self-test that asks for it writes while the app runs in preview: it points
    /// the vault at a folder of its own. Every other `--…-test` and `--render-…` run
    /// leaves somebody's vault alone.
    static var testing = false

    /// A self-test starts from nothing written: what the app has written in somebody's
    /// vault is no business of a run that points at a folder of its own.
    func forgetForTesting() { written = [:]; thoughts = [:]; outOfDate = [] }
    #endif

    /// Whether this run may write into the vault at all.
    private var mayWrite: Bool {
        #if DEBUG
        return !Settings.previewing || Self.testing
        #else
        return true
        #endif
    }

    var vaultPath: String { vault?.path ?? "" }

    // MARK: Setting it up

    func enable(_ on: Bool) {
        enabled = on
        Settings.keep(on, forKey: "obsidianOn")
        trouble = nil
        guard on else { return }
        ensureFolders()
        // Meetings changed while the integration was off: their cards should say so.
        Task {
            await MeetingStore.shared.ready()
            for record in MeetingStore.shared.meetings where written[record.id] != nil { observe(record) }
        }
    }

    /// The vault, chosen in the Finder. A bookmark is kept, so the same vault is still
    /// found after it is moved or renamed.
    func pickVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Vald valut")
        panel.message = String(localized: "Välj den mapp där Obsidian har dina anteckningar.")
        panel.directoryURL = vault
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setVault(url)
    }

    func setVault(_ url: URL) {
        vault = url
        Settings.keep(Self.bookmark(url), forKey: "obsidianVault")
        trouble = nil
        ensureFolders()
    }

    func setMeetingsFolder(_ name: String) {
        meetingsFolder = ObsidianFiles.safe(name).isEmpty ? Self.defaultMeetings : ObsidianFiles.safe(name)
        Settings.keep(meetingsFolder, forKey: "obsidianMeetings")
        ensureFolders()
    }

    func setNotesFolder(_ name: String) {
        notesFolder = ObsidianFiles.safe(name).isEmpty ? Self.defaultNotes : ObsidianFiles.safe(name)
        Settings.keep(notesFolder, forKey: "obsidianNotes")
        ensureFolders()
    }

    /// Both folders, when they aren't there yet, and a line written in each: the only
    /// honest way to know whether Mindtalk is let into the vault is to write there.
    @discardableResult
    func ensureFolders() -> Bool {
        guard let vault else {
            trouble = String(localized: "Välj valvet först — den mapp där Obsidian har sina anteckningar.")
            canWrite = nil
            return false
        }
        for name in [meetingsFolder, notesFolder] {
            let folder = vault.appendingPathComponent(name, isDirectory: true)
            if !ObsidianFiles.exists(folder) {
                do { try ObsidianFiles.create(folder) } catch { say(error, about: name); return false }
            }
            let probe = folder.appendingPathComponent(".mindtalk-prov")
            do {
                try ObsidianFiles.write(" ", to: probe)
                try FileManager.default.removeItem(at: probe)
            } catch { say(error, about: name); return false }
        }
        trouble = nil
        canWrite = true
        return true
    }

    /// macOS refusing a folder it protects, said as the way through rather than as a
    /// number: there is no permission to ask for beforehand, only one to be given.
    private func say(_ error: Error, about folder: String) {
        canWrite = false
        if Self.denied(error) {
            trouble = String(localized: "Mindtalk får inte skriva i „\(folder)”. Tillåt det under Systeminställningar → Sekretess → Filer och mappar.")
        } else {
            trouble = String(localized: "Mindtalk kunde inte skriva i „\(folder)”: \(error.localizedDescription)")
        }
    }

    nonisolated private static func denied(_ error: Error) -> Bool {
        let e = error as NSError
        if e.domain == NSCocoaErrorDomain, e.code == NSFileWriteNoPermissionError { return true }
        return e.domain == NSPOSIXErrorDomain && e.code == Int(EACCES)
    }

    /// The privacy pane where an app is let into a folder.
    static func openPermissionSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
    }

    // MARK: Watching meetings

    /// Every time a meeting is saved. Nothing is written by itself: a meeting you have
    /// written to the vault once lights up its card under Möten until you say to write it
    /// again, and a meeting never written waits there for you to ask.
    func observe(_ record: MeetingRecord) {
        // A render or a self-test never writes into somebody's vault; a test that wants
        // writing asks for it by name, in a folder of its own.
        guard mayWrite else { return }
        guard enabled, vault != nil, record.refined, written[record.id] != nil else { return }
        if ObsidianFiles.hash(record) != written[record.id]!.hash { outOfDate.insert(record.id) }
        else { outOfDate.remove(record.id) }
    }

    func state(_ record: MeetingRecord) -> State {
        guard enabled, vault != nil, record.refined, record.finished else { return .off }
        if written[record.id] == nil { return .fresh }
        return outOfDate.contains(record.id) ? .changed : .current
    }

    // MARK: Writing

    /// The meeting's folder and its two files — now, whatever has changed since.
    @discardableResult
    func export(_ record: MeetingRecord) -> Bool {
        guard mayWrite, let vault, ensureFolders() else { return false }
        let parent = vault.appendingPathComponent(meetingsFolder, isDirectory: true)
        let base = ObsidianFiles.name(of: record)
        let was = written[record.id]

        // The folder and the two files carry the meeting's name: renaming it moves them.
        // A folder that isn't there any more — deleted in Obsidian, or under a name the
        // settings have left — is made again where they point now.
        let path: String
        if let known = was?.folder, ObsidianFiles.exists(vault.appendingPathComponent(known)) {
            var here = known
            let from = vault.appendingPathComponent(known)
            if from.lastPathComponent != base {
                let moved = ObsidianFiles.unique(parent, base, insteadOf: from)
                do {
                    try ObsidianFiles.move(from, to: moved)
                    here = ObsidianFiles.relative(moved, under: vault)
                } catch { say(error, about: known); return false }
            }
            path = here
        } else {
            let made = ObsidianFiles.unique(parent, base)
            do { try ObsidianFiles.create(made) } catch { say(error, about: base); return false }
            path = ObsidianFiles.relative(made, under: vault)
        }
        let folder = vault.appendingPathComponent(path)

        // The files inside are named after the meeting too — but the transcript gives way:
        // the plain «<name>.md», the name Obsidian links to and the folder's own note, is
        // left free for a summary written by hand.
        let textURL = folder.appendingPathComponent("\(base) · transcript.md")
        let jsonURL = folder.appendingPathComponent("\(base).json")
        for (old, now) in [(was?.text ?? "", textURL), (was?.json ?? "", jsonURL)] {
            guard !old.isEmpty else { continue }
            let before = folder.appendingPathComponent(old)
            if before != now, ObsidianFiles.exists(before) { try? ObsidianFiles.move(before, to: now) }
        }

        let text = ObsidianFiles.text(record)
        let json = ObsidianFiles.json(record)
        do {
            try ObsidianFiles.write(text, to: textURL)
            try ObsidianFiles.write(json, to: jsonURL)
        } catch { say(error, about: path); return false }

        written[record.id] = Written(folder: path, text: textURL.lastPathComponent, json: jsonURL.lastPathComponent,
                                     hash: ObsidianFiles.digest(text + "\n" + json), at: Date())
        outOfDate.remove(record.id)
        keep()
        return true
    }

    /// Every thought Tankar has: written when it is said, and again when it changes.
    /// One removed from Mindtalk keeps its note.
    func syncThoughts(_ all: [Thought]) {
        guard mayWrite, enabled, vault != nil else { return }
        for thought in all where thought.deleted == nil {
            let text = ObsidianFiles.text(of: thought)
            let hash = ObsidianFiles.digest(text)
            if let note = thoughts[thought.id], note.hash == hash { continue }
            guard ensureFolders(), let vault else { return }
            let parent = vault.appendingPathComponent(notesFolder, isDirectory: true)
            // One file in the notes folder, named after the day and the thought's first
            // line. Revising a thought writes the same file again — a note's name must not
            // wander, Obsidian links are made to it.
            let name = thoughts[thought.id]?.text
            let url = name.map { parent.appendingPathComponent($0) }
                ?? ObsidianFiles.uniqueFile(parent, ObsidianFiles.name(of: thought), "md")
            do { try ObsidianFiles.write(text, to: url) } catch { say(error, about: notesFolder); return }
            thoughts[thought.id] = Written(folder: notesFolder, text: url.lastPathComponent, json: "", hash: hash, at: Date())
        }
        keep()
    }

    private func keep() {
        Settings.keep(try? JSONEncoder().encode(written), forKey: "obsidianWritten")
        Settings.keep(try? JSONEncoder().encode(thoughts), forKey: "obsidianThoughts")
    }

    nonisolated private static func bookmark(_ url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    nonisolated private static func vaultFrom(_ data: Data?) -> URL? {
        guard let data else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}
