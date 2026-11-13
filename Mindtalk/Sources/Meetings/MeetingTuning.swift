import Foundation
import SwiftUI

// MARK: - Tuning the voices (Settings → Möten → Justering)
//
// The numbers VAD and diarization work with used to live only where they are used,
// each beside the measurement that chose it — a black box. They are gathered here:
// what each one is, the ladder of values that is worth trying, and the way back.
//
// Two readings, because they take effect at different times:
//   • `chosen` — as the settings have them now. The grouping of words into turns and
//     paragraphs reads these; a meeting is grouped when it is shown, so a change
//     shows in the old meetings too.
//   • `running` — as the meeting that is going started with. Who said which sentence,
//     and whether a voice is someone you know, reads these: they must not shift under
//     a meeting that has already answered with them. `MeetingSession` calls `begin()`
//     when a meeting starts and `end()` when its final pass has been written, so a
//     change taken in mid-meeting takes effect with the next one.
//
// Nothing here is invented: every default is the number the code had before (the
// measurements behind them are quoted where each is used), and every ladder stops
// where the same measurements say the answer would be wrong either way.
// `Mindtalk --tuning-test` checks the defaults, the ladders and the reading back.

enum MeetingTuning {
    /// Every number, in the kind the code keeps it: seconds of speech or silence,
    /// cosine scores of voiceprints, counts of words and turns, decibels.
    struct Values: Codable, Equatable {
        // Stycke och turtagning (MeetingStore)
        var paragraphPause = 2.0
        var paragraphWords = 60.0
        var unclaimedPause = 1.0
        var speakerGap = 1.5

        // Vem som säger meningen (MeetingSession, from the diarizer's scores)
        var sentencePause = 0.5
        var sentenceWords = 40.0
        var voiceChangeWords = 2.0
        var voiceFloor = 0.05
        var tieMargin = 0.02
        var frameActive = 0.5

        // Är det samma person? (VoiceMemory, VoicePrints, RoundPlacement)
        var sameVoice = 0.60
        var voiceMargin = 0.10
        var notThem = 0.50
        var shortSameVoice = 0.65
        var shortPrint = 4.0
        var shortestPrint = 2.0
        var notThemSpeech = 10.0
        var turnThisVoice = 0.50
        var printSpeech = 6.0
        var printMaxSpeech = 30.0
        var printGap = 0.6
        var livePrintSpeech = 3.5
        var continuedBar = 0.7

        // Ronden: vem sa namnet (RoundPlacement)
        var heardInTurn = 1.0
        var backgroundTurns = 2.0
        var beforeTurn = 1.5
        var outsideTurns = 4.0
        var phraseLength = 2.0
        var roundPause = 0.5
        var longestWord = 1.0
        var aroundBefore = 1.5
        var aroundAfter = 1.0
        var minimumVote = 0.3
        var voteMargin = 2.0
        var dominantSpeech = 1.0
        var dominance = 0.7

        // Ronden: när någon pratar (IntroRound, the room's own level floor)
        var speechOverFloor = 10.0
        var silenceUnderFloor = 6.0
        var speechStart = 0.2
        var floorWindow = 5.0
        var turnEndSilence = 1.4
        var turnEndSpeech = 3.5
        var turnAlways = 10.0
    }

    /// Today's numbers: the ones the code measured its way to.
    static let standard = Values()

    // MARK: How it is kept

    private static let storageKey = "meetingTuning"

    /// As the settings have them: the grouping reads these.
    nonisolated(unsafe) static private(set) var chosen = read(UserDefaults.standard)
    /// As the meeting that is going started with: the voices read these.
    nonisolated(unsafe) static private(set) var running = chosen

    /// A meeting begins: the voices keep these numbers to themselves until it ends.
    nonisolated static func begin() { running = chosen }

    /// Its final pass is written: old meetings and the next one read the settings again.
    nonisolated static func end() { running = chosen }

    /// A value was changed in the settings. `running` is left alone on purpose: the
    /// meeting going on has already answered with the numbers it started from.
    nonisolated static func save(_ values: Values) {
        chosen = values
        Settings.keep(try? JSONEncoder().encode(values), forKey: storageKey)
    }

    /// Back to the numbers the code measured with.
    nonisolated static func reset() -> Values {
        save(standard)
        return standard
    }

    /// The stored numbers, each snapped to the nearest rung of its ladder — so a
    /// value from another version, or a hand-edited one, can't leave a knob off the
    /// range the measurements support.
    private nonisolated static func read(_ defaults: UserDefaults) -> Values {
        guard let data = defaults.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode(Values.self, from: data) else { return standard }
        var values = standard
        for knob in allKnobs {
            values[keyPath: knob.key] = knob.near(saved[keyPath: knob.key])
        }
        return values
    }

