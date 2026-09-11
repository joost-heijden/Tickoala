import SwiftUI
import TickoalaCore

/// Dag-, week- en maandoverzicht met correcties.
struct OverviewWindow: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var selection: Int64?
    @State private var addingFor: Int64?
    /// Sneltoetsen mogen alleen vuren als de tabel de actieve kant is; staat de
    /// cursor in het correctieformulier, dan wint dat formulier.
    @FocusState private var tableFocused: Bool
    @State private var confirmDelete = false
    @State private var deleteTarget: Int64?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                toolbar
                Divider()
                table
                Divider()
                footer
            }
            .frame(minWidth: 620)

            if let selection, let row = model.overviewEntries.first(where: { $0.id == selection }) {
                EntryEditor(
                    model: model,
                    row: row,
                    onClose: { self.selection = nil },
                    onSplit: { self.selection = $0 }
                )
                    .id(row.id)
                    .frame(minWidth: 280, maxWidth: 360)
            } else {
                VStack {
                    Text("Kies een blok om het te corrigeren.")
                        .foregroundStyle(.secondary)
                        .padding()
                    Spacer()
                }
                .frame(minWidth: 280, maxWidth: 360)
            }
        }
        .frame(minWidth: 900, minHeight: 460)
        // Een verdwenen blok (andere periode, weggegooid) mag niet geselecteerd
        // blijven staan; anders wijst het formulier naar iets dat er niet meer is.
        .onChange(of: model.overviewEntries.map { $0.id }) { ids in
            if let selection, !ids.contains(selection) {
                self.selection = nil
            }
        }
        .confirmationDialog("Blok \(deleteTarget ?? 0) verwijderen?", isPresented: $confirmDelete) {
            Button("Verwijderen", role: .destructive) {
                if let id = deleteTarget, model.deleteEntry(id: id) {
                    selection = nil
                    deleteTarget = nil
                }
            }
            Button("Annuleren", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("Deze actie kan niet ongedaan worden gemaakt.")
        }
        .sheet(item: Binding(get: { addingFor.map(ProfileBox.init) }, set: { addingFor = $0?.id })) { box in
            AddEntrySheet(model: model, profileId: box.id) { addingFor = nil }
        }
    }

    private struct ProfileBox: Identifiable { var id: Int64 }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $model.period) {
                ForEach(ReportPeriod.allCases, id: \.self) { period in
                    Text(period.label).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            .fixedSize()

            Button {
                model.shiftPeriod(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            Button("Vandaag") { model.anchor = Date() }
                .fixedSize()
            Button {
                model.shiftPeriod(1)
            } label: {
                Image(systemName: "chevron.right")
            }

            // Één regel, en mag krimpen voordat de knoppen dat doen.
            Text(rangeLabel)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)

            Spacer(minLength: 8)

            Picker("", selection: $model.profileFilter) {
                Text("Alle klanten").tag(Int64?.none)
                ForEach(model.profiles, id: \.profile.id) { item in
                    Text(item.profile.name).tag(Int64?.some(item.profile.id))
                }
            }
            .frame(width: 180)
            .fixedSize()

            // Vaste maat, anders rekt deze verticale streep de hele werkbalk op.
            Rectangle()
                .fill(.separator)
                .frame(width: 1, height: 22)

            Button {
                duplicateSelectedEntry()
            } label: {
                Image(systemName: "plus")
                    .accessibilityLabel("Dupliceer")
            }
            .help("Dupliceer het geselecteerde blok (⌘D)")
            .keyboardShortcut("d", modifiers: .command)
            .disabled(!canDuplicate || !tableFocused)

            Button {
                deleteSelectedEntry()
            } label: {
                Image(systemName: "trash")
                    .accessibilityLabel("Verwijder")
            }
            .help("Verwijder het geselecteerde blok (Delete)")
            .disabled(!canDelete || !tableFocused)
        }
        .padding(10)
    }

    private var table: some View {
        Table(of: AppModel.EntryRow.self, selection: $selection) {
            TableColumn("Datum") { Text(Formatting.day($0.entry.startedAt)) }.width(90)
            TableColumn("Start") { Text(Formatting.clock($0.entry.startedAt)) }.width(50)
            TableColumn("Einde") { Text($0.entry.endedAt.map(Formatting.clock) ?? "—") }.width(50)
            TableColumn("Duur") { Text(Formatting.duration($0.entry.duration())) }.width(60)
            TableColumn("Klant") { Text($0.profileName) }.width(min: 100, ideal: 120)
            TableColumn("Project") { Text($0.projectLabel) }.width(min: 160, ideal: 220)
            TableColumn("Bedrag") { row in
                Text(row.hourlyRateCents > 0 ? Formatting.money(cents: row.amountCents) : "—")
                    .foregroundStyle(row.hourlyRateCents > 0 ? .primary : .secondary)
            }.width(90)
            TableColumn("Status") { row in
                Text(row.entry.status.rawValue)
                    .foregroundStyle(row.entry.status == .open ? Color.orange : .secondary)
            }.width(80)
            TableColumn("Bron") { Text($0.entry.source.rawValue).foregroundStyle(.secondary) }.width(90)
            TableColumn("Notitie") { Text($0.entry.note ?? "") }
        } rows: {
            ForEach(model.overviewEntries) { row in
                TableRow(row)
                    .contextMenu {
                        Button("Bewerk") { selection = row.id }
                        Button("Dupliceer") { duplicateSelectedEntry(row.id) }
                            .disabled(row.entry.status == .running)
                        Divider()
                        Button("Verwijder", role: .destructive) { requestDelete(row.id) }
                    }
            }
        }
        // Alleen met de tabel als eerste aanspreekpunt werken Delete en ⌘D; anders
        // zou Backspace in de notitie een hele regel wissen.
        .focusable()
        .focused($tableFocused)
        .onDeleteCommand { deleteSelectedEntry() }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Text("Totaal \(Formatting.duration(model.overviewTotal))  (\(Formatting.decimalHours(model.overviewTotal)) uur)")
                .font(.headline)

            if model.overviewAmountCents > 0 {
                Text("Bedrag \(Formatting.money(cents: model.overviewAmountCents))")
                    .font(.headline)
                    .help("Netto uren × het uurtarief van de klant")
            }

            ForEach(model.overviewByProject.prefix(4), id: \.label) { item in
                Text("\(item.label): \(Formatting.duration(item.total))")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Projecten") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "projecten")
            }
            .fixedSize()

            Menu("Blok toevoegen") {
                ForEach(model.profiles, id: \.profile.id) { item in
                    Button(item.profile.name) { addingFor = item.profile.id }
                }
            }
            .frame(width: 160)
            .fixedSize()
        }
        .padding(10)
    }

    private var rangeLabel: String {
        let range = model.overviewRange
        let last = range.end.addingTimeInterval(-1)
        switch model.period {
        case .day: return Formatting.day(range.start)
        case .week, .month: return "\(Formatting.day(range.start)) t/m \(Formatting.day(last))"
        }
    }

    private var selectedRow: AppModel.EntryRow? {
        guard let selection else { return nil }
        return model.overviewEntries.first(where: { $0.id == selection })
    }

    /// Een lopend blok heeft nog geen einde en kan dus niet worden gekopieerd.
    private var canDuplicate: Bool {
        selectedRow.map { $0.entry.status != .running } ?? false
    }

    private var canDelete: Bool { selectedRow != nil }

    /// Dupliceren vanaf het toetsenbord of de knoppen: alleen als de tabel de
    /// actieve kant is, zodat ⌘D niet afgaat terwijl het formulier focus heeft.
    private func duplicateSelectedEntry() {
        guard tableFocused, let id = selectedRow?.id else { return }
        duplicateSelectedEntry(id)
    }

    private func duplicateSelectedEntry(_ id: Int64) {
        guard let duplicateID = model.duplicateEntry(id: id) else { return }
        selection = duplicateID
    }

    private func deleteSelectedEntry() {
        guard tableFocused, let id = selectedRow?.id else { return }
        requestDelete(id)
    }

    /// Verwijderen is onomkeerbaar, dus eerst een bevestiging.
    private func requestDelete(_ id: Int64) {
        guard model.overviewEntries.contains(where: { $0.id == id }) else { return }
        deleteTarget = id
        confirmDelete = true
    }
}

