import Foundation
import SwiftUI

// MARK: - Showing how the voices were decided (Settings → Möten → Justering)
//
// Every number the voices work with is already on the Justering page; what was missing is what
// those numbers did in one particular meeting. With "Visa röstbeslut i möten" on, a meeting gets
// a quiet button of its own ("Röstbeslut") that turns two read-outs on — and only that meeting's:
//
//   • beside each speaker's name and time: the score that gave them the name and the bar it had
//     to clear — "· 0,72▸0,60".
//   • under each section: why these words make a section of their own — the pause or the word
//     count that cut it, and the voices and folds inside it.
//
// Nothing here changes a decision, and nothing new is stored. The section's reason is recorded
// while the words are grouped (`Cut` in MeetingStore) and the voices' numbers come from what the
// meeting already keeps (`record.recognized`) and from People.json. The numbers shown are today's
// settings — a finished meeting decided with the values it started with (`MeetingTuning.running`),
// which are not kept; that is phase B in PLAN.md. The diarizer's own per-sentence scores and the
// round's votes are not kept either, so they are not shown.
//
// Every number is said the way the knobs say it (`MeetingTuning.Unit`), so a value in the text and
// its knob look like the same thing.

@MainActor
final class MeetingDebug: ObservableObject {
    static let shared = MeetingDebug()
    static let settingKey = "meetingDebug"

    /// The feature: off until you switch it on in Settings → Möten → Justering.
    @Published var enabled: Bool {
        didSet { Settings.keep(enabled, forKey: Self.settingKey) }
    }
    /// Which meetings show their numbers now. Not saved: off again next launch.
    @Published private(set) var shown: Set<UUID> = []

    private init() { enabled = UserDefaults.standard.bool(forKey: Self.settingKey) }

    /// A meeting shows its numbers with both switches on: the setting, and its own button.
    func isShown(_ id: UUID) -> Bool { enabled && shown.contains(id) }

    func toggle(_ id: UUID) {
        if shown.contains(id) { shown.remove(id) } else { shown.insert(id) }
    }

    // MARK: What a voice's print was made from

    /// How much of a voice's speech in this meeting a print is taken from: the same
    /// stretches `VoicePrints` uses, counted without running the model. Under the pointer for
    /// every turn of a voice, so kept for the meeting it belongs to.
    static func printSeconds(of speaker: Int, in record: MeetingRecord) -> Double {
        let key = "\(record.id)|\(speaker)|\(record.words.count)"
        if let at = speechSeconds[key] { return at }
        let seconds = VoicePrints.stretches(of: speaker, in: record.words).reduce(0) { $0 + $1.end - $1.start }
        if speechSeconds.count > 500 { speechSeconds = [:] }
        speechSeconds[key] = seconds
        return seconds
    }
    private static var speechSeconds: [String: Double] = [:]

    // MARK: What cut a section — the pass's own reason, in words

    /// The rule that ended a section, said the way the read-out says it. The card and
    /// `--evidence-test` go through this one function, so the sentence cannot drift away
    /// from the rule that fired.
    static func reasonLabel(_ cut: Cut, _ t: MeetingTuning.Values) -> String {
        switch cut.reason {
        case .first: return String(localized: "mötets början")
        case .carry: return String(localized: "där en röst fördes vidare")
        case .pause: return String(localized: "paus \(Tuned.seconds(cut.gap)) ≥ \(Tuned.seconds(t.paragraphPause))")
        case .pending: return String(localized: "paus \(Tuned.seconds(cut.gap)) ≥ \(Tuned.seconds(t.paragraphPause)) under ett ord under skrivande")
        case .words: return String(localized: "\(cut.spoken) ord ≥ \(Tuned.words(Int(t.paragraphWords))) vid punkten")
        case .unclaimed: return String(localized: "ord utan röst efter \(Tuned.seconds(cut.gap)) ≥ \(Tuned.seconds(t.unclaimedPause))")
        case .speaker: return String(localized: "rösten bytte")
        }
    }

    // MARK: `Mindtalk --evidence-test`

