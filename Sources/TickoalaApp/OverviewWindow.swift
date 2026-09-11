import SwiftUI
import TickoalaCore

/// Day, week and month overview with corrections.
struct OverviewWindow: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var selection: Int64?
    @State private var addingFor: Int64?
    /// Shortcuts may only fire when the table is the active side; if the cursor is
    /// in the correction form, that form wins.
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
                    Text("Choose a block to correct it.")
                        .foregroundStyle(.secondary)
                        .padding()
                    Spacer()
                }
                .frame(minWidth: 280, maxWidth: 360)
            }
        }
        .frame(minWidth: 900, minHeight: 460)
        // A disappeared block (different period, deleted) must not stay selected;
        // otherwise the form points at something that no longer exists.
        .onChange(of: model.overviewEntries.map { $0.id }) { ids in
            if let selection, !ids.contains(selection) {
                self.selection = nil
            }
        }
        .confirmationDialog("Delete block \(deleteTarget ?? 0)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if let id = deleteTarget, model.deleteEntry(id: id) {
                    selection = nil
                    deleteTarget = nil
                }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("This action cannot be undone.")
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
            Button("Today") { model.anchor = Date() }
                .fixedSize()
            Button {
                model.shiftPeriod(1)
            } label: {
                Image(systemName: "chevron.right")
            }

            // One line, and allowed to shrink before the buttons do.
            Text(rangeLabel)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)

            Spacer(minLength: 8)

            Picker("", selection: $model.profileFilter) {
                Text("All customers").tag(Int64?.none)
                ForEach(model.profiles, id: \.profile.id) { item in
                    Text(item.profile.name).tag(Int64?.some(item.profile.id))
                }
            }
            .frame(width: 180)
            .fixedSize()

            // Fixed size, otherwise this vertical line stretches the whole toolbar.
            Rectangle()
                .fill(.separator)
                .frame(width: 1, height: 22)

            Button {
                addNewBlock()
            } label: {
                Image(systemName: "plus")
                    .accessibilityLabel("Add block")
            }
            .help("Add a new block")
            .disabled(addProfileId == nil)

            Button {
                duplicateSelectedEntry()
            } label: {
                Image(systemName: "plus.on.rectangle")
                    .accessibilityLabel("Duplicate")
            }
            .help("Duplicate the selected block (⌘D)")
            .keyboardShortcut("d", modifiers: .command)
            .disabled(!canDuplicate || !tableFocused)

            Button {
                deleteSelectedEntry()
            } label: {
                Image(systemName: "trash")
                    .accessibilityLabel("Delete")
            }
            .help("Delete the selected block (Delete)")
            .disabled(!canDelete || !tableFocused)
        }
        .padding(10)
    }

    private var table: some View {
        Table(of: AppModel.EntryRow.self, selection: $selection) {
            TableColumn("Date") { Text(Formatting.day($0.entry.startedAt)) }.width(90)
            TableColumn("Start") { Text(Formatting.clock($0.entry.startedAt)) }.width(50)
            TableColumn("End") { Text($0.entry.endedAt.map(Formatting.clock) ?? "—") }.width(50)
            TableColumn("Duration") { Text(Formatting.duration($0.entry.duration())) }.width(60)
            TableColumn("Customer") { Text($0.profileName) }.width(min: 100, ideal: 120)
            TableColumn("Project") { Text($0.projectLabel) }.width(min: 160, ideal: 220)
            TableColumn("Amount") { row in
                Text(row.hourlyRateCents > 0 ? Formatting.money(cents: row.amountCents, currency: row.currency) : "—")
                    .foregroundStyle(row.hourlyRateCents > 0 ? .primary : .secondary)
            }.width(90)
            TableColumn("Status") { row in
                Text(row.entry.status.rawValue)
                    .foregroundStyle(row.entry.status == .open ? Color.orange : .secondary)
            }.width(80)
            TableColumn("Source") { Text($0.entry.source.rawValue).foregroundStyle(.secondary) }.width(90)
            TableColumn("Note") { Text($0.entry.note ?? "") }
        } rows: {
            ForEach(model.overviewEntries) { row in
                TableRow(row)
                    .contextMenu {
                        Button("Edit") { selection = row.id }
                        Button("Duplicate") { duplicateSelectedEntry(row.id) }
                            .disabled(row.entry.status == .running)
                        Divider()
                        Button("Delete", role: .destructive) { requestDelete(row.id) }
                    }
            }
        }
        // Delete and ⌘D only work with the table as the first responder; otherwise
        // Backspace in the note would wipe a whole row.
        .focusable()
        .focused($tableFocused)
        .onDeleteCommand { deleteSelectedEntry() }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Text("Total \(Formatting.duration(model.overviewTotal))  (\(Formatting.decimalHours(model.overviewTotal)) hours)")
                .font(.headline)

            if model.overviewAmountCents > 0 {
                Text("Amount \(Formatting.money(cents: model.overviewAmountCents, currency: model.overviewCurrency))")
                    .font(.headline)
                    .help("Net hours × the customer's hourly rate")
            }

            ForEach(model.overviewByProject.prefix(4), id: \.label) { item in
                Text("\(item.label): \(Formatting.duration(item.total))")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Projects") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "projects")
            }
            .fixedSize()

            Menu("Add block") {
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
        case .week, .month: return "\(Formatting.day(range.start)) to \(Formatting.day(last))"
        }
    }

    private var selectedRow: AppModel.EntryRow? {
        guard let selection else { return nil }
        return model.overviewEntries.first(where: { $0.id == selection })
    }

    /// A running block has no end yet and therefore cannot be copied.
    private var canDuplicate: Bool {
        selectedRow.map { $0.entry.status != .running } ?? false
    }

    private var canDelete: Bool { selectedRow != nil }

    /// The customer the add button should use: the selected block's customer,
    /// otherwise the active filter, otherwise the first customer.
    private var addProfileId: Int64? {
        if let selectedRow { return selectedRow.entry.profileId }
        if let filter = model.profileFilter { return filter }
        return model.profiles.first?.profile.id
    }

    private func addNewBlock() {
        guard let profileId = addProfileId else { return }
        addingFor = profileId
    }

    /// Duplicate from the keyboard or the buttons: only when the table is the
    /// active side, so ⌘D doesn't fire while the form has focus.
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

    /// Deleting is irreversible, so a confirmation first.
    private func requestDelete(_ id: Int64) {
        guard model.overviewEntries.contains(where: { $0.id == id }) else { return }
        deleteTarget = id
        confirmDelete = true
    }
}

