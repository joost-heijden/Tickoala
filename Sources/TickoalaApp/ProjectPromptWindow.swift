import SwiftUI
import TickoalaCore

/// The morning question: which project are you starting on? It opens by itself
/// when Tickoala wants a project chosen, and also sits in the menu.
struct ProjectPromptWindow: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let selection = model.pendingWifiProjectSelection {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Which project are you starting on?")
                        .font(.headline)
                    Text("Detected: \(selection.ssid)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(selection.projects) { project in
                        Button {
                            model.chooseWifiProject(selection, projectId: project.id)
                            dismiss()
                        } label: {
                            HStack {
                                Text(project.label)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .controlSize(.large)
                    }
                }
                HStack {
                    Spacer()
                    Button("Not now") {
                        model.cancelWifiProjectSelection()
                        dismiss()
                    }
                }
            } else {
                Text("No project to choose right now.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        // Fill the window: otherwise the background only covers the content and
        // shows as a white stripe on a grey window.
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tickoalaWindowBackground()
    }
}
