import SwiftUI
import WifiHoursCore

/// Automatische pauzeaftrek per klant instellen.
struct BreakWindow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.profiles.isEmpty {
                Spacer()
                Text("Nog geen organisatie ingesteld.")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(model.profiles, id: \.profile.id) { item in
                            BreakRuleForm(model: model, profile: item.profile)
                                .id(item.profile.id)
                        }
                    }
                    .padding()
                }

                Divider()
                HStack {
                    Text("De aftrek is een rekenregel: je tijdregistraties blijven ongewijzigd, "
                         + "dus je kunt de pauze altijd aanpassen of uitzetten.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(10)
            }
        }
        .frame(minWidth: 520, minHeight: 380)
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
                Toggle("Automatisch pauze aftrekken", isOn: $enabled)
                    .onChange(of: enabled) { _ in save() }

                HStack {
                    Text("Pauzeduur")
                    Spacer()
                    Stepper(value: $minutes, in: 0...240, step: 5) {
                        Text("\(minutes) minuten")
                            .monospacedDigit()
                    }
                    .onChange(of: minutes) { _ in save() }
                    .frame(width: 190)
                }
                .disabled(!enabled)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Aftrekken vanaf")
                        Text("Werk je die dag minder, dan gaat er niets af.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Stepper(value: $thresholdHours, in: 0...24) {
                        Text("\(thresholdHours) uur")
                            .monospacedDigit()
                    }
                    .onChange(of: thresholdHours) { _ in save() }
                    .frame(width: 120)

                    Stepper(value: $thresholdMinutes, in: 0...55, step: 5) {
                        Text("\(thresholdMinutes) min")
                            .monospacedDigit()
                    }
                    .onChange(of: thresholdMinutes) { _ in save() }
                    .frame(width: 120)
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
            return "Uit: de uren van \(profile.name) worden volledig geteld."
        }
        let threshold = thresholdHours * 60 + thresholdMinutes
        let net = max(0, threshold - minutes)
        return "Vanaf \(Formatting.duration(TimeInterval(threshold) * 60)) werk op een dag "
            + "gaat er \(minutes) minuten af. Een dag van precies "
            + "\(Formatting.duration(TimeInterval(threshold) * 60)) telt dan als "
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