/// Correctieformulier voor één blok.
struct EntryEditor: View {
    @ObservedObject var model: AppModel
    let row: AppModel.EntryRow
    var onClose: () -> Void
    /// Krijgt het id van het nieuwe tweede blok nadat er een pauze is ingevoegd.
    var onSplit: (Int64) -> Void

    @State private var start: Date
    @State private var end: Date
    @State private var hasEnd: Bool
    @State private var note: String
    @State private var projectId: Int64?
    @State private var confirmDelete = false
    @State private var pauseStart: Date
    @State private var pauseEnd: Date

    init(
        model: AppModel,
        row: AppModel.EntryRow,
        onClose: @escaping () -> Void,
        onSplit: @escaping (Int64) -> Void
    ) {
        self.model = model
        self.row = row
        self.onClose = onClose
        self.onSplit = onSplit
        _start = State(initialValue: row.entry.startedAt)
        _end = State(initialValue: row.entry.endedAt ?? row.entry.startedAt.addingTimeInterval(3600))
        _hasEnd = State(initialValue: row.entry.endedAt != nil)
        _note = State(initialValue: row.entry.note ?? "")
        _projectId = State(initialValue: row.entry.projectId)

        // Standaard een half uur pauze rond het midden, zodat er meteen iets
        // zinnigs staat zonder dat de gebruiker hoeft te rekenen.
        let begin = row.entry.startedAt
        let einde = row.entry.endedAt ?? begin.addingTimeInterval(3600)
        let midden = begin.addingTimeInterval(einde.timeIntervalSince(begin) / 2)
        let lengte = min(30 * 60, max(0, einde.timeIntervalSince(midden)))
        _pauseStart = State(initialValue: midden)
        _pauseEnd = State(initialValue: midden.addingTimeInterval(lengte))
    }

