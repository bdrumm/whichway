import SwiftUI

/// A note on how the app is behaving, kept on the trip at the moment the rider opened this (`DevNote`), so the trip
/// review sets it beside what the sensors and the feeds had then; and the words for the moments marked from the Live
/// Activity on the way. A preset says the commonest failures in one tap (`DevNotePreset`); words are optional then.
struct DevNoteSheet: View {
    /// The moment a new note is about: when the rider tapped to open this.
    let moment: Double
    /// What the phone has in hand now ("On the F · leg 1"), or which trip the note goes on.
    let context: String
    let notes: [DevNote]
    let onSave: (String, String?) -> Void
    let onWriteMark: (Double, String, String?) -> Void
    let onDropMark: (Double) -> Void
    @State private var text = ""
    @State private var preset: String? = nil
    @State private var markTexts: [Double: String] = [:]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                        ForEach(DevNotePreset.all) { p in
                            Button { preset = preset == p.id ? nil : p.id } label: {
                                Label(p.label, systemImage: p.symbol).font(.caption.weight(.semibold)).lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.bordered).tint(preset == p.id ? .accentColor : .secondary)
                            .accessibilityAddTraits(preset == p.id ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                    TextField(preset == nil ? "What did the app do, and what did you expect?" : "Anything to add? (optional)", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("Note at \(Fmt.hhmm(moment))")
                } footer: {
                    Text("\(context). Kept on the trip at \(clock(moment)) with what the phone believed then; the trip review shows it beside the sensors and the trains.")
                }
                let marks = notes.pendingMarks
                if !marks.isEmpty {
                    Section {
                        ForEach(marks, id: \.ts) { m in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Marked \(clock(m.ts))\(m.line.map { " · on the \(route($0))" } ?? "")").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                HStack {
                                    TextField("What happened then?", text: Binding(get: { markTexts[m.ts] ?? "" }, set: { markTexts[m.ts] = $0 }), axis: .vertical)
                                        .lineLimit(1...5)
                                    Menu {
                                        ForEach(DevNotePreset.all) { p in
                                            Button { onWriteMark(m.ts, markTexts[m.ts] ?? "", p.id); markTexts[m.ts] = nil } label: { Label(p.label, systemImage: p.symbol) }
                                        }
                                    } label: { Image(systemName: "list.bullet") }
                                    .accessibilityLabel("Pick what happened")
                                    Button("Save") { onWriteMark(m.ts, markTexts[m.ts] ?? "", nil); markTexts[m.ts] = nil }
                                        .disabled(DevNote.clean(markTexts[m.ts] ?? "").isEmpty)
                                }
                            }
                            .swipeActions { Button("Delete", role: .destructive) { onDropMark(m.ts) } }
                        }
                    } header: {
                        Text("Marked from the Live Activity")
                    } footer: {
                        Text("Each note keeps the moment you tapped. Swipe one away if you tapped by mistake.")
                    }
                }
                let written = notes.filter { !$0.pending }
                if !written.isEmpty {
                    Section("On this trip") {
                        ForEach(written, id: \.ts) { n in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(clock(n.ts)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(n.summary).font(.subheadline)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Note on the app")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(text, preset); dismiss() }.disabled(DevNote.clean(text).isEmpty && preset == nil)
                }
            }
        }
    }

    private func clock(_ ts: Double) -> String { Fmt.hhmmss(ts) }

    private func route(_ key: String) -> String { String(key.split(separator: "_").first ?? "") }
}
