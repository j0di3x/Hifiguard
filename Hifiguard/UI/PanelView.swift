import AppKit
import ServiceManagement
import SwiftUI

struct PanelView: View {
    @Bindable var lock: HiFiLock
    @Bindable var eq: EQController
    @Bindable var updates: UpdateChecker
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    private func setOpenAtLogin(_ on: Bool) {
        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

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

            if let release = updates.available {
                HStack {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
                    Text("Hifiguard \(release.version) is available").font(.callout)
                    Spacer()
                    Button("Download") { NSWorkspace.shared.open(release.url) }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Open at login", isOn: Binding(get: { openAtLogin }, set: setOpenAtLogin))
                Toggle("Check for updates daily", isOn: $updates.isAutomatic)
            }
            .controlSize(.small)

            HStack {
                Button(updates.isChecking ? "Checking…" : "Check for Updates") { updates.checkNow() }
                    .disabled(updates.isChecking)
                if let message = updates.manualCheckMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .controlSize(.small)
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