    /// The read-out has to be what the grouping did, not a second guess afterwards. So the
    /// test runs the real pass over words written to reach each rule, and asks of every
    /// section: does the reason it names hold with the values in use, does its number appear
    /// in the sentence shown, and do the same words give the same reasons twice.
    @MainActor static func selfTest() -> Int32 {
        var failed = 0
        func check(_ ok: Bool, _ what: String) { if !ok { failed += 1; print("FEL  \(what)") } }
        let t = MeetingTuning.chosen
        func word(_ text: String, _ at: Double, _ who: Int? = 0) -> MeetingWord {
            MeetingWord(text: text, start: at, end: at + 0.3, speaker: who)
        }

        // One meeting that reaches every rule that can start a section.
        var words = [word("Först", 0), word("pratar.", 0.4)]
        words.append(word("Paus", t.paragraphPause + 1.2))          // a pause over the paragraph's bar
        words.append(word("här.", t.paragraphPause + 1.6))
        words.append(word("Du.", t.paragraphPause + 2.0, 1))         // another voice, no pause at all
        var at = (words.last?.end ?? 0) + 0.2
        for n in 0..<Int(t.paragraphWords) {                         // long enough to cut on words
            words.append(word("ord\(n).", at))
            at = (words.last?.end ?? at) + 0.05
        }
        words.append(word("Slut.", at + 0.4))

        let turns = MeetingText.turnsAllAnew(words, pending: [])
        check(turns.count >= 4, "\(turns.count) stycken, förväntade minst 4")
        for (n, turn) in turns.enumerated() {
            let label = reasonLabel(turn.cut, t)
            check(!label.isEmpty, "stycke \(n): anledningen är tom")
            switch turn.cut.reason {
            case .first: check(n == 0, "stycke \(n): mötets början mitt i mötet")
            case .pause, .pending:
                check(turn.cut.gap >= t.paragraphPause, "stycke \(n): paus \(turn.cut.gap) < \(t.paragraphPause)")
                check(label.contains(Tuned.seconds(turn.cut.gap)), "stycke \(n): pausen nämns inte")
            case .words:
                check(turn.cut.spoken >= Int(t.paragraphWords), "stycke \(n): \(turn.cut.spoken) ord < \(Int(t.paragraphWords))")
                check(turn.cut.sentenceEnd, "stycke \(n): klippt efter ett ord utan punkt")
            case .speaker: check(turn.cut.from != turn.cut.to, "stycke \(n): samma röst före och efter")
            case .unclaimed: check(turn.cut.gap >= t.unclaimedPause, "stycke \(n): \(turn.cut.gap) < \(t.unclaimedPause)")
            case .carry: break   // only a live pass's second chunk seeds one; a single pass never does
            }
        }
        check(turns.contains { $0.cut.reason == .pause }, "inget stycke klipptes av pausen")
        check(turns.contains { $0.cut.reason == .speaker }, "inget stycke klipptes av att rösten bytte")
        check(turns.contains { $0.cut.reason == .words }, "inget stycke klipptes av ordantalet")
        check(MeetingText.turnsAllAnew(words, pending: []).map(\.cut) == turns.map(\.cut),
              "samma ord gav andra anledningar andra gången")

        // Words still being written, after a pause and with no voice yet: a row of their own.
        let after = (words.last?.end ?? 0) + t.paragraphPause + 0.5
        let live = MeetingText.turnsAllAnew(words, pending: [MeetingWord(text: "kvar", start: after, end: after + 0.4, speaker: nil)])
        check(live.contains { $0.cut.reason == .pending || $0.cut.reason == .unclaimed },
              "ord under skrivande gav ingen egen rad")

        // The bar beside a name: a short print is held to its own bar, a long one to the usual.
        check(RoundPlacement.sameVoiceBar(seconds: t.shortPrint - 1) == Float(t.shortSameVoice), "kort prov fick fel gräns")
        check(RoundPlacement.sameVoiceBar(seconds: t.shortPrint + 6) == Float(t.sameVoice), "långt prov fick fel gräns")
        // The numbers are said in the knobs' own words, not in words of their own.
        check(Tuned.seconds(2.34) == MeetingTuning.Unit.seconds.label(2.34), "sekunder sägs inte som värdena på sidan")
        check(Tuned.score(0.72) == MeetingTuning.Unit.score.label(0.72), "poäng sägs inte som värdena på sidan")
        check(Tuned.words(60) == MeetingTuning.Unit.words.label(60), "ord sägs inte som värdena på sidan")

        print(failed == 0 ? "OK – \(turns.count) stycken, anledningarna är passets egna" : "\(failed) fel")
        return failed == 0 ? 0 : 1
    }
}