/// Correction form for one block.
struct EntryEditor: View {
    @ObservedObject var model: AppModel
    let row: AppModel.EntryRow
    var onClose: () -> Void
    /// Receives the id of the new second block after a break has been inserted.
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

        // By default a half hour of break around the middle, so something sensible
        // is there immediately without the user having to calculate.
        let breakWindow = defaultBreak(
            start: row.entry.startedAt,
            end: row.entry.endedAt ?? row.entry.startedAt.addingTimeInterval(3600)
        )
        _pauseStart = State(initialValue: breakWindow.start)
        _pauseEnd = State(initialValue: breakWindow.end)
    }

    var body: some View {
        Form {
            Section("Block \(row.entry.id) — \(row.profileName)") {
                DatePicker("Start", selection: $start)
                Toggle("End recorded", isOn: $hasEnd)
                DatePicker("End", selection: $end)
                    .disabled(!hasEnd)
                Picker("Project", selection: $projectId) {
                    Text("(no project)").tag(Int64?.none)
                    ForEach(model.projects(for: row.entry.profileId)) { project in
                        Text(project.label).tag(Int64?.some(project.id))
                    }
                }
                FormFieldStacked(label: "Note") {
                    TextField("", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Duration", value: Formatting.duration(hasEnd ? end.timeIntervalSince(start) : row.entry.duration()))
                LabeledContent("Source", value: row.entry.source.rawValue)
            }

            if row.entry.status == .open {
                Text("This block is missing a credible end. Enter the end and save; the status will then be completed.")
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)

                Button("Delete", role: .destructive) { confirmDelete = true }
                Spacer()
            }

            if hasEnd {
                Section("Add break") {
                    DatePicker("Break starts", selection: $pauseStart)
                    DatePicker("Break ends", selection: $pauseEnd)
                    LabeledContent("Break duration", value: Formatting.duration(max(0, pauseEnd.timeIntervalSince(pauseStart))))
                    Button {
                        // Save the corrections first, then split: the break is
                        // validated against the just-saved start and end.
                        save()
                        if let second = model.splitEntry(id: row.entry.id, pauseStart: pauseStart, pauseEnd: pauseEnd) {
                            onSplit(second)
                        }
                    } label: {
                        Label("Insert break", systemImage: "pause.circle")
                    }
                    .disabled(!canSplit)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete block \(row.entry.id)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                model.deleteEntry(id: row.entry.id)
                onClose()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// A break can only fall within the (edited) start and end.
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

/// Add a block by hand, for example after sleep.
struct AddEntrySheet: View {
    @ObservedObject var model: AppModel
    let profileId: Int64
    var onClose: () -> Void

    @State private var start = Formatting.calendar.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var end = Formatting.calendar.date(bySettingHour: 17, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var note = ""
    @State private var projectId: Int64?
    @State private var hasBreak = false
    @State private var pauseStart: Date
    @State private var pauseEnd: Date

    init(model: AppModel, profileId: Int64, onClose: @escaping () -> Void) {
        self.model = model
        self.profileId = profileId
        self.onClose = onClose
        // A half hour of break around the middle, so a sensible default is there
        // immediately without the user having to calculate.
        let begin = Formatting.calendar.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
        let finish = Formatting.calendar.date(bySettingHour: 17, minute: 0, second: 0, of: Date()) ?? Date()
        let breakWindow = defaultBreak(start: begin, end: finish)
        _pauseStart = State(initialValue: breakWindow.start)
        _pauseEnd = State(initialValue: breakWindow.end)
    }

    var body: some View {
        Form {
            Section("Add block") {
                DatePicker("Start", selection: $start)
                DatePicker("End", selection: $end)
                Picker("Project", selection: $projectId) {
                    Text("(no project)").tag(Int64?.none)
                    ForEach(model.projects(for: profileId)) { project in
                        Text(project.label).tag(Int64?.some(project.id))
                    }
                }
                FormField(label: "Note", labelWidth: 90) {
                    TextField("", text: $note)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Duration", value: Formatting.duration(end.timeIntervalSince(start)))
            }
            Section("Break") {
                Toggle("Add break", isOn: $hasBreak)
                if hasBreak {
                    DatePicker("Break starts", selection: $pauseStart)
                    DatePicker("Break ends", selection: $pauseEnd)
                    LabeledContent("Break duration", value: Formatting.duration(max(0, pauseEnd.timeIntervalSince(pauseStart))))
                }
            }
            HStack {
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
                Button("Cancel", role: .cancel) { onClose() }
                Spacer()
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .onAppear {
            projectId = model.profiles.first(where: { $0.profile.id == profileId })?.project?.id
        }
        // With a changed start/end the break should still fall in the block.
        .onChange(of: hasBreak) { on in
            guard on, end > start else { return }
            let window = defaultBreak(start: start, end: end)
            pauseStart = window.start
            pauseEnd = window.end
        }
    }

    /// The block must be positive, and a break must fall within it.
    private var canAdd: Bool {
        guard end > start else { return false }
        guard hasBreak else { return true }
        return pauseStart >= start && pauseEnd <= end && pauseStart < pauseEnd
    }

    private func add() {
        guard let id = model.addEntry(profileId: profileId, projectId: projectId, start: start, end: end, note: note) else {
            return
        }
        if hasBreak {
            model.splitEntry(id: id, pauseStart: pauseStart, pauseEnd: pauseEnd)
        }
        onClose()
    }
}

/// A half hour of break around the middle of the block, clipped to the end.
private func defaultBreak(start: Date, end: Date) -> (start: Date, end: Date) {
    let middle = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
    let length = min(30 * 60, max(0, end.timeIntervalSince(middle)))
    return (middle, middle.addingTimeInterval(length))
}
