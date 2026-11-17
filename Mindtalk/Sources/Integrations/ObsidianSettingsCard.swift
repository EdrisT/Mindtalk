import AppKit
import SwiftUI

// MARK: - Inställningar → Integrationer → Obsidian
//
// One card, like MCP's on the section above it: the switch on top, and under it where
// the vault is and the two folders inside it. Switched off, a line says what it would
// do; switched on, Mindtalk makes the folders at once and says so — or says what macOS
// refused, with the one button that mends it (System Settings on Filer och mappar).
//
// Nothing here is written behind a meeting's back after the first time: a meeting that
// has changed since its folder was written says so on its own card under Möten, where
// it is written again by hand. So this card never needs a list of what differs — it
// only ever says where things go, and whether Mindtalk is allowed to put them there.

struct ObsidianSettingsCard: View {
    @ObservedObject var obsidian = Obsidian.shared
    /// The folder names, while being typed; they land when the field is left.
    @State private var meetings = Obsidian.shared.meetingsFolder
    @State private var notes = Obsidian.shared.notesFolder
    @FocusState private var meetingsField: Bool
    @FocusState private var notesField: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("Obsidian")

            VStack(spacing: 0) {
                CardRow(title: String(localized: "Spara i Obsidian"),
                        detail: String(localized: "Varje möte du sparar blir en mapp i ditt Obsidian-valv med texten och mötets uppgifter. Tankar blir egna anteckningar.")) {
                    InkToggle(label: String(localized: "Spara i Obsidian"), isOn: Binding(get: { obsidian.enabled }, set: { obsidian.enable($0) }))
                }
                if obsidian.enabled {
                    CardDivider()
                    vaultRow
                    CardDivider()
                    folderRow(title: String(localized: "Mapp för möten"),
                              detail: String(localized: "Där mötena läggs, under valvet. Mappen skapas om den inte finns."),
                              text: $meetings, placeholder: Obsidian.defaultMeetings, focus: $meetingsField) {
                                  obsidian.setMeetingsFolder($0); return obsidian.meetingsFolder
                              }
                    CardDivider()
                    folderRow(title: String(localized: "Mapp för tankar"),
                              detail: String(localized: "Dina tankar från Tankar läggs här. Mappen skapas om den inte finns."),
                              text: $notes, placeholder: Obsidian.defaultNotes, focus: $notesField) {
                                  obsidian.setNotesFolder($0); return obsidian.notesFolder
                              }
                }
            }
            .card()

            if let trouble = obsidian.trouble {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13)).foregroundStyle(DS.Colors.warning)
                    Text(LocalizedStringKey(trouble))
                        .font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Öppna Systeminställningar") { Obsidian.openPermissionSettings() }.buttonStyle(.soft)
                }
                .padding(.horizontal, 4)
            }
        }
        .onAppear {
            meetings = obsidian.meetingsFolder
            notes = obsidian.notesFolder
            // Asking again, like the microphone's and the calendar's card do: opening the
            // page is how you find out that macOS stopped letting Mindtalk write.
            if obsidian.enabled { obsidian.ensureFolders() }
        }
    }

    /// The vault: where it is, and the one way to change it — through the Finder, so
    /// Mindtalk is let into the folder it is shown.
    private var vaultRow: some View {
        CardRow(title: String(localized: "Valv"), detail: obsidian.vault == nil
                ? String(localized: "Mappen där Obsidian har dina anteckningar.")
                : String(localized: "Anteckningarna skrivs hit.") + "\n" + obsidian.vaultPath) {
            VStack(alignment: .trailing, spacing: 6) {
                if obsidian.vault == nil {
                    Button("Välj mapp") { obsidian.pickVault() }.buttonStyle(.ink)
                } else {
                    HStack(spacing: 8) {
                        if obsidian.canWrite == true { GrantedLabel(text: String(localized: "Kan skriva")) }
                        Button("Ändra") { obsidian.pickVault() }.buttonStyle(.soft)
                    }
                }
            }
        }
    }

    /// `set` lands the name and answers with the one that was kept, so the field shows
    /// that rather than what was typed.
    private func folderRow(title: String, detail: String, text: Binding<String>, placeholder: String,
                           focus: FocusState<Bool>.Binding, set: @escaping (String) -> String) -> some View {
        CardRow(title: title, detail: detail) {
            TextField(LocalizedStringKey(placeholder), text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .multilineTextAlignment(.trailing)
                .frame(width: 170)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Colors.field))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .strokeBorder(DS.Colors.fieldStroke, lineWidth: 1))
                .focused(focus)
                .onSubmit { text.wrappedValue = set(text.wrappedValue) }
                // Clicking away lands the name too — Enter isn't the only way to mean it.
                .onChange(of: focus.wrappedValue) { _, live in
                    if !live { text.wrappedValue = set(text.wrappedValue) }
                }
        }
    }
}