/// A number in the words the Justering page uses for it: "2,3 s", "0,72", "60 ord".
enum Tuned {
    static func seconds(_ value: Double) -> String { MeetingTuning.Unit.seconds.label(value) }
    static func score(_ value: Double) -> String { MeetingTuning.Unit.score.label(value) }
    static func words(_ count: Int) -> String { MeetingTuning.Unit.words.label(Double(count)) }
}

/// The little ? that opens an evidence card — the same sign the knobs use (`KnobRow`).
struct EvidenceSign: View {
    let question: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Image(systemName: "questionmark.circle").font(.system(size: 10.5))
                .foregroundStyle(DS.Colors.faint).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LocalizedStringKey(question))
    }
}

extension View {
    /// The evidence card: the same 260 pt popover the knobs open, a line of the label and the
    /// number it was weighed against.
    func evidenceCard(_ isOn: Binding<Bool>, title: String, @ViewBuilder lines: @escaping () -> some View) -> some View {
        popover(isPresented: isOn, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 7) {
                Text(LocalizedStringKey(title)).font(.system(size: 13, weight: .semibold))
                lines()
            }
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 260, alignment: .leading)
            .padding(14)
        }
    }
}

/// One line in an evidence card: what it is, and the number it was weighed against.
struct EvidenceLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(LocalizedStringKey(label)).foregroundStyle(DS.Colors.muted)
            Spacer(minLength: 6)
            Text(value).fontWeight(.medium).monospacedDigit().foregroundStyle(DS.Colors.ink)
        }
    }
}

// MARK: - Why this is a section of its own

/// Under a section: what cut it, with the numbers that were weighed when it did.
struct SectionEvidenceLine: View {
    let turn: MeetingTurn
    /// The meeting: which stretches you moved under this voice yourself (`moves`).
    var record: MeetingRecord? = nil
    /// The turn's own words — empty while they are still being written, which is why the
    /// counts come only when there are words to count.
    var words: [MeetingWord] = []
    let cast: Cast
    @State private var open = false

    private var tuning: MeetingTuning.Values { MeetingTuning.chosen }
    private var speech: Double { words.reduce(0) { $0 + $1.end - $1.start } }

    var body: some View {
        HStack(spacing: 4) {
            Text(clipped).font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                .foregroundStyle(DS.Colors.faint)
            EvidenceSign(question: "Varför blev det ett eget stycke?") { open = true }
        }
        .evidenceCard($open, title: "Varför blev det ett eget stycke?") { card }
    }

    /// "klippt: paus 2,3 s ≥ 2,0 s · 12 ord · 7,4 s"
    private var clipped: String {
        var parts = [String(localized: "klippt: \(reason)")]
        if !words.isEmpty {
            parts.append(Tuned.words(words.count))
            parts.append(Tuned.seconds(speech))
        }
        return parts.joined(separator: " · ")
    }

    /// The rule that ended the section before this one — the branch `MeetingText.raw` took.
    private var reason: String { MeetingDebug.reasonLabel(turn.cut, tuning) }

