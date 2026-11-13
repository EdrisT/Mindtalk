import AppKit
import SwiftUI

/// The same names are available in saved meetings and while a meeting is live.
/// Names remain useful even when remembering voices is switched off.
struct SpeakerNamePicker: View {
    @Binding var name: String
    let cast: Cast
    let placeholder: String
    let submit: (String) -> Void
    let cancel: () -> Void
    @ObservedObject private var memory = VoiceMemory.shared
    @ObservedObject private var store = MeetingStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SpeakerNameField(name: $name, rows: rows, placeholder: placeholder,
                             submit: submit, cancel: cancel)
                .frame(height: 26)
            Text("Välj en känd talare eller skriv ett nytt namn.")
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.muted)
        }
        .frame(width: 280)
    }

    private var rows: [SpeakerNames.Row] {
        SpeakerNames.rows(known: memory.people.map(\.name)
            + cast.order.filter { !cast.background.contains($0) }.compactMap { cast.names[String($0)] }
            + store.meetings.flatMap { VoiceMemory.namesToRemember(in: $0) }
            + [Settings.myName ?? ""],
            // The people invited to the event this meeting started from: a name to pick,
            // never a conclusion — one of them may have stayed home.
            invited: cast.expected)
    }
}

enum SpeakerNames {
    /// A row in the list: a name, or the quiet label over a set of names. A label is not
    /// a name — it is never taken for one, and typing never completes to one.
    enum Row: Equatable {
        case header(String)
        case name(String)
    }

    /// The names you already know, then the ones the calendar said were invited, each set
    /// under its own label — so you can tell where a name came from before you give it to
    /// a voice. A name in both sets stands once, with the known ones. One set only, which
    /// is every meeting without a calendar event, and the list stays as plain as it was.
    static func rows(known: [String], invited: [String]) -> [Row] {
        let first = choices(known)
        let rest = choices(invited).filter { name in
            !first.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        guard !first.isEmpty, !rest.isEmpty else { return (first + rest).map(Row.name) }
        return [.header(String(localized: "Kända namn"))] + first.map(Row.name)
            + [.header(String(localized: "Från kalendern"))] + rest.map(Row.name)
    }

    /// Prefer the remembered spelling, without merging distinct accented names.
    static func choices(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// An editable native Mac picker: the arrow lists every name, typing completes a
/// name, and the usual arrow keys, Return and Escape work in the list and field.
struct SpeakerNameField: NSViewRepresentable {
    @Binding var name: String
    let rows: [SpeakerNames.Row]
    let placeholder: String
    let submit: (String) -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.usesDataSource = true
        field.dataSource = context.coordinator
        field.delegate = context.coordinator
        field.completes = true
        field.hasVerticalScroller = true
        field.numberOfVisibleItems = 8
        field.font = .systemFont(ofSize: 13)
        field.setAccessibilityLabel(String(localized: "Ge talaren ett namn"))
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        let previousRows = context.coordinator.parent.rows
        context.coordinator.parent = self
        if previousRows != rows { field.reloadData() }
        field.placeholderString = placeholder
        // Don't reset the field editor or its completion selection on each keystroke.
        if field.stringValue != name { field.stringValue = name }
    }

    final class Field: NSComboBox {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                window.makeFirstResponder(self)
                self.selectText(nil)
            }
        }
    }

    final class Coordinator: NSObject, NSComboBoxDataSource, NSComboBoxDelegate {
        var parent: SpeakerNameField
        init(_ parent: SpeakerNameField) { self.parent = parent }

        func numberOfItems(in comboBox: NSComboBox) -> Int { parent.rows.count }
        func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
            guard parent.rows.indices.contains(index) else { return nil }
            switch parent.rows[index] {
            case .header(let label):
                // Smaller and quieter than a name, so two sets read as two without a line.
                return NSAttributedString(string: label, attributes: [
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                ])
            case .name(let name):
                let selected = comboBox.indexOfSelectedItem == index
                    || (comboBox.indexOfSelectedItem < 0 && comboBox.stringValue == name)
                // AppKit's default white selected text disappears on our white dark-mode
                // accent. Give the list an explicit foreground for its actual highlight.
                return NSAttributedString(string: name, attributes: [
                    .foregroundColor: selected ? selectionTextColor(in: comboBox) : NSColor.controlTextColor,
                ])
            }
        }

        /// The name on a row, nil for the label over a set: a label is never a name.
        private func person(_ index: Int) -> String? {
            guard parent.rows.indices.contains(index), case .name(let name) = parent.rows[index] else { return nil }
            return name
        }

        private var people: [String] {
            parent.rows.compactMap { row -> String? in
                if case .name(let name) = row { return name }
                return nil
            }
        }

        private func selectionTextColor(in comboBox: NSComboBox) -> NSColor {
            var result = NSColor.selectedControlTextColor
            comboBox.effectiveAppearance.performAsCurrentDrawingAppearance {
                guard let color = NSColor.selectedContentBackgroundColor.usingColorSpace(.sRGB) else { return }
                func linear(_ value: CGFloat) -> CGFloat {
                    value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
                }
                let luminance = 0.2126 * linear(color.redComponent)
                    + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
                let blackContrast = (luminance + 0.05) / 0.05
                let whiteContrast = 1.05 / (luminance + 0.05)
                result = blackContrast >= whiteContrast ? .black : .white
            }
            return result
        }
        func comboBox(_ comboBox: NSComboBox, indexOfItemWithStringValue string: String) -> Int {
            parent.rows.firstIndex { row in
                if case .name(let name) = row { return name.caseInsensitiveCompare(string) == .orderedSame }
                return false
            } ?? NSNotFound
        }
        func comboBox(_ comboBox: NSComboBox, completedString string: String) -> String? {
            guard !string.isEmpty else { return nil }
            return people.first {
                $0.range(of: string, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSComboBox,
                  let editor = field.currentEditor() as? NSTextView else { return }
            editor.isAutomaticTextCompletionEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSComboBox else { return }
            parent.name = field.stringValue
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSComboBox,
                  parent.rows.indices.contains(field.indexOfSelectedItem) else { return }
            // The pointer and the arrow keys step over a label to the name nearest it:
            // a set's heading is not a name and never becomes one in the field.
            if person(field.indexOfSelectedItem) == nil {
                let past = (field.indexOfSelectedItem + 1..<parent.rows.count).first { person($0) != nil }
                    ?? (0..<field.indexOfSelectedItem).reversed().first { person($0) != nil }
                if let past { field.selectItem(at: past) }
                return
            }
            // AppKit can notify before stringValue reflects the selected row.
            parent.name = person(field.indexOfSelectedItem) ?? ""
            field.reloadData()
        }

        func comboBoxSelectionIsChanging(_ notification: Notification) {
            // Recolor both rows as the highlight moves with the mouse or arrow keys.
            (notification.object as? NSComboBox)?.reloadData()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            if command == #selector(NSResponder.insertNewline(_:)) {
                parent.name = control.stringValue
                parent.submit(control.stringValue)
                return true
            }
            if command == #selector(NSResponder.cancelOperation(_:)) {
                parent.cancel()
                return true
            }
            return false
        }
    }
}
