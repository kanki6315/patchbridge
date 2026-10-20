import SwiftUI

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @State private var precise = false
    @State private var entry = ""
    @State private var entryError = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Simulation only", systemImage: "waveform.path")
                        .font(.headline)
                    Text("Try the Bluetooth editing loop with your Mac. No Quad Cortex is connected.")
                        .foregroundStyle(.secondary)
                }
                Section("Connection") {
                    Label(model.status, systemImage: model.ready ? "checkmark.circle" : "antenna.radiowaves.left.and.right")
                    if model.busy { ProgressView("Waiting for Mac…") }
                    if model.needsApproval {
                        Text("In the Mac bridge terminal, enter the approval command shown for this connection.")
                            .foregroundStyle(.secondary)
                        Button("I’ve approved on Mac", action: model.authorize).disabled(model.busy)
                    } else if !model.connected {
                        Button("Find my Mac", action: model.scan)
                    }
                    if model.connected { Button("Disconnect", role: .destructive, action: model.disconnect) }
                }
                if let error = model.error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
                if model.ready {
                    Section {
                        LabeledContent("Preset", value: model.preset)
                        Picker("Scene", selection: Binding(get: { model.scene }, set: model.changeScene)) {
                            Text("A").tag("A"); Text("B").tag("B")
                        }.pickerStyle(.segmented).disabled(model.busy)
                        Label(model.dirty ? "Unsaved changes" : "Saved", systemImage: model.dirty ? "circle.fill" : "checkmark")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Section("Simulated amp") {
                        HStack {
                            Text("Gain")
                            Spacer()
                            Button {
                                entry = String(format: "%.2f", model.gain); precise = true
                            } label: {
                                Text(model.gain, format: .number.precision(.fractionLength(2)))
                                    .monospacedDigit().font(.title2.weight(.semibold))
                            }.accessibilityLabel("Enter exact gain").disabled(model.busy)
                        }
                        Slider(value: $model.gain, in: 0...10, onEditingChanged: { editing in
                            if !editing { model.commitGain() }
                        }).disabled(model.busy).accessibilityLabel("Gain")
                        HStack { Text("0"); Spacer(); Text("10") }.font(.caption).foregroundStyle(.secondary)
                        Text(model.busy ? "Pending confirmation" : model.lastResult).font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        Button("Save simulated preset", systemImage: "square.and.arrow.down", action: model.save)
                            .disabled(model.busy || !model.dirty)
                        Button("Refresh from Mac", systemImage: "arrow.clockwise", action: model.refresh).disabled(model.busy)
                    } footer: {
                        Text("Gain is sent when you release the slider. Saving is separate. Simulation saves last until the Mac helper closes.")
                    }
                }
            }
            .navigationTitle("Patchbridge")
            .tint(.teal)
            .alert("Exact gain", isPresented: $precise) {
                TextField("0–10", text: $entry).keyboardType(.decimalPad)
                Button("Cancel", role: .cancel) {}
                Button("Apply") {
                    if let value = Double(entry.replacingOccurrences(of: ",", with: ".")), value.isFinite, (0...10).contains(value) {
                        model.gain = value; model.commitGain()
                    } else { entryError = true }
                }
            } message: { Text("Enter a value between 0 and 10.") }
            .alert("Enter a number from 0 to 10", isPresented: $entryError) { Button("OK", role: .cancel) {} }
        }
    }
}