    @ViewBuilder private var card: some View {
        let cut = turn.cut, t = tuning
        EvidenceLine(label: "Klippt av", value: reason)
        if cut.gap > 0 {
            EvidenceLine(label: "Tyst mellan orden", value: Tuned.seconds(cut.gap))
            EvidenceLine(label: "Tyst som klipper", value: Tuned.seconds(t.paragraphPause))
        }
        if cut.reason == .words {
            EvidenceLine(label: "Ord innan punkten klipper", value: "\(cut.spoken) ≥ \(Tuned.words(Int(t.paragraphWords)))")
        }
        if let from = cut.from, let to = cut.to, from != to {
            EvidenceLine(label: "Röst", value: "\(cast.name(of: from)) → \(cast.name(of: to))")
        }
        // What held the section together instead of cutting it.
        EvidenceLine(label: "Tyst som skiljer åt en talare", value: Tuned.seconds(t.speakerGap))
        if !words.isEmpty {
            let runs = MeetingText.segments(words)
            EvidenceLine(label: "Röstblock inom stycket",
                         value: runs.isEmpty ? String(localized: "inget")
                                             : runs.map { "\(cast.name(of: $0.speaker)) \(MeetingView.duration($0.start))" }.prefix(3).joined(separator: ", "))
            if !turn.asides.isEmpty {
                EvidenceLine(label: "Någon annans \"Mm\" fält in",
                             value: turn.asides.map { cast.name(of: $0.speaker) }.joined(separator: ", "))
            }
            if !turn.foreign.isEmpty {
                EvidenceLine(label: "Ord av andra inuti", value: "\(turn.foreign.count)")
            }
        }
        // Whose voice the section carries — and whether you put the words there yourself.
        if let speaker = turn.speaker {
            EvidenceLine(label: "Rösten i stycket",
                         value: cast.background.contains(speaker)
                             ? String(localized: "bakgrund (en TV, radion)") : cast.name(of: speaker))
            let last = words.last?.end ?? turn.start
            let moved = record?.moves.filter { $0.speaker == speaker && $0.start < last && $0.end > turn.start }.count ?? 0
            if moved > 0 {
                EvidenceLine(label: "Du flyttade ord hit", value: "\(moved)")
            }
        }
        Text("Värdena är de som står i Inställningar nu; styckena görs om varje gång mötet visas.")
            .font(.system(size: 11.5)).foregroundStyle(DS.Colors.muted)
    }
}

// MARK: - Why this voice has this name

/// Beside a speaker's name and time: the score that named them and the bar it cleared.
/// Only Mindtalk's own guesses have a score — a name you typed has none, and the card says so.
struct SpeakerEvidenceChip: View {
    let record: MeetingRecord
    let speaker: Int
    let cast: Cast
    @State private var open = false
    /// What "Jämför igen" found, for this voice and no other.
    @State private var ranked: [String]?
    @State private var comparing = false

    private var key: String { String(speaker) }
    private var score: Float? { record.recognized[key] }
    /// How much of this voice's speech a print is taken from, in this meeting.
    private var seconds: Double { MeetingDebug.printSeconds(of: speaker, in: record) }
    /// The bar that applies to a print this long — and why.
    private var bar: Float { RoundPlacement.sameVoiceBar(seconds: seconds) }

    var body: some View {
        HStack(spacing: 4) {
            if let score {
                Text(verbatim: "· \(Tuned.score(Double(score)))▸\(Tuned.score(Double(bar)))")
                    .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                    .foregroundStyle(DS.Colors.faint)
            }
            EvidenceSign(question: "Varför är det den här rösten?") { open = true }
        }
        .evidenceCard($open, title: "Varför är det den här rösten?") { card }
    }

    private var origin: String {
        if cast.background.contains(speaker) { return String(localized: "bakgrund (en TV, radion)") }
        if record.recognized[key] != nil { return String(localized: "Mindtalk, från ett röstavtryck") }
        if cast.isNamed(speaker) { return String(localized: "du gav namnet") }
        return String(localized: "ingen har gett den ett namn")
    }

