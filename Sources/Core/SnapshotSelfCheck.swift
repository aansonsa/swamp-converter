import SwiftUI

// A snapshot of the standard controls in the harness window, so the "active look" workaround (see Snapshots.swift) is checked by eye after every macOS update:
// the switch, slider, segmented control and progress bar must draw in the accent colour, the traffic lights in colour. If they come out grey, AppKit stopped
// asking the questions the snapshot windows answer, and every module's control snapshots would be misleading.

struct HarnessControlsSample: View {
    @State private var on = true
    @State private var level = 0.6
    @State private var mode = 1

    var body: some View {
        Form {
            Section("Controls") {
                Toggle("Switch", isOn: $on)
                Slider(value: $level) { Text("Slider") }
                Picker("Segmented", selection: $mode) { Text("One").tag(0); Text("Two").tag(1); Text("Three").tag(2) }.pickerStyle(.segmented)
                ProgressView(value: 0.45) { Text("Progress") }
                HStack {
                    Button("Cancel") {}
                    Spacer()
                    Button("Convert") {}.buttonStyle(.borderedProminent)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

enum CoreSnapshots {
    @MainActor
    static func register() {
        SnapshotRegistry.shared.register("core.harness-controls", size: CGSize(width: 380, height: 300), backdrop: .windowBackground, chrome: .window(title: "Harness"),
                                         variants: SnapshotVariant.lightDark) { HarnessControlsSample() }
    }
}
