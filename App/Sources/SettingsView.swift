import SwiftUI

@MainActor
struct SettingsView: View {
    let state: SettingsViewState

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Capture adapter") {
                        Text(state.captureAdapterSummary)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Capture")
                } footer: {
                    Text("Choose a capture mode in the scanner. Camera access is requested when you start.")
                }

                Section {
                    LabeledContent("Scan packages") {
                        Text(state.storageSummary)
                            .multilineTextAlignment(.trailing)
                    }

                    Text(state.privacySummary)
                        .font(.body)
                        .accessibilityIdentifier(AccessibilityID.settingsLocalOnly)
                } header: {
                    Text("Local data")
                }

                Section {
                    LabeledContent("Build") {
                        Text(state.buildSummary)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
        }
        .accessibilityIdentifier(AccessibilityID.settingsRoot)
    }
}

#Preview("Settings") {
    SettingsView(state: DemoSettingsService().currentSettings())
}
