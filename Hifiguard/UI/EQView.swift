import AppKit
import SwiftUI

struct EQView: View {
    @Bindable var eq: EQController

    private static let privacySettings =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Equalizer").font(.headline)
                    Text(eq.status.text).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Equalizer", isOn: $eq.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if eq.status == .needsPermission {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Allow Hifiguard under Screen & System Audio Recording, then turn the equalizer off and on.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Privacy Settings") { NSWorkspace.shared.open(Self.privacySettings) }
                }
            }

            Picker("Preset", selection: Binding(
                get: { eq.presetName ?? "" },
                set: { name in
                    if let preset = EQPreset.all.first(where: { $0.name == name }) { eq.select(preset) }
                })) {
                ForEach(EQPreset.all) { Text($0.name).tag($0.name) }
                if eq.presetName == nil { Text("Custom").tag("") }
            }

            VStack(spacing: 2) {
                ForEach(0..<EQBands.count, id: \.self) { band in
                    HStack(spacing: 8) {
                        Text(EQBands.label(band))
                            .font(.caption.monospacedDigit())
                            .frame(width: 30, alignment: .trailing)
                        Slider(value: Binding(get: { eq.gains[band] }, set: { eq.setGain(band, $0) }),
                               in: EQBands.gainRange, step: 0.5)
                            .controlSize(.small)
                        Text(String(format: "%+.1f", eq.gains[band]))
                            .font(.caption.monospacedDigit())
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }

            Toggle("Limiter (prevents clipping)", isOn: $eq.isLimiterOn)
                .controlSize(.small)
        }
    }
}
