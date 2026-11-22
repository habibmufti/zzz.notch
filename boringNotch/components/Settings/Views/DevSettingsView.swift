//
//  DevSettingsView.swift
//  boringNotch
//

import Defaults
import SwiftUI

struct DevSettingsView: View {
    @Default(.devLiveActivityStyle) private var liveActivityStyle
    @Default(.devFullscreenMode) private var fullscreenMode
    @Default(.devAskInNotch) private var askInNotch
    @Default(.devAskTimeout) private var askTimeout
    @Default(.enableSystemTab) private var enableSystemTab
    @Default(.systemRefreshInterval) private var systemRefreshInterval

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
                Picker("Closed notch style", selection: $liveActivityStyle) {
                    ForEach(DevLiveActivityStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                if liveActivityStyle == .face {
                    Defaults.Toggle(key: .faceShowWhenIdle) {
                        Text("Always show face when idle")
                    }
                    Defaults.Toggle(key: .devMascotMusic) {
                        Text("React to music")
                    }
                    Defaults.Toggle(key: .faceReactCalendar) {
                        Text("React to upcoming meetings")
                    }
                    Defaults.Toggle(key: .faceReactSystem) {
                        Text("React to thermal, memory, and battery alerts")
                    }
                    Defaults.Toggle(key: .faceTrackCursor) {
                        Text("Track cursor with eyes")
                    }
                } else {
                    Defaults.Toggle(key: .devMascotMusic) {
                        Text("React to music")
                    }
                    Defaults.Toggle(key: .devMascotMusicControls) {
                        Text("Play/pause and skip music from mascots")
                    }
                    Defaults.Toggle(key: .devSubagentBadge) {
                        Text("Show subagent count")
                    }
                }
            } header: {
                Text("Closed notch")
            } footer: {
                Text(liveActivityStyle == .mascots
                    ? "Music reactions show headphones and bobbing while music plays. Clicking a mascot always pokes it; the controls add play/pause on click and skip on double-click."
                    : "The face represents your Mac in the closed notch — reacting live to agents, music, imminent meetings, notifications, and event-driven system alerts with zero background polling.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("In full screen", selection: $fullscreenMode) {
                    ForEach(DevFullscreenMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            } header: {
                Text("Full screen")
            } footer: {
                Text(fullscreenMode.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Defaults.Toggle(key: .devVerboseCard) {
                    Text("Detailed session card")
                }
            } header: {
                Text("Dev tab")
            } footer: {
                Text("Shows task, current step, plan, subagents and recent actions. Off: one compact row per session.")
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

            Section {
                Defaults.Toggle(key: .enableSystemTab) {
                    Text("Show System Usage tab")
                }
                Picker("Refresh interval", selection: $systemRefreshInterval) {
                    Text("1 s").tag(1.0)
                    Text("1.5 s").tag(1.5)
                    Text("2 s").tag(2.0)
                    Text("3 s").tag(3.0)
                }
                .disabled(!enableSystemTab)
                Defaults.Toggle(key: .systemShowSparkline) {
                    Text("Show CPU sparkline")
                }
                .disabled(!enableSystemTab)
            } header: {
                Text("System Usage")
            } footer: {
                Text("Samples CPU, memory pressure, network, disk, thermal state, and battery only while the notch is open on the System tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