    // MARK: What the settings page shows

    /// How a number is said in the menu: "2,5 s", "0,60", "60 ord", "10 dB".
    enum Unit {
        case seconds, score, share, words, turns, decibels, times

        func label(_ value: Double) -> String {
            let number: String
            switch self {
            case .seconds: number = value.formatted(.number.precision(.fractionLength(1...2)))
            case .score, .share: number = value.formatted(.number.precision(.fractionLength(2)))
            case .words, .turns, .decibels: number = value.formatted(.number.precision(.fractionLength(0)))
            case .times: number = value.formatted(.number.precision(.fractionLength(1)))
            }
            switch self {
            case .seconds: return "\(number) s"
            case .score, .share: return number
            case .words: return "\(number) \(String(localized: "enheter|ord"))"
            case .turns: return "\(number) \(String(localized: "enheter|turar"))"
            case .decibels: return "\(number) dB"
            case .times: return "\(number) \(String(localized: "enheter|ggr"))"
            }
        }
    }

    /// One number you can change: what it is, what changing it does, and the values
    /// worth trying. `key` is also where it is kept, through `Values`.
    struct Knob: Identifiable {
        let id: String
        let title: String
        let detail: String
        let effect: String
        let key: WritableKeyPath<Values, Double>
        let steps: [Double]
        let unit: Unit

        /// The ladder as the menu wants it, and the number as it is said.
        var options: [(value: Double, title: String)] { steps.map { ($0, unit.label($0)) } }
        /// The nearest rung of this knob's ladder.
        func near(_ value: Double) -> Double {
            steps.min(by: { abs($0 - value) < abs($1 - value) }) ?? MeetingTuning.standard[keyPath: key]
        }
    }

    /// The groups, in the order the page shows them.
    struct Group {
        let title: String
        let knobs: [Knob]
    }

    /// Stycke och turtagning: how the words are cut up for reading. These change the
    /// look of meetings that are already over too.
    static let grouping: [Knob] = [
        Knob(id: "paragraphPause", title: String(localized: "Tyst som klipper ett stycke"),
             detail: String(localized: "Någon som pratar i sträck delas upp efter en paus på så här lång."),
             effect: String(localized: "Högre → färre och längre stycken. Lägre → fler, kortare."),
             key: \.paragraphPause, steps: [0.5, 1, 1.5, 2, 2.5, 3, 4, 5], unit: .seconds),
        Knob(id: "paragraphWords", title: String(localized: "Ord innan punkten klipper"),
             detail: String(localized: "Efter så här många ord i samma stycke bryts det redan vid en punkt, inte bara vid tystnad."),
             effect: String(localized: "Högre → styckena växer längre innan punkten klipper. Lägre → punkterna delar oftare."),
             key: \.paragraphWords, steps: [20, 30, 40, 60, 80, 100, 150], unit: .words),
        Knob(id: "unclaimedPause", title: String(localized: "Tyst innan en rad utan röst"),
             detail: String(localized: "Ord som ännu ingen röst tagit får en egen rad när det har varit tyst så här länge."),
             effect: String(localized: "Högre → ord utan röst hamnar oftare i blocket ovanför. Lägre → de får oftare en egen rad."),
             key: \.unclaimedPause, steps: [0.5, 0.75, 1, 1.5, 2, 3], unit: .seconds),
        Knob(id: "speakerGap", title: String(localized: "Tyst som skiljer åt en talare"),
             detail: String(localized: "En kortare paus håller ihop en talares ord till ett block; längre börjar ett nytt."),
             effect: String(localized: "Högre → fler ord slås ihop till ett block. Lägre → varje talare får fler, kortare block."),
             key: \.speakerGap, steps: [0.5, 1, 1.5, 2, 2.5, 3, 4], unit: .seconds),
    ]

