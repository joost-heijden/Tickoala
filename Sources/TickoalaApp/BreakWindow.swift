import SwiftUI
import TickoalaCore

/// Workday settings and the automatic break deduction per customer.
struct BreakWindow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    WorkdaySettings(model: model)
                    NonWorkingDaysSection(model: model)

                    if model.profiles.isEmpty {
                        Text("No customer configured yet.")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 20)
                    } else {
                        ForEach(model.profiles, id: \.profile.id) { item in
                            BreakRuleForm(model: model, profile: item.profile)
                                .id(item.profile.id)
                        }
                    }
                }
                .padding()
            }

            Divider()
            HStack {
                Text("The deduction is a calculation: your time entries stay unchanged, "
                     + "so you can always adjust or turn off the break.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)
        }
        .frame(minWidth: 520, minHeight: 380)
    }
}

/// The start and end of the workday, shared by every customer.
private struct WorkdaySettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        FormSection(title: "Workday") {
            FormField(label: "Day starts at") {
                DatePicker("", selection: timeBinding(
                    get: { model.workdayStartMinutes },
                    set: { model.workdayStartMinutes = $0 }
                ), displayedComponents: .hourAndMinute)
                .labelsHidden()
            }
            FormField(label: "Day ends at") {
                DatePicker("", selection: timeBinding(
                    get: { model.workdayEndMinutes },
                    set: { model.workdayEndMinutes = $0 }
                ), displayedComponents: .hourAndMinute)
                .labelsHidden()
            }
            Text("A block that gets no stop signal — the Mac slept or Tickoala was closed — "
                 + "is closed at the end time instead of running into the night. Automatic "
                 + "check-ins and departures are rounded to the nearest half hour.")
                .font(.caption)
                .foregroundStyle(.secondary)

            FormField(label: "Ask for a project") {
                Picker("", selection: $model.projectPrompt) {
                    ForEach(ProjectPrompt.allCases, id: \.self) { prompt in
                        Text(prompt.label).tag(prompt)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
            }
            Text("When Tickoala starts at a client — on arrival or after the laptop wakes from sleep — "
                 + "ask which project to work on. The choice opens as a window and also sits in the menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// A stored workday time is a minute count; the picker works with a time.
    private func timeBinding(get: @escaping () -> Int, set: @escaping (Int) -> Void) -> Binding<Date> {
        Binding(
            get: {
                var components = DateComponents()
                components.hour = get() / 60
                components.minute = get() % 60
                return Formatting.calendar.date(from: components) ?? Date()
            },
            set: { date in
                let components = Formatting.calendar.dateComponents([.hour, .minute], from: date)
                set((components.hour ?? 0) * 60 + (components.minute ?? 0))
            }
        )
    }
}

/// Holidays and vacation days: marked once, so the tracker does not cut the day
/// off at the workday end and the day is visibly not a normal one.
private struct NonWorkingDaysSection: View {
    @ObservedObject var model: AppModel

    @State private var date = Date()
    @State private var label = ""
    @State private var kind: NonWorkingKind = .holiday

    var body: some View {
        FormSection(title: "Holidays and vacation") {
            HStack(spacing: 8) {
                DatePicker("", selection: $date, displayedComponents: .date)
                    .labelsHidden()
                Picker("", selection: $kind) {
                    ForEach(NonWorkingKind.allCases, id: \.self) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
                TextField("", text: $label, prompt: Text("Label (optional)"))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                Button("Add") { add() }
            }
            if model.nonWorkingDays.isEmpty {
                Text("No non-working days marked.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.nonWorkingDays) { day in
                    HStack {
                        Text(Formatting.day(day.date))
                            .monospacedDigit()
                        Text(day.display)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            model.removeNonWorkingDay(day.date)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                }
            }
            Text("On a marked day the workday-end fallback does not apply: a block without "
                 + "a stop signal closes at the end of the day instead.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func add() {
        model.addNonWorkingDay(Formatting.calendar.startOfDay(for: date), label: label, kind: kind)
        label = ""
    }
}

private struct BreakRuleForm: View {
    @ObservedObject var model: AppModel
    let profile: Profile

    @State private var enabled = false
    @State private var minutes = 30
    @State private var thresholdHours = 6
    @State private var thresholdMinutes = 0
    @State private var loaded = false

    var body: some View {
        GroupBox(profile.name) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Automatically deduct break", isOn: $enabled)
                    .onChange(of: enabled) { _ in save() }

                HStack {
                    Text("Break duration")
                    Spacer()
                    Stepper(value: $minutes, in: 0...240, step: 5) {
                        Text("\(minutes) minutes")
                            .monospacedDigit()
                    }
                    .onChange(of: minutes) { _ in save() }
                    .frame(width: 240, alignment: .trailing)
                }
                .disabled(!enabled)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Deduct from")
                        Text("If you work less that day, nothing is deducted.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Stepper(value: $thresholdHours, in: 0...24) {
                        Text("\(thresholdHours) hours")
                            .monospacedDigit()
                    }
                    .onChange(of: thresholdHours) { _ in save() }
                    .frame(width: 120, alignment: .trailing)

                    Stepper(value: $thresholdMinutes, in: 0...55, step: 5) {
                        Text("\(thresholdMinutes) min")
                            .monospacedDigit()
                    }
                    .onChange(of: thresholdMinutes) { _ in save() }
                    .frame(width: 120, alignment: .trailing)
                }
                .disabled(!enabled)

                Divider()
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(enabled ? .primary : .secondary)
            }
            .padding(6)
        }
        .onAppear(perform: load)
    }

    private var explanation: String {
        guard enabled, minutes > 0 else {
            return "Off: the hours of \(profile.name) are counted in full."
        }
        let threshold = thresholdHours * 60 + thresholdMinutes
        let net = max(0, threshold - minutes)
        return "From \(Formatting.duration(TimeInterval(threshold) * 60)) of work on a day, "
            + "\(minutes) minutes are deducted. A day of exactly "
            + "\(Formatting.duration(TimeInterval(threshold) * 60)) then counts as "
            + "\(Formatting.duration(TimeInterval(net) * 60))."
    }

    private func load() {
        guard !loaded else { return }
        let rule = profile.breakRule
        enabled = rule.enabled
        minutes = rule.minutes
        thresholdHours = rule.thresholdMinutes / 60
        thresholdMinutes = rule.thresholdMinutes % 60
        loaded = true
    }

    private func save() {
        guard loaded else { return }
        model.updateBreakRule(
            profileId: profile.id,
            rule: BreakRule(
                enabled: enabled,
                minutes: minutes,
                thresholdMinutes: thresholdHours * 60 + thresholdMinutes
            )
        )
    }
}
