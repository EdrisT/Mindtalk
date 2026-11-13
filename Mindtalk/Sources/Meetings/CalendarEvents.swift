import AppKit
import EventKit
import Foundation
import os
import SwiftUI

// MARK: - The calendar beside a meeting (Settings → Möten → Kalender)
//
// A meeting in the room is usually a meeting in the calendar too. When recording
// starts, Mindtalk looks for the event that is going on, or begins within ten
// minutes: its name, who was invited and how they answered, what the invitation
// says, and when it runs. That goes in the meeting's own file, under "calendar" —
// one section, apart from the transcript, so it can be read as what the meeting was
// *meant* to be, never as what happened.
//
// The calendar is read, never written: Mindtalk adds nothing to it and changes
// nothing. What it finds stays on the Mac, in the meeting's folder; with MCP on, the
// meeting's text is what an AI app may read, so what follows from that is said on the
// card.
//
// The event is only ever a *suggestion* about people. An attendee is a name Mindtalk
// offers when it asks who is speaking — never a name it assigns to a voice by itself.
//
// The searching is a plain function over `CalendarMeeting` values (`matching`), not a
// query against EventKit: that's what `--calendar-test` can check without your
// calendar, without a permission prompt, and without writing anything.

// MARK: - What was found

/// One person invited to an event.
struct CalendarPerson: Codable, Equatable {
    /// How they answered the invitation. `.pending` covers "not answered" and
    /// "optional": both say nothing about whether they'll be there.
    enum Answer: String, Codable {
        case organizer, accepted, declined, tentative, pending
    }

    var name: String
    var answer: Answer

    /// The address, kept only to recognise the same person in another meeting or under
    /// another spelling of their name. Never shown, never in an export, never over MCP.
    var key: String? = nil

    nonisolated var declined: Bool { answer == .declined }
}

/// An event in the calendar, as Mindtalk keeps it: what the invitation says, not what
/// happened in the room.
struct CalendarMeeting: Identifiable, Codable, Equatable {
    /// How this event came to the meeting.
    enum Match: String, Codable {
        /// It was already going when recording started.
        case running
        /// It starts within the next ten minutes.
        case soon
        /// More than one matched; you said which.
        case chosen
    }

    /// The event's own id, as EventKit gives it. A repeated meeting gets one per
    /// occurrence, which is what a meeting in the room is.
    var eventID: String
    /// The same as the event's id: what a list of them is drawn from.
    var id: String { eventID }
    /// Which calendar it came from, by that calendar's name.
    var calendar: String
    var title: String
    /// nil when the times were not asked for.
    var start: Date?
    var end: Date?
    /// The text in the invitation: someone else's words, cleaned and capped.
    var notes: String? = nil
    /// Where it is: a room, or the link to the call. One line.
    var location: String? = nil
    var people: [CalendarPerson] = []
    /// How *you* answered, when the event says: an event you declined is not offered.
    var mine: CalendarPerson.Answer? = nil
    var match: Match

    /// Names worth offering as speakers. Nobody who said they won't come.
    nonisolated var names: [String] {
        var seen = Set<String>()
        return people.filter { !$0.declined }
            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// The one who called the meeting, when the calendar says.
    nonisolated var organizer: String? { people.first { $0.answer == .organizer }?.name }

    /// A line for the screen: "Styrningsmöte 14:00–15:00 · 5 inbjudna". Times left out
    /// when they weren't asked for.
    nonisolated func shown(date: DateFormatter = Self.timeFormatter) -> String {
        var line = title.isEmpty ? "—" : title
        if let start, let end { line += " \(date.string(from: start))–\(date.string(from: end))" }
        let coming = people.filter { !$0.declined }.count
        if coming > 0 { line += " · " + String(localized: "inbjudna: \(coming)") }
        return line
    }

    nonisolated static var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }
}

/// What follows a meeting into its file. Off here: not read out of the calendar at all,
/// so it is never written and never leaves through an export or MCP.
struct CalendarFields: Codable, Equatable {
    var title = true
    var people = true
    var notes = true
    var location = true
    var times = true

    static let standard = CalendarFields()
    static let storageKey = "calendar.fields"

    /// Only what the settings ask for. The event's id and which calendar it came from
    /// always stay: without them the meeting says nothing about where it was.
    nonisolated func kept(_ event: CalendarMeeting) -> CalendarMeeting {
        var kept = event
        if !title { kept.title = "" }
        if !times { kept.start = nil; kept.end = nil }
        if !notes { kept.notes = nil }
        if !location { kept.location = nil }
        if !people { kept.people = [] }
        return kept
    }