    /// Vem som säger meningen: what the diarizer's scores have to show before a
    /// sentence, or a word, is given to a voice.
    static let assignment: [Knob] = [
        Knob(id: "sentencePause", title: String(localized: "Tyst som slutar en mening"),
             detail: String(localized: "En mening får sin talare när det har varit tyst så här länge — annars vid . ? !"),
             effect: String(localized: "Högre → färre meningar får en talare utsagd. Lägre → talaren utsägs oftare."),
             key: \.sentencePause, steps: [0.2, 0.3, 0.4, 0.5, 0.75, 1, 1.5], unit: .seconds),
        Knob(id: "sentenceWords", title: String(localized: "En mening får vara så här lång"),
             detail: String(localized: "Längre än så här väntar inte röstkänningen på punkt eller tystnad."),
             effect: String(localized: "Högre → en mening får bli längre innan den måste ha en talare. Lägre → den avgörs tidigare."),
             key: \.sentenceWords, steps: [10, 20, 30, 40, 60, 80], unit: .words),
        Knob(id: "voiceChangeWords", title: String(localized: "Ord i rad innan ett byte räknas"),
             detail: String(localized: "En annan röst måste hålla i så här många ord för att dela en mening i två."),
             effect: String(localized: "Högre → svårare att dela en mening mellan två röster. Lägre → meningar delas oftare."),
             key: \.voiceChangeWords, steps: [1, 2, 3, 4, 5, 6], unit: .words),
        Knob(id: "voiceFloor", title: String(localized: "Röstpoäng som räknas som tal"),
             detail: String(localized: "Högst under så här mycket av mätpunkterna anses ingen ha talat alls."),
             effect: String(localized: "Högre → bara tydligt tal ger en talare. Lägre → även svaga röster får ord."),
             key: \.voiceFloor, steps: [0.02, 0.03, 0.05, 0.08, 0.1, 0.15, 0.2], unit: .score),
        Knob(id: "tieMargin", title: String(localized: "Två röster nära varandra: osäkert"),
             detail: String(localized: "Den starkaste rösten måste vara bättre än den närmaste med så mycket, annars får orden den talare de redan har."),
             effect: String(localized: "Högre → oftare osäkert: orden behåller sin talare. Lägre → byten godkänns oftare."),
             key: \.tieMargin, steps: [0.01, 0.02, 0.03, 0.05, 0.08, 0.1], unit: .score),
        Knob(id: "frameActive", title: String(localized: "Röstpoäng där någon talar"),
             detail: String(localized: "Varje mätpunkt på 10 ms räknas som tal från så här hög poäng. Används när ett mötes röster jämförs med varandra."),
             effect: String(localized: "Högre → bara det tydligaste talet räknas. Lägre → mer räknas som tal."),
             key: \.frameActive, steps: [0.3, 0.4, 0.5, 0.6, 0.7], unit: .score),
    ]