    @ViewBuilder private var card: some View {
        let t = MeetingTuning.running
        EvidenceLine(label: "Namnet kommer av", value: origin)
        if let score {
            EvidenceLine(label: "Poäng", value: Tuned.score(Double(score)))
            EvidenceLine(label: "Samma röst från", value: Tuned.score(Double(bar)))
            EvidenceLine(label: "Varför den gränsen",
                         value: seconds < t.shortPrint
                             ? String(localized: "provet är kort: \(Tuned.seconds(seconds)) < \(Tuned.seconds(t.shortPrint))")
                             : String(localized: "provet är \(Tuned.seconds(seconds))"))
            EvidenceLine(label: "Bättre än nästa förslag med", value: Tuned.score(Double(t.voiceMargin)))
        }
        if record.moves.contains(where: { $0.speaker == speaker }) {
            EvidenceLine(label: "Du flyttade ord hit", value: "\(record.moves.filter { $0.speaker == speaker }.count)")
        }
        if let person = person {
            EvidenceLine(label: "Röstavtryck som sparas", value: "\(person.prints.count)")
            if let sources = person.sources, !sources.isEmpty {
                EvidenceLine(label: "Från mötena", value: "\(sources.count)")
            }
            EvidenceLine(label: "Röstmodell", value: person.model ?? "—")
        }
        EvidenceLine(label: "Minst tal för ett prov", value: Tuned.seconds(t.printSpeech))
        EvidenceLine(label: "Mest tal för ett prov", value: Tuned.seconds(t.printMaxSpeech))
        EvidenceLine(label: "Inte samma person under", value: Tuned.score(Double(t.notThem)))
        if let rejected = record.rejected[key], !rejected.isEmpty {
            EvidenceLine(label: "Namn du sa nej till", value: rejected.joined(separator: ", "))
        }
        if let ranked {
            ForEach(ranked, id: \.self) { Text($0).font(.system(size: 12)).foregroundStyle(DS.Colors.ink) }
        } else if VoiceMemory.shared.known.isEmpty {
            Text("Röster kom inte ihåg, så det finns inget att jämföra med.")
                .font(.system(size: 11.5)).foregroundStyle(DS.Colors.muted)
        } else if record.hasAudio {
            Button(comparing ? String(localized: "Jämför…") : String(localized: "Jämför igen med dagens värden")) { compare() }
                .buttonStyle(.soft).disabled(comparing)
        }
        Text("Mötet avgjorde med de värden som gällde när det började; de sparades inte. Gränserna här är dagens.")
            .font(.system(size: 11.5)).foregroundStyle(DS.Colors.muted)
    }

    /// The person this voice is named for, if their voice is remembered.
    private var person: VoiceMemory.Person? {
        guard let name = record.names[key], !name.isEmpty else { return nil }
        return VoiceMemory.shared.people.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// A new print of this voice, against everyone remembered — the numbers the meeting did not
    /// keep. Asked for by hand: it runs the speaker model over the recording.
    private func compare() {
        comparing = true
        Task { @MainActor in
            let voices = await VoiceMemory.shared.prints(words: record.words,
                                                         audio: MeetingStore.audioURL(for: record.id), only: [speaker])
            let people = VoiceMemory.shared.known
            var out: [String] = []
            if let voice = voices[speaker] {
                for known in people.sorted(by: { $0.name < $1.name }) {
                    let score = RoundPlacement.similarity(voice.print, known.prints)
                    out.append("\(known.name) \(Tuned.score(Double(score))) — \(said(RoundPlacement.verdict(voice, known, among: people)))")
                }
            }
            ranked = out.isEmpty ? [String(localized: "inget prov att mäta")] : out
            comparing = false
        }
    }

    private func said(_ verdict: RoundPlacement.Verdict) -> String {
        switch verdict {
        case .surely: return String(localized: "säker")
        case .plausible(let s): return String(localized: "möjlig (\(Tuned.score(Double(s))))")
        case .notThem: return String(localized: "klart annan röst")
        case .unknown: return String(localized: "provet är för kort")
        }
    }
}

// MARK: - The meeting's own button

/// "Röstbeslut" in the bar under a meeting: shown only once the setting is on, and what it
/// turns on is this meeting alone.
struct MeetingEvidenceButton: View {
    @ObservedObject var debug = MeetingDebug.shared
    let id: UUID

    var body: some View {
        if debug.enabled {
            Button {
                withAnimation(.snappy) { debug.toggle(id) }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(debug.isShown(id) ? DS.Colors.ink : DS.Colors.faint).frame(width: 5, height: 5)
                    Text(String(localized: "Röstbeslut")).font(.system(size: 12.5, weight: .medium))
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Capsule().fill(DS.Colors.chip))
                .overlay(Capsule().strokeBorder(DS.Colors.ink.opacity(debug.isShown(id) ? 0.35 : 0.15), lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Visa poängen och gränserna som avgjorde röster och stycken i det här mötet")
        }
    }
}
