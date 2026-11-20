//
//  DevSettingsView.swift
//  boringNotch
//

import Defaults
import SwiftUI

struct DevSettingsView: View {
    @Default(.devAskInNotch) private var askInNotch
    @Default(.devAskTimeout) private var askTimeout

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .devSounds) {
                    Text("Play sounds for dev events")
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Plays a sound for finished, failed, and waiting dev events.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Defaults.Toggle(key: .devMascotMusic) {
                    Text("React to music")
                }
                Defaults.Toggle(key: .devMascotMusicControls) {
                    Text("Play/pause and skip music from mascots")
                }
                Defaults.Toggle(key: .devSubagentBadge) {
                    Text("Show subagent count")
                }
            } header: {
                Text("Mascots")
            } footer: {
                Text("Music reactions show headphones and bobbing while music plays. Clicking a mascot always pokes it; the controls add play/pause on click and skip on double-click.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Defaults.Toggle(key: .devAskInNotch) {
                    Text("Show questions in the notch")
                }
                Stepper(value: $askTimeout, in: 15...600, step: 15) {
                    HStack {
                        Text("Answer timeout")
                        Spacer()
                        Text("\(askTimeout) s")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .disabled(!askInNotch)
            } header: {
                Text("Questions")
            } footer: {
                Text("When off, questions from dev tools are answered in the terminal instead. A question with no answer in time counts as skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