    /// Är det samma person: how close a voiceprint must be to a remembered voice, and
    /// how much speech a print needs before it says anything at all.
    static let identity: [Knob] = [
        Knob(id: "sameVoice", title: String(localized: "Samma röst från"),
             detail: String(localized: "Röster från olika möten som är lika mycket räknas som samma person. 0,60 valdes efter uppmätning: samma röst i ett nytt möte 0,64 och uppåt, två olika personer högst 0,54."),
             effect: String(localized: "Högre → färre röster slås ihop: fler personer. Lägre → oftare samma person — två kan bli en."),
             key: \.sameVoice, steps: [0.5, 0.55, 0.6, 0.65, 0.7], unit: .score),
        Knob(id: "voiceMargin", title: String(localized: "Bättre än nästa förslag med"),
             detail: String(localized: "Den bästa träffen måste slå den näst bästa med så mycket, annars nämns ingen."),
             effect: String(localized: "Högre → oftare nämns ingen. Lägre → ett namn utses oftare."),
             key: \.voiceMargin, steps: [0, 0.05, 0.1, 0.15, 0.2], unit: .score),
        Knob(id: "notThem", title: String(localized: "Inte samma person under"),
             detail: String(localized: "Under så här mycket är det tydligt att det är någon annan — men ett kort ljudprov får aldrig säga det."),
             effect: String(localized: "Högre → oftare uttalat att det är en annan. Lägre → krävs tydligare olikhet."),
             key: \.notThem, steps: [0.4, 0.45, 0.5, 0.55, 0.6], unit: .score),
        Knob(id: "shortSameVoice", title: String(localized: "Samma röst från kort prov, från"),
             detail: String(localized: "Ett kort ljudprov behöver vara bättre än så här för att nämna en person."),
             effect: String(localized: "Högre → korta prov nämner oftast ingen. Lägre → de nämner oftare någon."),
             key: \.shortSameVoice, steps: [0.55, 0.6, 0.65, 0.7, 0.75], unit: .score),
        Knob(id: "shortPrint", title: String(localized: "Ett prov är kort under"),
             detail: String(localized: "Från så här mycket tal krävs det inte längre en högre poäng för att nämna någon."),
             effect: String(localized: "Högre → fler prov räknas som korta och måste slå hårdare. Lägre → kravet gäller oftare."),
             key: \.shortPrint, steps: [2, 3, 4, 5, 6, 8], unit: .seconds),
        Knob(id: "shortestPrint", title: String(localized: "Kortaste provet som gäller"),
             detail: String(localized: "Från så här lite tal säger ett ljudprov ingenting alls — åt något håll."),
             effect: String(localized: "Högre → fler talare får ingen röststämpling alls. Lägre → även korta tal räcker."),
             key: \.shortestPrint, steps: [1, 1.5, 2, 2.5, 3], unit: .seconds),
        Knob(id: "notThemSpeech", title: String(localized: "Provet får säga nej från"),
             detail: String(localized: "Först efter så här mycket tal får ett ljudprov avgöra att det inte är personen."),
             effect: String(localized: "Högre → oftare tyst om att det är fel person. Lägre → det sägs oftare."),
             key: \.notThemSpeech, steps: [6, 8, 10, 12, 15, 20], unit: .seconds),
        Knob(id: "turnThisVoice", title: String(localized: "En turrunda låter som från"),
             detail: String(localized: "Ljudet från en rundes tur som är så här nära en röst i rummet väger tyngre än etiketten på namnordet."),
             effect: String(localized: "Högre → etiketten på namnordet väger tyngre. Lägre → röstjämplingen avgör oftare."),
             key: \.turnThisVoice, steps: [0.4, 0.45, 0.5, 0.55, 0.6], unit: .score),
        Knob(id: "printSpeech", title: String(localized: "Minst tal för ett ljudprov"),
             detail: String(localized: "Mindre än så här räcker inte för att bilda en röststämpling av en talare i ett möte."),
             effect: String(localized: "Högre → färre talare får en röststämpling. Lägre → fler."),
             key: \.printSpeech, steps: [4, 5, 6, 8, 10, 12], unit: .seconds),
        Knob(id: "printMaxSpeech", title: String(localized: "Mest tal för ett ljudprov"),
             detail: String(localized: "Mer än så här behövs inte: proverna tas från de längsta styckena upp till hit."),
             effect: String(localized: "Högre → fler sekunders tal används, långsammare. Lägre → snabbare men tunnare prov."),
             key: \.printMaxSpeech, steps: [15, 20, 30, 45, 60], unit: .seconds),
        Knob(id: "printGap", title: String(localized: "Tyst inuti ett ljudprov"),
             detail: String(localized: "En kortare paus än så här håller ihop en talares stycken till ett prov."),
             effect: String(localized: "Högre → talet slås ihop till färre, längre prov. Lägre → proverna klipps oftare."),
             key: \.printGap, steps: [0.3, 0.4, 0.6, 0.8, 1, 1.5], unit: .seconds),
        Knob(id: "livePrintSpeech", title: String(localized: "Prova röster under möte från"),
             detail: String(localized: "Så mycket tal behövs för att nämna någon inom loppet av sekunder medan mötet går."),
             effect: String(localized: "Högre → namnet kommer senare i mötet. Lägre → snabbare men osäkrare svar."),
             key: \.livePrintSpeech, steps: [2, 2.5, 3, 3.5, 4, 5, 6], unit: .seconds),
        Knob(id: "continuedBar", title: String(localized: "Säkrare när mötet fortsätter"),
             detail: String(localized: "Ett möte som fortsätter från ett tidigare behöver så här nära en röst från förut för att slås ihop."),
             effect: String(localized: "Högre → oftare en ny person i det fortsatta mötet. Lägre → oftare samma röst som förut."),
             key: \.continuedBar, steps: [0.6, 0.65, 0.7, 0.75, 0.8], unit: .score),
    ]

