import AppKit
import SwiftUI

struct EffectPanel: View {
    @ObservedObject var model: EffectModel
    @State private var isNamingPreset = false
    @State private var presetName = ""

    var body: some View {
        VStack(spacing: 16) {
            header

            sourceControls

            presetControls

            Divider()

            VStack(spacing: 14) {
                ParameterSlider(
                    title: "Стена",
                    detail: wallDetail,
                    systemImage: "square.split.diagonal.2x2",
                    value: $model.wall
                )

                ParameterSlider(
                    title: "Расстояние",
                    detail: distanceDetail,
                    systemImage: "arrow.left.and.right",
                    value: $model.distance
                )

                ParameterSlider(
                    title: "Бас",
                    detail: bassDetail,
                    systemImage: "speaker.wave.3",
                    value: $model.bass
                )

                ParameterSlider(
                    title: "Комната",
                    detail: roomDetail,
                    systemImage: "wave.3.right",
                    value: $model.room
                )

                ParameterSlider(
                    title: "Эхо",
                    detail: echoDetail,
                    systemImage: "repeat",
                    value: $model.echo
                )

                ParameterSlider(
                    title: "Усиление",
                    detail: boostDetail,
                    systemImage: "speaker.plus",
                    value: $model.boost
                )
            }

            HStack(spacing: 10) {
                Button("По умолчанию") {
                    model.applyPreset()
                }
                .buttonStyle(.borderless)

                Spacer()

                Button("Закрыть") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 360)
        .onAppear {
            model.refreshSources()
        }
    }

    private var sourceControls: some View {
        HStack(spacing: 8) {
            Text("Источник")
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Menu {
                ForEach(model.availableSources) { source in
                    Button {
                        model.selectSource(id: source.id)
                    } label: {
                        if source.id == model.selectedSourceID {
                            Label(source.name, systemImage: "checkmark")
                        } else {
                            Text(source.name)
                        }
                    }
                }

                Divider()

                Button("Обновить список", systemImage: "arrow.clockwise") {
                    model.refreshSources()
                }
            } label: {
                HStack(spacing: 6) {
                    Text(model.selectedSource.name)
                        .lineLimit(1)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 28)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .disabled(model.isBusy)
    }

    private var presetControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    Button("Последний") {
                        model.selectPreset(id: EffectModel.lastPresetID)
                    }
                    ForEach(model.namedPresets) { preset in
                        Button(preset.name) {
                            model.selectPreset(id: preset.id)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(selectedPresetName)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 9)
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)

                Button {
                    presetName = ""
                    isNamingPreset = true
                } label: {
                    Label("Сохранить", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .help("Сохранить текущие настройки")
            }

            if isNamingPreset {
                HStack(spacing: 8) {
                    TextField("Название пресета", text: $presetName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(savePreset)

                    Button("Сохранить", action: savePreset)
                        .disabled(!canSavePreset)

                    Button {
                        isNamingPreset = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Отмена")
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(model.isEnabled ? Color.accentColor.gradient : Color.secondary.opacity(0.16).gradient)
                    .frame(width: 46, height: 46)

                Image(systemName: model.isEnabled ? "waveform" : "waveform.slash")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(model.isEnabled ? .white : .secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("За стеной")
                    .font(.headline)

                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: Binding(
                get: { model.isEnabled },
                set: { isEnabled in
                    Task { await model.setEnabled(isEnabled) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(model.isBusy)
        }
    }

    private var wallDetail: String {
        let percent = Int((model.wall * 100).rounded())
        guard percent > 0 else { return "0%" }
        let cutoff = AudioEffectController.cutoffFrequency(for: model.wall)
        return "\(percent)% · \(Int(cutoff.rounded())) Гц"
    }

    private var distanceDetail: String {
        let decibels = Int((model.distance * 10).rounded())
        return decibels == 0 ? "0 дБ" : "−\(decibels) дБ"
    }

    private var bassDetail: String {
        "+\(Int((model.bass * 12).rounded())) дБ"
    }

    private var roomDetail: String {
        "\(Int((model.room * 60).rounded()))% отражений"
    }

    private var echoDetail: String {
        "\(Int((model.echo * 50).rounded()))% повтора"
    }

    private var boostDetail: String {
        "+\(Int((model.boost * 10).rounded())) дБ"
    }

    private var canSavePreset: Bool {
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty
            && name.localizedCaseInsensitiveCompare("Последний") != .orderedSame
    }

    private var selectedPresetName: String {
        guard model.selectedPresetID != EffectModel.lastPresetID else {
            return "Последний"
        }

        return model.namedPresets.first(where: { $0.id == model.selectedPresetID })?.name
            ?? "Последний"
    }

    private func savePreset() {
        guard canSavePreset, model.savePreset(named: presetName) else { return }
        presetName = ""
        isNamingPreset = false
    }
}

private struct ParameterSlider: View {
    let title: String
    let detail: String
    let systemImage: String
    @Binding var value: Double

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)

                Text(title)
                    .font(.subheadline.weight(.medium))

                Spacer()

                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(value: $value, in: 0...1)
        }
    }
}