    nonisolated static func read(in defaults: UserDefaults) -> CalendarFields {
        guard let data = defaults.data(forKey: storageKey),
              let fields = try? JSONDecoder().decode(CalendarFields.self, from: data) else { return standard }
        return fields
    }
}

// MARK: - The calendar itself

/// The one place that touches EventKit: which calendars Mindtalk may see, whether it
/// may see any at all, and what is going on around the moment recording starts.
///
/// Everything here runs on the main actor, the fetch included: a window of a few hours
/// in a handful of calendars comes back at once, and one place for the store means one
/// place the permission is asked for.
@MainActor
final class CalendarEvents: ObservableObject {
    static let shared = CalendarEvents()
    private static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "Kalender")

    /// How far ahead an event may start and still be this meeting: ten minutes — the
    /// time it takes to sit down, close the door and press play.
    nonisolated static let soonWindow: TimeInterval = 10 * 60
    /// How far back it may have started: three hours. A meeting that began while the
    /// room was being found is still this meeting; one that ended an hour ago is not.
    nonisolated static let pastWindow: TimeInterval = 3 * 3600
    /// The invitation's text, at most: a calendar can hold a whole document, and a
    /// meeting's summary has a budget to keep.
    nonisolated static let noteLimit = 1200
    nonisolated static let noteLines = 12
    /// Where the meeting is, at most: a room or a link, not a paragraph.
    nonisolated static let placeLimit = 160

    /// Where Mindtalk stands with the calendar.
    enum Access: Equatable {
        /// Never asked.
        case unknown
        /// May read it.
        case granted
        /// May write but not read: not enough, and said as much.
        case limited
        /// You said no.
        case denied
        /// This Mac doesn't allow it at all.
        case restricted
    }

    @Published private(set) var access: Access

    /// Switched on by the owner. Off: the calendar is never opened, and a meeting gets
    /// no `calendar` section.
    @Published var enabled: Bool {
        didSet {
            Settings.keep(enabled, forKey: "calendar.enabled")
            Self.log.notice("kalender \(self.enabled ? "på" : "av", privacy: .public)")
            guard enabled else { found = []; return }
            if access == .unknown { request() }
            refresh()
        }
    }

    /// What follows a meeting into its file.
    @Published var fields: CalendarFields {
        didSet { Settings.keep(try? JSONEncoder().encode(fields), forKey: CalendarFields.storageKey) }
    }

    /// A calendar on this Mac. `subscribed`: someone else's list, a holiday or a
    /// birthday feed — off from the start, because those are not meetings.
    struct Calendar: Identifiable, Equatable {
        let id: String
        let title: String
        let subscribed: Bool
    }
    @Published private(set) var calendars: [Calendar] = []
    /// The calendars Mindtalk may look in. Nothing chosen at all means the default:
    /// every calendar of your own, no subscribed ones.
    @Published var chosen: Set<String> {
        didSet { Settings.keep(Array(chosen).sorted(), forKey: "calendar.calendars") }
    }

    /// What the calendar holds around now, nearest first — what the start card shows.
    @Published private(set) var found: [CalendarMeeting] = []
    /// Chosen on the card when more than one fitted. Nothing chosen is not the same as
    /// one fitted: with two waiting and no choice nothing is written about either.
    @Published var picked: String?
    /// "Inte det här": let go for the meeting that is about to start. The event stays in
    /// the calendar and is offered another time; nothing follows this meeting.
    @Published var skipped = Set<String>()
    /// What the system answered when it said no. Shown rather than swallowed: without a
    /// usage description in the app's own Info.plist the request is refused with no
    /// window at all, and a silent no is impossible to find without this.
    @Published private(set) var problem: String?

    private let store = EKEventStore()
    private let defaults = UserDefaults.standard

    private init() {
        access = Self.accessNow()
        enabled = defaults.bool(forKey: "calendar.enabled")
        fields = CalendarFields.read(in: defaults)
        chosen = Set(defaults.stringArray(forKey: "calendar.calendars") ?? [])
        problem = nil
    }

    // MARK: Getting leave to look

    /// Asks macOS. The system's own window; nothing Mindtalk can put words in.
    func request() {
        store.requestFullAccessToEvents { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                self.access = Self.accessNow()
                self.problem = granted ? nil : error?.localizedDescription
                if let error { Self.log.error("kalender: \(error.localizedDescription, privacy: .public)") }
                Self.log.notice("åtkomst: \(granted ? "ja" : "nej", privacy: .public)")
                if granted, self.enabled { self.refresh() }
            }
        }
    }

    /// Where the calendar stands right now — asked again when the app comes to the
    /// front, so allowing it in System Settings shows up without a restart.
    nonisolated static func accessNow() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .writeOnly: return .limited
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .unknown
        default: return .unknown
        }
    }

    /// System Settings on the calendars page, where Mindtalk is allowed: the one button
    /// that mends it, as with Apple Intelligence in Settings → Möten.
    nonisolated static func openCalendarSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
    }

    // MARK: What the calendars hold


    /// The calendars to look in: the chosen ones, or every calendar of your own while
    /// none has been chosen.
    private var watching: Set<String> {
        if !chosen.isEmpty { return chosen }
        return Set(calendars.filter { !$0.subscribed }.map(\.id))
    }

    /// What is going on around `now`, nearest first. Nothing at all when it's off, when
    /// the calendar can't be read, or when nothing matches.
    @discardableResult
    func refresh(now: Date = Date()) -> [CalendarMeeting] {
        // Asked again each time: allowed in System Settings meanwhile, the card follows
        // without a restart.
        access = Self.accessNow()
        if access == .granted { problem = nil }
        guard enabled, access == .granted else { found = []; calendars = []; return [] }
        // The calendars as they are now — added or removed in the meantime — and the
        // predicate asks only those, which is what "which calendars may be read" means.
        let all = store.calendars(for: .event)
        calendars = all.map { Calendar(id: $0.calendarIdentifier, title: $0.title,
                                      subscribed: $0.source?.sourceType == .subscribed) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let watched = all.filter { watching.contains($0.calendarIdentifier) }
        guard !watched.isEmpty else { found = []; return [] }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-Self.pastWindow),
                                                 end: now.addingTimeInterval(Self.soonWindow),
                                                 calendars: watched)
        found = Self.matching(store.events(matching: predicate).compactMap { CalendarMeeting($0, fields: fields) },
                              now: now)
        // An event that is no longer there can't be chosen or let go any more.
        let here = Set(found.map(\.eventID))
        if let picked, !here.contains(picked) { self.picked = nil }
        skipped = skipped.intersection(here)
        return found
    }

    /// The meeting's own copy of the event: only what the settings ask for.
    func stored(_ event: CalendarMeeting) -> CalendarMeeting {
        fields.kept(event)
    }

    /// The event this meeting is about, at `now`: the one you chose, or the only one
    /// that fits. Nothing when you said it isn't about this, and nothing when two fit
    /// and none was chosen — guessing which meeting is in the room is not this feature's
    /// job, and a wrong name in the file is worse than no name.
    func upcoming(now: Date = Date()) -> CalendarMeeting? {
        Self.choose(found.filter { !skipped.contains($0.eventID) }, picked: picked)
    }

    /// A meeting started on what was offered: the choice is let go, so the next one is
    /// asked about the events around it instead.
    func startedMeeting() {
        picked = nil
        skipped = []
    }

    nonisolated static func choose(_ here: [CalendarMeeting], picked: String?) -> CalendarMeeting? {
        guard let one = here.first(where: { $0.eventID == picked }) ?? (here.count == 1 ? here.first : nil) else {
            return nil
        }
        // Several fitted and you said which: the meeting's file says so too.
        guard here.count > 1, one.eventID == picked else { return one }
        var chosen = one
        chosen.match = .chosen
        return chosen
    }

    // MARK: Finding the meeting

    /// Which of these is the meeting that is starting: still going, or beginning within
    /// `soon`. An event you declined is not offered, nor one without a name, nor one
    /// that has already ended. The one already going comes first — the most recently
    /// begun, which is the one in the room — then the ones about to start.
    nonisolated static func matching(_ events: [CalendarMeeting], now: Date,
                                     soon: TimeInterval = soonWindow) -> [CalendarMeeting] {
        events.compactMap { event -> CalendarMeeting? in
            guard !event.title.isEmpty, let end = event.end, let start = event.start,
                  end > now, start <= now.addingTimeInterval(soon), event.mine != .declined
            else { return nil }
            var found = event
            found.match = start <= now ? .running : .soon
            return found
        }
        .sorted { rank($0, now: now) < rank($1, now: now) }
    }

    /// Already running: first, most recently begun. Starting soon: nearest first.
    nonisolated private static func rank(_ event: CalendarMeeting, now: Date) -> (Int, TimeInterval) {
        guard let start = event.start else { return (2, 0) }
        return start <= now ? (0, now.timeIntervalSince(start)) : (1, start.timeIntervalSince(now))
    }
}