    /// Ronden: vem sa namnet — how the round of names decides which voice owns a turn,
    /// and which voice is only background (a TV, the next table).
    static let round: [Knob] = [
        Knob(id: "heardInTurn", title: String(localized: "Tal i en tur räknas från"),
             detail: String(localized: "Så här mycket av en röst måste höras i turen för att den ska räknas som hörd där."),
             effect: String(localized: "Högre → färre deltagare räknas ha hört namnet. Lägre → fler."),
             key: \.heardInTurn, steps: [0.5, 0.75, 1, 1.5, 2], unit: .seconds),
        Knob(id: "backgroundTurns", title: String(localized: "Turar som gör en röst till bakgrund"),
             detail: String(localized: "Hörd i så här många av rondens turar är rösten inte en deltagares: en TV väntar inte på sin tur."),
             effect: String(localized: "Högre → en röst får höras i fler turar. Lägre → bakgrunden sållas ut snabbare."),
             key: \.backgroundTurns, steps: [2, 3, 4, 5], unit: .turns),
        Knob(id: "beforeTurn", title: String(localized: "Tal strax före en tur"),
             detail: String(localized: "Pratar rösten så här länge före en tur och vidare in i den, är den bakgrund till den turen."),
             effect: String(localized: "Högre → fler röster blir bakgrund till turen. Lägre → färre."),
             key: \.beforeTurn, steps: [0.5, 1, 1.5, 2, 3], unit: .seconds),
        Knob(id: "outsideTurns", title: String(localized: "Tal utanför turarna"),
             detail: String(localized: "Så mycket tal under ronden utanför någon tur gör rösten till bakgrund."),
             effect: String(localized: "Högre → mer tal krävs utanför turorna. Lägre → bakgrunden upptäcks snabbare."),
             key: \.outsideTurns, steps: [2, 3, 4, 5, 6, 8], unit: .seconds),
        Knob(id: "phraseLength", title: String(localized: "En namnfras får vara högst"),
             detail: String(localized: "Började rösten tala längre tillbaka än så, pratar den ända fram till namnet: namnordet är troligare någon annans."),
             effect: String(localized: "Högre → längre fraser hör till samma röst. Lägre → fler fraser bryts — namnet blir oftare någon annans."),
             key: \.phraseLength, steps: [1, 1.5, 2, 2.5, 3], unit: .seconds),
        Knob(id: "roundPause", title: String(localized: "Paus som avbryter en fras"),
             detail: String(localized: "En paus på så här långt börjar en ny fras i mätningen av namnorden."),
             effect: String(localized: "Högre → en fras håller ihop över längre pauser. Lägre → fler fraser."),
             key: \.roundPause, steps: [0.3, 0.4, 0.5, 0.75, 1], unit: .seconds),
        Knob(id: "longestWord", title: String(localized: "Ett ord räknas som tal högst"),
             detail: String(localized: "Talmodellen drar ut det sista ordet över tystnaden efter sig; ett ord räknas inte längre än så."),
             effect: String(localized: "Högre → längre ord räknas fortfarande som tal. Lägre → talet klipps kortare."),
             key: \.longestWord, steps: [0.5, 0.75, 1, 1.5, 2], unit: .seconds),
        Knob(id: "aroundBefore", title: String(localized: "Tal före namnet räknas"),
             detail: String(localized: "När namnordet själv inte har en klar röst: så här mycket före det väger med."),
             effect: String(localized: "Högre → mer av talet före namnet väger med. Lägre → mindre."),
             key: \.aroundBefore, steps: [0.5, 1, 1.5, 2, 3], unit: .seconds),
        Knob(id: "aroundAfter", title: String(localized: "Tal efter namnet räknas"),
             detail: String(localized: "…och så här mycket efter det."),
             effect: String(localized: "Högre → mer av talet efter namnet väger med. Lägre → mindre."),
             key: \.aroundAfter, steps: [0.5, 0.75, 1, 1.5, 2], unit: .seconds),
        Knob(id: "minimumVote", title: String(localized: "Röstandel som räknas"),
             detail: String(localized: "En röst måste ha minst så här mycket av talet runt namnordet för att få det."),
             effect: String(localized: "Högre → färre röster kvalificerar sig om namnet. Lägre → fler."),
             key: \.minimumVote, steps: [0.2, 0.25, 0.3, 0.4, 0.5], unit: .share),
        Knob(id: "voteMargin", title: String(localized: "Gånger bättre än nästa röst"),
             detail: String(localized: "Och så mycket bättre än den närmaste rösten, annars avgör inte namnordet."),
             effect: String(localized: "Högre → oftare avgör inte namnordet någonting. Lägre → ett namn utses oftare."),
             key: \.voteMargin, steps: [1.5, 2, 2.5, 3, 4], unit: .times),
        Knob(id: "dominantSpeech", title: String(localized: "Tal i en tur utan namnord"),
             detail: String(localized: "En tur som fick sitt namn in skrivet eller känt igen: en röst måste ha minst så här mycket av den."),
             effect: String(localized: "Högre → färre turar kan ge en röst namnet. Lägre → fler."),
             key: \.dominantSpeech, steps: [0.5, 0.75, 1, 1.5, 2], unit: .seconds),
        Knob(id: "dominance", title: String(localized: "Del av turens tal"),
             detail: String(localized: "…och så stor del av allt som hördes i turen."),
             effect: String(localized: "Högre → bara den tydligaste rösten får. Lägre → fler kan få."),
             key: \.dominance, steps: [0.5, 0.6, 0.7, 0.8, 0.9], unit: .share),
    ]

