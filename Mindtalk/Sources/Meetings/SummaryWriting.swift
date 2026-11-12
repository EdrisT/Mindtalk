import Foundation
import os

// MARK: - Who writes the notes
//
// Two write a meeting's summary and answer questions about it: Apple Intelligence
// (built in) and your own model in Ollama or LM Studio on this Mac (SummaryWriter.swift).
// The choice lives here: in the settings, and in the system log, so a summary by the
// wrong writer can be traced. Nothing is downloaded for it — the models that used to
// come here (Gemma 4 through MLX) are not part of this fork.

@MainActor
final class SummaryWriting: ObservableObject {
    static let shared = SummaryWriting()
    private static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "SummaryWriting")

    /// Which writes the summaries: Apple Intelligence or your own model in Ollama or
    /// LM Studio (SummaryWriter.swift).
    @Published var choice: SummaryWriterChoice = .apple {
        didSet {
            // In the system log, so a summary by the wrong writer can be traced.
            Self.log.notice("writer chosen: \(self.choice.stored, privacy: .public), was \(oldValue.stored, privacy: .public)")
            // A render or a self-test: chosen for this run only, never written down.
            guard !Settings.previewing else { return }
            let defaults = UserDefaults.standard
            defaults.set(choice.stored, forKey: "summaryWriter")
            if case .server(let backend, let model) = choice, choice != oldValue {
                defaults.set(model, forKey: "serverModel.\(backend.rawValue)")
                LocalServers.shared.prewarm(backend, model)
            }
        }
    }
    /// The server model chosen, if one is.
    var server: (backend: ServerBackend, model: String)? {
        if case .server(let b, let m) = choice { return (b, m) }
        return nil
    }
    /// Who writes the next notes, unless it's Apple Intelligence (nil). The one chosen,
    /// whether it can write right now or not: a server that isn't running says so when
    /// asked to write. Never another writer instead.
    var writer: (any SummaryWriter)? { choice.writer }
    /// Something other than Apple Intelligence is chosen to write.
    var isActive: Bool { choice != .apple }
    /// "Ollama · qwen3.5:9b", or "Apple Intelligence".
    var writerName: String { writer?.name ?? "Apple Intelligence" }
    /// The same in a sentence: "qwen3.5:9b i Ollama".
    var writerSentenceName: String { writer?.sentenceName ?? "Apple Intelligence" }

    // MARK: This Mac

    nonisolated static var memoryGB: Int { Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()) }

    /// Free space for something you asked for (counts what macOS can clear).
    nonisolated static var freeBytes: Int64 {
        let values = try? FileManager.default.homeDirectoryForCurrentUser
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// "6,9 GB" — "6.9 GB" when the app runs in English.
    nonisolated static func gigabytes(_ bytes: Int64) -> String {
        (Double(bytes) / 1e9).formatted(.number.precision(.fractionLength(1)).locale(AppLanguage.locale)) + " GB"
    }

    private init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "summaryWriter") {
            if let c = SummaryWriterChoice(stored: saved) {
                choice = c
            } else {
                // Not understood — a writer this build doesn't have, e.g. a saved
                // "gemma:e4b". Apple Intelligence writes; what was saved stays as it
                // is, for the version that wrote it.
                Self.log.error("writer at launch: stored choice \(saved, privacy: .public) not understood, Apple Intelligence writes")
            }
        }
        Self.log.notice("writer at launch: \(self.choice.stored, privacy: .public)")
    }
}