    var body: some View {
        Form {
            Section("Blok \(row.entry.id) — \(row.profileName)") {
                DatePicker("Begin", selection: $start)
                Toggle("Einde vastgelegd", isOn: $hasEnd)
                DatePicker("Einde", selection: $end)
                    .disabled(!hasEnd)
                Picker("Project", selection: $projectId) {
                    Text("(geen project)").tag(Int64?.none)
                    ForEach(model.projects(for: row.entry.profileId)) { project in
                        Text(project.label).tag(Int64?.some(project.id))
                    }
                }
                TextField("Notitie", text: $note, axis: .vertical)
                    .lineLimit(2...4)
                LabeledContent("Duur", value: Formatting.duration(hasEnd ? end.timeIntervalSince(start) : row.entry.duration()))
                LabeledContent("Bron", value: row.entry.source.rawValue)
            }

            if row.entry.status == .open {
                Text("Dit blok mist een geloofwaardig einde. Vul het einde in en bewaar; de status wordt dan afgerond.")
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Bewaren") { save() }
                    .keyboardShortcut(.defaultAction)

                Button("Verwijderen", role: .destructive) { confirmDelete = true }
                Spacer()
            }

            if hasEnd {
                Section("Pauze toevoegen") {
                    DatePicker("Pauze begint", selection: $pauseStart)
                    DatePicker("Pauze eindigt", selection: $pauseEnd)
                    LabeledContent("Pauzeduur", value: Formatting.duration(max(0, pauseEnd.timeIntervalSince(pauseStart))))
                    Button {
                        // Eerst de correcties bewaren, dan pas splitsen: de pauze
                        // wordt tegen de zojuist bewaarde begin en eind getoetst.
                        save()
                        if let tweede = model.splitEntry(id: row.entry.id, pauseStart: pauseStart, pauseEnd: pauseEnd) {
                            onSplit(tweede)
                        }
                    } label: {
                        Label("Pauze invoegen", systemImage: "pause.circle")
                    }
                    .disabled(!canSplit)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Blok \(row.entry.id) verwijderen?", isPresented: $confirmDelete) {
            Button("Verwijderen", role: .destructive) {
                model.deleteEntry(id: row.entry.id)
                onClose()
            }
            Button("Annuleren", role: .cancel) {}
        }
    }

    /// Een pauze kan alleen binnen de (bewerkte) begin- en eindtijd vallen.
    private var canSplit: Bool {
        row.entry.status != .running
            && pauseStart >= start
            && pauseEnd <= end
            && pauseStart < pauseEnd
    }

    private func save() {
        model.updateEntry(
            id: row.entry.id,
            projectId: projectId,
            start: start,
            end: hasEnd ? end : nil,
            note: note,
            status: hasEnd ? .completed : (row.entry.status == .running ? .running : .open)
        )
    }
}

/// Blok met de hand toevoegen, bijvoorbeeld na een slaapstand.
struct AddEntrySheet: View {
    @ObservedObject var model: AppModel
    let profileId: Int64
    var onClose: () -> Void

    @State private var start = Formatting.calendar.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var end = Formatting.calendar.date(bySettingHour: 17, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var note = ""
    @State private var projectId: Int64?

    var body: some View {
        Form {
            Section("Blok toevoegen") {
                DatePicker("Begin", selection: $start)
                DatePicker("Einde", selection: $end)
                Picker("Project", selection: $projectId) {
                    Text("(geen project)").tag(Int64?.none)
                    ForEach(model.projects(for: profileId)) { project in
                        Text(project.label).tag(Int64?.some(project.id))
                    }
                }
                TextField("Notitie", text: $note)
                LabeledContent("Duur", value: Formatting.duration(end.timeIntervalSince(start)))
            }
            HStack {
                Button("Toevoegen") {
                    model.addEntry(profileId: profileId, projectId: projectId, start: start, end: end, note: note)
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(end <= start)
                Button("Annuleren", role: .cancel) { onClose() }
                Spacer()
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .onAppear {
            projectId = model.profiles.first(where: { $0.profile.id == profileId })?.project?.id
        }
    }
}
