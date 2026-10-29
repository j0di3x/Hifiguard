import AppKit
import SwiftUI

struct PanelView: View {
    @Bindable var lock: HiFiLock
    @Bindable var eq: EQController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: lock.status.isHiFi ? "headphones" : "phone")
                    .font(.title2)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(lock.status.title).font(.headline)
                    if let detail = lock.status.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Toggle("Hi-fi Lock", isOn: $lock.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("Hi-fi Lock")
            }
            Picker("Mic", selection: $lock.preferredMicUID) {
                Text("Automatic (Mac Microphone)").tag(String?.none)
                ForEach(lock.replacementMics) { mic in
                    Text(mic.name).tag(String?.some(mic.uid))
                }
            }
            .disabled(!lock.isEnabled)

            Divider()
            EQView(eq: eq)
            Divider()

            HStack {
                Spacer()
                Button("Quit Hifiguard") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

struct MenuBarLabel: View {
    let lock: HiFiLock

    var body: some View {
        Image(systemName: lock.status.isHiFi ? "headphones" : "phone")
    }
}
