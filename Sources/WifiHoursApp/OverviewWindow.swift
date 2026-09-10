import SwiftUI
import WifiHoursCore

/// Dag-, week- en maandoverzicht met correcties.
struct OverviewWindow: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var selection: Int64?
    @State private var addingFor: Int64?

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
                EntryEditor(model: model, row: row) { self.selection = nil }
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
                Text("Alle organisaties").tag(Int64?.none)
                ForEach(model.profiles, id: \.profile.id) { item in
                    Text(item.profile.name).tag(Int64?.some(item.profile.id))
                }
            }
            .frame(width: 180)
            .fixedSize()
        }
        .padding(10)
    }

    private var table: some View {
        Table(model.overviewEntries, selection: $selection) {
            TableColumn("Datum") { Text(Formatting.day($0.entry.startedAt)) }.width(90)
            TableColumn("Start") { Text(Formatting.clock($0.entry.startedAt)) }.width(50)
            TableColumn("Einde") { Text($0.entry.endedAt.map(Formatting.clock) ?? "—") }.width(50)
            TableColumn("Duur") { Text(Formatting.duration($0.entry.duration())) }.width(60)
            TableColumn("Organisatie") { Text($0.profileName) }.width(min: 100, ideal: 120)
            TableColumn("Project") { Text($0.projectLabel) }.width(min: 160, ideal: 220)
            TableColumn("Status") { row in
                Text(row.entry.status.rawValue)
                    .foregroundStyle(row.entry.status == .open ? Color.orange : .secondary)
            }.width(80)
            TableColumn("Bron") { Text($0.entry.source.rawValue).foregroundStyle(.secondary) }.width(90)
            TableColumn("Notitie") { Text($0.entry.note ?? "") }
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Text("Totaal \(Formatting.duration(model.overviewTotal))  (\(Formatting.decimalHours(model.overviewTotal)) uur)")
                .font(.headline)

            ForEach(model.overviewByProject.prefix(4), id: \.label) { item in
                Text("\(item.label): \(Formatting.duration(item.total))")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Projecten…") {
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
}

/// Correctieformulier voor één blok.
struct EntryEditor: View {
    @ObservedObject var model: AppModel
    let row: AppModel.EntryRow
    var onClose: () -> Void

    @State private var start: Date
    @State private var end: Date
    @State private var hasEnd: Bool
    @State private var note: String
    @State private var projectId: Int64?
    @State private var confirmDelete = false

    init(model: AppModel, row: AppModel.EntryRow, onClose: @escaping () -> Void) {
        self.model = model
        self.row = row
        self.onClose = onClose
        _start = State(initialValue: row.entry.startedAt)
        _end = State(initialValue: row.entry.endedAt ?? row.entry.startedAt.addingTimeInterval(3600))
        _hasEnd = State(initialValue: row.entry.endedAt != nil)
        _note = State(initialValue: row.entry.note ?? "")
        _projectId = State(initialValue: row.entry.projectId)
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
                Button("Bewaren") {
                    model.updateEntry(
                        id: row.entry.id,
                        projectId: projectId,
                        start: start,
                        end: hasEnd ? end : nil,
                        note: note,
                        status: hasEnd ? .completed : (row.entry.status == .running ? .running : .open)
                    )
                }
                .keyboardShortcut(.defaultAction)

                Button("Verwijderen", role: .destructive) { confirmDelete = true }
                Spacer()
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