    /// Ronden: när någon pratar — the round's own VAD, levels in 20 ms frames against
    /// the room's own noise floor.
    static let vad: [Knob] = [
        Knob(id: "speechOverFloor", title: String(localized: "Tal så här mycket över rummet"),
             detail: String(localized: "Ljudnivån måste vara så här mycket över rummets eget golv för att räknas som tal."),
             effect: String(localized: "Högre → bara högljutt tal räknas. Lägre → även brus kan räknas som tal."),
             key: \.speechOverFloor, steps: [6, 8, 10, 12, 15], unit: .decibels),
        Knob(id: "silenceUnderFloor", title: String(localized: "Tyst så här nära rummets golv"),
             detail: String(localized: "Så här nära golvet räknas det som tyst. Måste vara lägre än gränsen för tal."),
             effect: String(localized: "Högre → mer räknas som tystnad. Lägre → bara riktigt tyst räknas."),
             key: \.silenceUnderFloor, steps: [3, 4, 5, 6, 7, 8], unit: .decibels),
        Knob(id: "speechStart", title: String(localized: "Så här länge innan talet börjar"),
             detail: String(localized: "Talet anses ha börjat efter så här långt sammanhängande ljud — och börjar inte vid en hosta."),
             effect: String(localized: "Högre → hostningar och skratten missas, men starten kommer senare. Lägre → snabbare, mer brus."),
             key: \.speechStart, steps: [0.1, 0.15, 0.2, 0.3, 0.5], unit: .seconds),
        Knob(id: "floorWindow", title: String(localized: "Rummets golv mäts över"),
             detail: String(localized: "Golvet är det tystaste av ljudet under en så här lång tid: kortare än så hinner inte ett bullrigt rum hinna visa vad som är tyst."),
             effect: String(localized: "Högre → golvet hänger kvar längre i ett bullrigt rum. Lägre → golvet följer rummet fortare."),
             key: \.floorWindow, steps: [3, 4, 5, 8, 10], unit: .seconds),
        Knob(id: "turnEndSilence", title: String(localized: "Tyst som avslutar en tur"),
             detail: String(localized: "Någon har svarat och det har varit tyst så här länge: ronden går vidare till nästa."),
             effect: String(localized: "Högre → ronden väntar längre innan nästa får svara. Lägre → snabbare vidare."),
             key: \.turnEndSilence, steps: [0.8, 1, 1.2, 1.4, 2, 3], unit: .seconds),
        Knob(id: "turnEndSpeech", title: String(localized: "Tal som avslutar en tur"),
             detail: String(localized: "Först efter så här mycket tal avslutas en tur av tystnaden."),
             effect: String(localized: "Högre → turen behöver mer tal innan tystnaden får avsluta. Lägre → korta svar räcker."),
             key: \.turnEndSpeech, steps: [2, 2.5, 3, 3.5, 5, 7], unit: .seconds),
        Knob(id: "turnAlways", title: String(localized: "En tur avslutas alltid efter"),
             detail: String(localized: "Så långt tal avslutar turen ändå, hur tyst det än varit."),
             effect: String(localized: "Högre → längre turar innan avbrottet kommer. Lägre → avbrott oftare."),
             key: \.turnAlways, steps: [5, 8, 10, 15, 20], unit: .seconds),
    ]

    static let groups: [Group] = [
        Group(title: String(localized: "Stycke och turtagning"), knobs: grouping),
        Group(title: String(localized: "Vem som säger meningen"), knobs: assignment),
        Group(title: String(localized: "Är det samma person?"), knobs: identity),
        Group(title: String(localized: "Ronden: vem sa namnet"), knobs: round),
        Group(title: String(localized: "Ronden: när någon pratar"), knobs: vad),
    ]

    static let allKnobs: [Knob] = groups.flatMap(\.knobs)
}

// MARK: - The page

/// Settings → Möten → Justering: every number the voices work with, in the order the
/// room uses them, with the way back to the numbers Mindtalk measured its way to.
struct MeetingTuningCard: View {
    @State private var values = MeetingTuning.chosen

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(String(localized: "Justering av röster"))
            VStack(spacing: 0) {
                CardRow(title: String(localized: "Så här hör Mindtalk vem som säger vad"),
                        detail: String(localized: "Vad som är tystnad, hur lång en mening är, och hur lika en röst måste vara för att vara samma person. Standardvärdena är uppmätta på riktigt upptalade möten; ändra om någon av dem inte stämmer med hur ditt rum låter. Klicka på ? för vad som ändras när du höjer eller sänker värdet.")) {
                    Button("Återställ") { values = MeetingTuning.reset() }.buttonStyle(.soft)
                        .disabled(MeetingTuning.chosen == MeetingTuning.standard)
                }
            }
            .card()

            ForEach(MeetingTuning.groups, id: \.title) { group in
                SectionTitle(group.title)
                VStack(spacing: 0) {
                    ForEach(group.knobs) { knob in
                        KnobRow(knob: knob, value: binding(for: knob))
                        if knob.id != group.knobs.last?.id { CardDivider() }
                    }
                }
                .card()
            }
        }
    }

    /// One row's number: written straight to the settings, and to the meeting going on
    /// with its own numbers left as they are.
    private func binding(for knob: MeetingTuning.Knob) -> Binding<Double> {
        Binding(
            get: { values[keyPath: knob.key] },
            set: { newValue in
                var tuned = values
                tuned[keyPath: knob.key] = newValue
                values = tuned
                MeetingTuning.save(tuned)
            }
        )
    }
}