// MARK: - From EventKit

extension CalendarMeeting {
    /// An event as Mindtalk reads it. An all-day event is not a meeting, and neither is
    /// one without a name: both are passed over.
    ///
    /// The name and the times are read even when the settings leave them out — they are
    /// what decides *which* event this is. What the settings turn off is emptied here,
    /// so it is never written to the meeting's file.
    init?(_ event: EKEvent, fields: CalendarFields) {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !event.isAllDay, !title.isEmpty else { return nil }
        let start = event.startDate, end = event.endDate
        eventID = event.eventIdentifier ?? event.calendarItemIdentifier
        calendar = event.calendar.title
        self.title = fields.title ? title : ""
        // The name and the times are read whichever way the settings go; what they turn
        // off is emptied, so it is never written.
        self.start = fields.times ? start : nil
        self.end = fields.times ? end : nil
        notes = fields.notes ? Self.cleaned(event.notes) : nil
        location = fields.location ? Self.place(event.location) : nil
        people = fields.people ? Self.of(event) : []
        mine = Self.me(event)
        // How the event was found is the matcher's business (`matching` says running or
        // soon); here it is only an event read out of the calendar.
        match = .soon
    }

    /// The people, the one who called it first, then by name. The one who called the
    /// meeting isn't a status in a calendar: it's the role, so a chair is an organiser
    /// whatever they answered about themselves.
    nonisolated private static func of(_ event: EKEvent) -> [CalendarPerson] {
        var people: [CalendarPerson] = []
        var known = Set<String>()
        func add(_ person: EKParticipant, as answer: CalendarPerson.Answer) {
            let address = key(person)
            guard let shown = label(name: person.name, address: address),
                  !known.contains(shown.lowercased()) else { return }
            known.insert(shown.lowercased())
            people.append(CalendarPerson(name: shown, answer: answer, key: address))
        }
        if let organizer = event.organizer { add(organizer, as: .organizer) }
        for person in event.attendees ?? [] {
            add(person, as: answer(person.participantStatus, role: person.participantRole))
        }
        return people.sorted { a, b in
            if (a.answer == .organizer) != (b.answer == .organizer) { return a.answer == .organizer }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Who to write down. EventKit has no name for an attendee who isn't in your
    /// contacts — only the address — and an invited person who vanishes from the list is
    /// worse than one standing there as their address. A name is never replaced.
    nonisolated static func label(name: String?, address: String?) -> String? {
        let given = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !given.isEmpty { return given }
        let mail = (address ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return mail.isEmpty ? nil : mail
    }

    /// How *you* answered, when the calendar says who you are in it.
    nonisolated private static func me(_ event: EKEvent) -> CalendarPerson.Answer? {
        if event.organizer?.isCurrentUser == true { return .organizer }
        guard let me = event.attendees?.first(where: \.isCurrentUser) else { return nil }
        return answer(me.participantStatus, role: me.participantRole)
    }

    /// EventKit's answer, in Mindtalk's words. Unknown, pending, delegated and the rest
    /// are all "not answered yet" for what the room needs to know.
    nonisolated private static func answer(_ status: EKParticipantStatus,
                                           role: EKParticipantRole = .unknown) -> CalendarPerson.Answer {
        if role == .chair { return .organizer }
        switch status {
        case .accepted: return .accepted
        case .declined: return .declined
        case .tentative: return .tentative
        default: return .pending
        }
    }

    /// Where a participant lives: EventKit gives the address as a mailto: URL. Kept as a
    /// key only — to know Anna from another meeting — never shown.
    nonisolated private static func key(_ person: EKParticipant) -> String? {
        let address = person.url.absoluteString.lowercased().replacingOccurrences(of: "mailto:", with: "")
        return address.isEmpty ? nil : address
    }

    /// The invitation's text: empty lines and runs of spaces away, at most a dozen
    /// lines and 1200 characters. What's longer than that was never meant to be read
    /// aloud in a meeting.
    nonisolated static func cleaned(_ notes: String?) -> String? {
        let lines = (notes ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var text = lines.prefix(CalendarEvents.noteLines).joined(separator: "\n")
        if text.count > CalendarEvents.noteLimit {
            text = String(text.prefix(CalendarEvents.noteLimit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return text.isEmpty ? nil : text
    }

    /// Where the meeting is, on one line: a room, a floor, the link to the call. A
    /// calendar can hold a whole address block there, so it is folded and capped.
    nonisolated static func place(_ location: String?) -> String? {
        let text = (location ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return text.count > CalendarEvents.placeLimit
            ? String(text.prefix(CalendarEvents.placeLimit)) + "…" : text
    }
}

// MARK: - The card

/// Settings → Möten → Kalender: the switch, what it takes to let Mindtalk look, and
/// what of the invitation follows the meeting into its file.
struct CalendarCard: View {
    @ObservedObject private var events = CalendarEvents.shared
    /// Which calendars to look in, folded: a thing to set once.
    @State private var more = false

    var body: some View {
        VStack(spacing: 0) {
            CardRow(title: String(localized: "Kalender"), detail: Self.headline(events)) {
                InkToggle(label: String(localized: "Hämta mötet ur kalendern"), isOn: $events.enabled)
            }
            if events.enabled {
                CardDivider()
                accessRow
                CardDivider()
                CardRow(title: String(localized: "Detta följer med mötet"),
                        detail: String(localized: "Det som skrivs i mötets fil. Avbockat läses aldrig ur kalendern. Med MCP på kan AI-program som får läsa mötena läsa det här avsnittet — aldrig adresserna.")) { EmptyView() }
                CardDivider()
                fieldRows
                CardDivider()
                FoldRow(title: String(localized: "Kalendrar"),
                        detail: String(localized: "Välj vilka kalendrar Mindtalk får titta i. Prenumererade — födelsedagar, helgdagar, andras listor — är av från början."),
                        open: $more)
                if more {
                    CardDivider()
                    calendarRows
                }
            }
        }
        .card()
        .onAppear { events.refresh() }
        // Allowed in System Settings meanwhile: the card changes without a restart.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard events.enabled else { return }
            events.refresh()
        }
    }

    /// What the card says on top: what it does when it's on, and plainly that it
    /// doesn't when it isn't.
    static func headline(_ events: CalendarEvents) -> String {
        events.enabled
            ? String(localized: "När du börjar spela in letar Mindtalk upp mötet i kalendern — det som pågår eller börjar inom tio minuter. Det som hittas sparas med mötet och stannar på din Mac.")
            : String(localized: "Av: Mindtalk öppnar aldrig din kalender.")
    }

    /// Where the calendar stands, and the one button that mends it. Recording never
    /// waits for this: without it a meeting is recorded exactly as before.
    @MainActor private var accessRow: some View {
        CardRow(title: String(localized: "Kalenderåtkomst"),
                detail: Self.accessDetail(events.access, calendars: events.calendars.count)
                      + (events.problem.map { " " + $0 } ?? "")) {
            switch events.access {
            case .unknown:
                Button("Tillåt") { events.request() }.buttonStyle(.soft)
            case .denied, .limited:
                Button("Öppna Systeminställningar") { CalendarEvents.openCalendarSettings() }.buttonStyle(.soft)
            case .granted, .restricted:
                EmptyView()
            }
        }
    }

    static func accessDetail(_ access: CalendarEvents.Access, calendars: Int) -> String {
        switch access {
        case .unknown: return String(localized: "Mindtalk behöver ditt tillstånd för att läsa kalendern.")
        case .granted: return String(localized: "Kalendrar som kan läsas: \(calendars).")
        case .limited: return String(localized: "Mindtalk får bara skriva i kalendern, inte läsa den. Välj fullständig åtkomst under Systeminställningar → Integritet och säkerhet → Kalendrar.")
        case .denied: return String(localized: "Mindtalk får inte läsa kalendern. Slå på det under Systeminställningar → Integritet och säkerhet → Kalendrar.")
        case .restricted: return String(localized: "Den här Macen tillåter inte att program läser kalendern.")
        }
    }

    /// The five things that may follow a meeting, each by what it is.
    @MainActor private var fieldRows: some View {
        VStack(spacing: 0) {
            field(String(localized: "Mötets namn"), String(localized: "Namnet från inbjudan. Ett möte du själv döpt behåller sitt."), $events.fields.title)
            CardDivider()
            field(String(localized: "De inbjudna och hur de svarat"),
                  String(localized: "Namn, och om de accepterat, tackat nej eller inte svarat. Adressen sparas bara för att känna igen samma person — den visas inte, följer inte med en export och kan inte läsas av AI-program."),
                  $events.fields.people)
            CardDivider()
            field(String(localized: "Beskrivningen"),
                  String(localized: "Texten i inbjudan. Det är någon annans ord: den säger vad mötet var tänkt, inte vad som hände."),
                  $events.fields.notes)
            CardDivider()
            field(String(localized: "Platsen"),
                  String(localized: "Det som står som plats i inbjudan: ett rum, en våning eller länken till samtalet."),
                  $events.fields.location)
            CardDivider()
            field(String(localized: "Start- och sluttid"), String(localized: "När mötet var planerat att börja och sluta."), $events.fields.times)
        }
    }

    @MainActor private func field(_ name: String, _ detail: String, _ on: Binding<Bool>) -> some View {
        CardRow(title: name, detail: detail) {
            Toggle(LocalizedStringKey(name), isOn: on)
                .toggleStyle(InkCheckboxStyle())
                .labelsHidden()
                .accessibilityLabel(LocalizedStringKey(name))
        }
    }

    /// One checkbox per calendar, in the order they are named.
    @MainActor private var calendarRows: some View {
        VStack(spacing: 0) {
            ForEach(events.calendars) { calendar in
                CardRow(title: calendar.title,
                        detail: calendar.subscribed ? String(localized: "Prenumererad") : nil) {
                    Toggle(LocalizedStringKey(calendar.title), isOn: watching(calendar))
                        .toggleStyle(InkCheckboxStyle())
                        .labelsHidden()
                        .accessibilityLabel(LocalizedStringKey(calendar.title))
                }
                if calendar.id != events.calendars.last?.id { CardDivider() }
            }
            if events.calendars.isEmpty {
                CardRow(title: String(localized: "Inga kalendrar"),
                        detail: String(localized: "Det finns ingen kalender på den här Macen som Mindtalk får läsa.")) { EmptyView() }
            }
        }
    }

    /// A calendar's checkbox: unchecked means the default of its own kind — your own
    /// calendars are in, a subscribed one is out — until something is chosen.
    @MainActor private func watching(_ calendar: CalendarEvents.Calendar) -> Binding<Bool> {
        Binding(
            get: { events.chosen.contains(calendar.id) || (events.chosen.isEmpty && !calendar.subscribed) },
            set: { on in
                var set = events.chosen
                // First change of any: write down every calendar as it stands now, or
                // the ones never touched would switch off one by one.
                if set.isEmpty { set = Set(events.calendars.filter { !$0.subscribed }.map(\.id)) }
                if on { set.insert(calendar.id) } else { set.remove(calendar.id) }
                events.chosen = set
            }
        )
    }
}

// MARK: - Self-test

#if DEBUG
extension CalendarEvents {
    /// `Mindtalk --calendar-test`: which event counts as the meeting that is starting,
    /// how far ahead and behind, what an event you declined does, who is worth
    /// suggesting as a speaker, what the settings leave out, and what an old or broken
    /// meeting file reads as. Nothing here opens your calendar, asks for leave, or
    /// writes anything.
    @MainActor static func selfTest() -> Int32 {
        var failed = 0
        func check(_ ok: Bool, _ what: String) { if !ok { failed += 1; print("FEL  \(what)") } }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func event(_ title: String, starts: TimeInterval, ends: TimeInterval,
                   mine: CalendarPerson.Answer? = .accepted, from: String = "Jobb",
                   people: [CalendarPerson] = []) -> CalendarMeeting {
            CalendarMeeting(eventID: title, calendar: from, title: title,
                            start: now.addingTimeInterval(starts), end: now.addingTimeInterval(ends),
                            notes: nil, people: people, mine: mine, match: .soon)
        }
        func person(_ name: String, _ answer: CalendarPerson.Answer) -> CalendarPerson {
            CalendarPerson(name: name, answer: answer, key: name.lowercased() + "@example.com")
        }

        // Running, or beginning within ten minutes: that's the meeting.
        check(matching([event("Pågår", starts: -600, ends: 1800)], now: now).count == 1, "mötet som pågick hittades inte")
        check(matching([event("Om nio", starts: 9 * 60, ends: 3600)], now: now).count == 1, "nio minuter framåt hittades inte")
        check(matching([event("Om elva", starts: 11 * 60, ends: 3600)], now: now).isEmpty, "elva minuter framåt skulle inte räcka")
        check(matching([event("Slut för en timme", starts: -7200, ends: -3600)], now: now).isEmpty, "ett avslutat möte hittades")
        check(matching([event("Utan namn", starts: 0, ends: 600), CalendarMeeting(eventID: "x", calendar: "Jobb", title: "", start: now, end: now.addingTimeInterval(600), people: [], mine: nil, match: .soon)], now: now).count == 1, "ett evenemang utan namn skulle inte erbjudas")
        // An event you said nej to is not the meeting you're recording.
        check(matching([event("Nej", starts: -60, ends: 600, mine: .declined)], now: now).isEmpty, "ett evenemang du tackade nej till erbjuds")
        // Obekräftad and tveksam are still meetings.
        check(matching([event("Obekräftad", starts: -60, ends: 600, mine: .pending)], now: now).count == 1, "obekräftat svar hittades inte")
        check(matching([event("Tveksam", starts: -60, ends: 600, mine: .tentative)], now: now).count == 1, "tveksamt svar hittades inte")

        // More than one: the one in the room first — most recently begun — and the ones
        // about to start nearest first.
        let many = matching([event("Började för två timmar", starts: -7200, ends: 1800),
                             event("Började nyss", starts: -120, ends: 1800),
                             event("Om åtta", starts: 8 * 60, ends: 3600),
                             event("Om två", starts: 2 * 60, ends: 3600)], now: now)
        check(many.map(\.title) == ["Började nyss", "Började för två timmar", "Om två", "Om åtta"],
              "flera möten kom i fel ordning: \(many.map(\.title))")
        check(many.filter { $0.match == .running }.count == 2 && many.filter { $0.match == .soon }.count == 2,
              "pågående och kommande skildes inte åt")

        // Which of them follows the meeting: one that fits is taken, two are not until
        // you say which, and a choice that no longer matches nothing is not a guess.
        check(choose(many, picked: nil) == nil, "två som passade skulle inte gissa åt sig")
        check(choose([many[1]], picked: nil) == many[1], "en som passade följde inte med")
        check(choose(many, picked: many[3].eventID)?.eventID == many[3].eventID, "det valda mötet följde inte med")
        check(choose(many, picked: many[3].eventID)?.match == .chosen, "det valda mötet fick inte etiketten valt")
        check(choose([many[1]], picked: nil)?.match == many[1].match, "ett enda möte märktes som valt")
        check(choose(many, picked: "borta") == nil, "ett val som inte finns skulle inte gissa")
        check(choose([], picked: many[0].eventID) == nil, "ingen träff gav ändå ett möte")

        // Who is worth suggesting as a speaker: everyone but the ones who said nej.
        let crowd = event("Möte", starts: 0, ends: 600, people: [person("Anna", .organizer), person("Erik", .accepted),
                                                                person("Erik", .accepted), person("Bo", .declined),
                                                                person("  ", .accepted)])
        check(crowd.names == ["Anna", "Erik"], "de inbjudna blev: \(crowd.names)")
        check(crowd.organizer == "Anna", "den som kallade hittades inte")

        // The invitation's text: short kept as is, long cut, blank nothing.
        check(CalendarMeeting.cleaned("  \n  Agenda: budget  \n\n  \n ") == "Agenda: budget", "beskrivningen städades fel")
        check(CalendarMeeting.cleaned(nil) == nil, "ingen beskrivning blev inte tom")
        let long = String(repeating: "x", count: CalendarEvents.noteLimit * 3)
        check(CalendarMeeting.cleaned(long)?.count == CalendarEvents.noteLimit + 1, "beskrivningen klipptes inte")
        check(CalendarMeeting.cleaned(Array(repeating: "rad", count: 40).joined(separator: "\n"))?
                .split(separator: "\n").count == CalendarEvents.noteLines, "för många rader")

        // Where it is: an address block becomes one line, and nothing stays nothing.
        check(CalendarMeeting.place(" Stora salen ") == "Stora salen", "platsen städades fel")
        check(CalendarMeeting.place("Stora salen\n4 tr\nhttps://meet.example/x") == "Stora salen 4 tr https://meet.example/x",
              "platsen blev inte en rad")
        check(CalendarMeeting.place(nil) == nil && CalendarMeeting.place("  \n ") == nil, "ingen plats blev inte tom")
        check(CalendarMeeting.place(String(repeating: "y", count: CalendarEvents.placeLimit * 2))?.count
                == CalendarEvents.placeLimit + 1, "platsen klipptes inte")

        // An invited person: a name is kept, and only a nameless one falls back to the
        // address. Nobody becomes nothing.
        check(CalendarMeeting.label(name: "Anna Lind", address: "anna@example.com") == "Anna Lind", "namnet byttes mot adressen")
        check(CalendarMeeting.label(name: nil, address: "edrta913@company.se") == "edrta913@company.se", "en namnlös gäst försvann")
        check(CalendarMeeting.label(name: "   ", address: "   ") == nil, "ingen alls blev till något")

        // What the settings leave out never reaches the file.
        let all = CalendarFields.standard
        let none = CalendarFields(title: false, people: false, notes: false, location: false, times: false)
        let rich = CalendarMeeting(eventID: "id", calendar: "Jobb", title: "Styrelsemöte",
                                   start: now, end: now.addingTimeInterval(3600),
                                   notes: "Budget", location: "Stora salen", people: [person("Anna", .accepted)],
                                   mine: .accepted, match: .running)
        check(all.kept(rich) == rich, "allt skulle följa med")
        let left = none.kept(rich)
        check(left.title.isEmpty && left.start == nil && left.end == nil && left.notes == nil
              && left.location == nil && left.people.isEmpty, "avbockat följde ändå med")
        check(left.eventID == "id" && left.calendar == "Jobb", "evenemanget slutade säga vad det var")

        // The meeting's own file: the section is read when it is there and when it
        // isn't, and a `calendar` that can't be read never hides the meeting.
        let minimal = try? JSONDecoder().decode(MeetingRecord.self, from: Data(#"{"id":"3F3B7C1E-9A1F-4A6E-9A11-2B0D9C5E7A11"}"#.utf8))
        check(minimal?.calendar == nil, "möte utan kalender läste inte som utan")
        if var record = minimal {
            record.calendar = all.kept(rich)
            // The way back to the room: the invited are what the name list is offered,
            // through the meeting's cast.
            check(record.cast.expected == rich.names, "de inbjudna nådde inte namnlistan")
            guard let data = try? JSONEncoder().encode(record) else { print("FEL  kunde inte skriva mötet"); return 1 }
            let back = try? JSONDecoder().decode(MeetingRecord.self, from: data)
            check(back?.calendar == all.kept(rich), "kalendern blev inte igen")
            // Same file, valid JSON, only the calendar section nonsense: the meeting is
            // read anyway, without one. Built with JSONSerialization so the file itself
            // stays valid — an unreadable file says nothing about how a section is read.
            let shape = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if let object = shape, let broken = try? JSONSerialization.data(withJSONObject: object.merging(["calendar": "strunt"]) { _, new in new }) {
                let read = try? JSONDecoder().decode(MeetingRecord.self, from: broken)
                check(read != nil, "mötet med trasig kalender gick inte att läsa")
                check(read?.calendar == nil, "en trasig kalender dolde mötet")
            } else {
                print("FEL  mötets fil gick inte att vrida på")
                failed += 1
            }
        }

        // The settings: read back as written, in a scratch domain. The app's own are
        // left alone (`Settings.previewing` — a "--…-test" run never writes).
        let scratch = "ai.mindact.mindtalk.calendar-self-test"
        guard let defaults = UserDefaults(suiteName: scratch) else { print("FEL  ingen provdomän"); return 1 }
        defaults.removePersistentDomain(forName: scratch)
        defer { defaults.removePersistentDomain(forName: scratch) }
        check(CalendarFields.read(in: defaults) == CalendarFields.standard, "tomma inställningar läste inte standard")
        defaults.set(try? JSONEncoder().encode(none), forKey: CalendarFields.storageKey)
        check(CalendarFields.read(in: defaults) == none, "fälten blev inte desamma igen")

        if failed == 0 { print("OK  kalender: val, orden och mötets fil som väntat") }
        print("\(failed) fel")
        return failed == 0 ? 0 : 1
    }
}
#endif