/// One number on the page, with the little ? that says what it is: 43 explanations
/// standing under 43 rows would be longer than the page, so each one waits for the
/// pointer. The ? is there to be found; the sentence is read where it is spoken.
private struct KnobRow: View {
    let knob: MeetingTuning.Knob
    @Binding var value: Double
    @State private var about = false

    var body: some View {
        CardRow(title: knob.title) {
            HStack(spacing: 8) {
                // A bare Image with .help showed nothing here — the same ⓘ as the meetings
                // page: a button that opens a popover, so it answers to a click as well as
                // to VoiceOver.
                Button { about = true } label: {
                    Image(systemName: "questionmark.circle").font(.system(size: 12.5)).foregroundStyle(DS.Colors.faint)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Vad betyder detta?")
                .help(knob.detail + " " + knob.effect)
                .popover(isPresented: $about, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(knob.detail)
                        Text(knob.effect)
                            .foregroundStyle(DS.Colors.muted)
                    }
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 260, alignment: .leading)
                    .padding(14)
                }
                MenuPicker(options: knob.options, selection: $value)
                    .accessibilityHint(knob.detail + " " + knob.effect)
            }
        }
    }
}

#if DEBUG
extension MeetingTuning {
    /// `Mindtalk --tuning-test`: the defaults are the numbers the code used before,
    /// every ladder holds its own default, a value off the ladder snaps to the nearest
    /// rung, and what is written is what is read back.
    @MainActor static func selfTest() -> Int32 {
        var failed = 0
        func check(_ ok: Bool, _ what: String) { if !ok { failed += 1; print("FEL  \(what)") } }

        // The numbers the code measured with: a default moved by mistake changes how
        // every meeting on this Mac is heard.
        check(standard.paragraphPause == 2, "paragraphPause är inte 2")
        check(standard.paragraphWords == 60, "paragraphWords är inte 60")
        check(standard.unclaimedPause == 1, "unclaimedPause är inte 1")
        check(standard.speakerGap == 1.5, "speakerGap är inte 1,5")
        check(standard.sentencePause == 0.5, "sentencePause är inte 0,5")
        check(standard.sentenceWords == 40, "sentenceWords är inte 40")
        check(standard.voiceChangeWords == 2, "voiceChangeWords är inte 2")
        check(standard.voiceFloor == 0.05, "voiceFloor är inte 0,05")
        check(standard.tieMargin == 0.02, "tieMargin är inte 0,02")
        check(standard.frameActive == 0.5, "frameActive är inte 0,5")
        check(standard.sameVoice == 0.6, "sameVoice är inte 0,60")
        check(standard.voiceMargin == 0.1, "voiceMargin är inte 0,10")
        check(standard.notThem == 0.5, "notThem är inte 0,50")
        check(standard.shortSameVoice == 0.65, "shortSameVoice är inte 0,65")
        check(standard.shortPrint == 4, "shortPrint är inte 4")
        check(standard.shortestPrint == 2, "shortestPrint är inte 2")
        check(standard.notThemSpeech == 10, "notThemSpeech är inte 10")
        check(standard.turnThisVoice == 0.5, "turnThisVoice är inte 0,50")
        check(standard.printSpeech == 6, "printSpeech är inte 6")
        check(standard.printMaxSpeech == 30, "printMaxSpeech är inte 30")
        check(standard.printGap == 0.6, "printGap är inte 0,6")
        check(standard.livePrintSpeech == 3.5, "livePrintSpeech är inte 3,5")
        check(standard.continuedBar == 0.7, "continuedBar är inte 0,7")
        check(standard.heardInTurn == 1, "heardInTurn är inte 1")
        check(standard.backgroundTurns == 2, "backgroundTurns är inte 2")
        check(standard.beforeTurn == 1.5, "beforeTurn är inte 1,5")
        check(standard.outsideTurns == 4, "outsideTurns är inte 4")
        check(standard.phraseLength == 2, "phraseLength är inte 2")
        check(standard.roundPause == 0.5, "roundPause är inte 0,5")
        check(standard.longestWord == 1, "longestWord är inte 1")
        check(standard.aroundBefore == 1.5, "aroundBefore är inte 1,5")
        check(standard.aroundAfter == 1, "aroundAfter är inte 1")
        check(standard.minimumVote == 0.3, "minimumVote är inte 0,3")
        check(standard.voteMargin == 2, "voteMargin är inte 2")
        check(standard.dominantSpeech == 1, "dominantSpeech är inte 1")
        check(standard.dominance == 0.7, "dominance är inte 0,7")
        check(standard.speechOverFloor == 10, "speechOverFloor är inte 10")
        check(standard.silenceUnderFloor == 6, "silenceUnderFloor är inte 6")
        check(standard.speechStart == 0.2, "speechStart är inte 0,2")
        check(standard.floorWindow == 5, "floorWindow är inte 5")
        check(standard.turnEndSilence == 1.4, "turnEndSilence är inte 1,4")
        check(standard.turnEndSpeech == 3.5, "turnEndSpeech är inte 3,5")
        check(standard.turnAlways == 10, "turnAlways är inte 10")

        // The page: no knob twice, and every default on its own ladder.
        var seen = Set<String>()
        for knob in allKnobs {
            check(seen.insert(knob.id).inserted, "värdet \(knob.id) finns två gånger")
            check(knob.steps.contains(standard[keyPath: knob.key]), "\(knob.id): standardvärdet är inte i stegen")
            check(knob.steps == knob.steps.sorted(), "\(knob.id): stegen är inte i ordning")
            // A knob on the page without a sentence, or without what moving it does, is a
            // knob nobody can use: the ? would open on nothing. The arrow is what marks the
            // two directions — the words themselves are read in the Mac's own language.
            check(!knob.detail.isEmpty && !knob.effect.isEmpty, "\(knob.id): saknar förklaring")
            check(knob.effect.contains("→"), "\(knob.id): effekttexten säger inte vad som händer åt båda hållet")
        }
        check(allKnobs.count == 43, "\(allKnobs.count) värden, förväntade 43")

        // The rules the numbers have to keep between them.
        check(standard.silenceUnderFloor < standard.speechOverFloor, "tystnaden ligger inte under talet")
        check(standard.shortestPrint < standard.shortPrint, "kortaste provet är inte kortare än korta provet")
        check(standard.shortPrint < standard.notThemSpeech, "korta provet är inte kortare än provet som får säga nej")
        check(standard.printSpeech <= standard.printMaxSpeech, "minsta talet är större än största")

        // Off the ladder: the nearest rung, never a value the measurements don't support.
        for (given, want) in [(0.99, 0.7), (0.0, 0.5), (0.62, 0.6), (0.649, 0.65)] {
            check(knob(named: "sameVoice")?.near(given) == want, "sameVoice \(given) blev inte \(want)")
        }
        check(knob(named: "speechOverFloor")?.near(11.2) == 12, "11,2 dB blev inte 12")

        // Written and read back, in a scratch domain: the app's own settings are left alone.
        let scratch = "ai.mindact.mindtalk.tuning-self-test"
        guard let defaults = UserDefaults(suiteName: scratch) else { print("FEL  ingen provdomän"); return 1 }
        defaults.removePersistentDomain(forName: scratch)
        defer { defaults.removePersistentDomain(forName: scratch) }

        check(read(defaults) == standard, "tomma inställningar läste inte standardvärdena")
        var tuned = standard
        for knob in allKnobs { tuned[keyPath: knob.key] = knob.steps.last ?? standard[keyPath: knob.key] }
        guard let data = try? JSONEncoder().encode(tuned) else { print("FEL  kunde inte koda värdena"); return 1 }
        defaults.set(data, forKey: storageKey)
        check(read(defaults) == tuned, "värdena blev inte desamma igen")
        // A number that isn't on any ladder — an older Mindtalk, or a hand-edit.
        defaults.set(Data([0, 1]), forKey: storageKey)
        check(read(defaults) == standard, "smutsiga byte läste inte standardvärdena")
        check(read(UserDefaults(suiteName: "\(scratch).missing") ?? defaults) == standard, "en saknad inställning läste inte standardvärdena")

        // The meeting's own copy: begin freezes, end lets go.
        let wasChosen = chosen, wasRunning = running
        defer { chosen = wasChosen; running = wasRunning }
        save(tuned)
        check(chosen == tuned, "valet sparades inte i minnet")
        begin()
        check(running == tuned, "mötet fick inte de valda värdena")
        save(standard)
        check(running == tuned, "mötet bytte värden mitt under")
        end()
        check(running == standard, "mötet släppte inte värdena")

        print(failed == 0 ? "OK  justering: \(allKnobs.count) värden, standard och steg som väntat"
                          : "FEL  \(failed) av justeringens kontroller")
        return failed == 0 ? 0 : 1
    }

    private nonisolated static func knob(named name: String) -> Knob? {
        allKnobs.first { $0.id == name }
    }
}
#endif
