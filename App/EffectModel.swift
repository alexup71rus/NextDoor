import Combine
import Foundation

struct EffectParameters: Codable, Equatable, Sendable {
    var wall: Double
    var distance: Double
    var bass: Double
    var room: Double
    var echo: Double
    var boost: Double

    var clamped: EffectParameters {
        EffectParameters(
            wall: wall.unitClamped,
            distance: distance.unitClamped,
            bass: bass.unitClamped,
            room: room.unitClamped,
            echo: echo.unitClamped,
            boost: boost.unitClamped
        )
    }
}

struct EffectPreset: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var parameters: EffectParameters
}

@MainActor
final class EffectModel: ObservableObject {
    static let shared = EffectModel()
    static let lastPresetID = "last"

    static let defaultParameters = EffectParameters(
        wall: 0.30,
        distance: 0.10,
        bass: 0.20,
        room: 0.12,
        echo: 0.12,
        boost: 0.30
    )

    @Published private(set) var isEnabled = false
    @Published private(set) var isBusy = false
    @Published private(set) var status = "Готов"
    @Published private(set) var namedPresets: [EffectPreset]
    @Published private(set) var selectedPresetID = EffectModel.lastPresetID
    @Published private(set) var availableSources: [AudioSourceOption]
    @Published private(set) var selectedSourceID: String

    @Published var wall: Double {
        didSet { parametersDidChange() }
    }

    @Published var distance: Double {
        didSet { parametersDidChange() }
    }

    @Published var bass: Double {
        didSet { parametersDidChange() }
    }

    @Published var room: Double {
        didSet { parametersDidChange() }
    }

    @Published var echo: Double {
        didSet { parametersDidChange() }
    }

    @Published var boost: Double {
        didSet { parametersDidChange() }
    }

    private enum DefaultsKey {
        static let wall = "effect.v3.wall"
        static let distance = "effect.v3.distance"
        static let bass = "effect.v3.bass"
        static let room = "effect.v3.room"
        static let echo = "effect.v3.echo"
        static let boost = "effect.v3.boost"
        static let namedPresets = "effect.v3.namedPresets"
        static let sourceID = "effect.v4.sourceID"
        static let sourceName = "effect.v4.sourceName"
        static let sourceBundleIDs = "effect.v4.sourceBundleIDs"
    }

    private let defaults: UserDefaults
    private let audioController = AudioEffectController()
    private var isApplyingParameters = false
    private var lastParameters: EffectParameters

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedSourceID = defaults.string(forKey: DefaultsKey.sourceID)
            ?? AudioSourceOption.system.id
        let storedSourceName = defaults.string(forKey: DefaultsKey.sourceName)
            ?? "Выбранное приложение"
        let storedSourceBundleIDs = defaults.stringArray(forKey: DefaultsKey.sourceBundleIDs)
            ?? [storedSourceID]
        selectedSourceID = storedSourceID
        if storedSourceID == AudioSourceOption.system.id {
            availableSources = [.system]
        } else {
            availableSources = [
                .system,
                AudioSourceOption(
                    id: storedSourceID,
                    name: storedSourceName,
                    bundleID: storedSourceID,
                    processBundleIDs: storedSourceBundleIDs
                )
            ]
        }

        let fallback = Self.defaultParameters
        let storedLast = EffectParameters(
            wall: defaults.object(forKey: DefaultsKey.wall) as? Double ?? fallback.wall,
            distance: defaults.object(forKey: DefaultsKey.distance) as? Double ?? fallback.distance,
            bass: defaults.object(forKey: DefaultsKey.bass) as? Double ?? fallback.bass,
            room: defaults.object(forKey: DefaultsKey.room) as? Double ?? fallback.room,
            echo: defaults.object(forKey: DefaultsKey.echo) as? Double ?? fallback.echo,
            boost: defaults.object(forKey: DefaultsKey.boost) as? Double ?? fallback.boost
        ).clamped
        lastParameters = storedLast
        wall = storedLast.wall
        distance = storedLast.distance
        bass = storedLast.bass
        room = storedLast.room
        echo = storedLast.echo
        boost = storedLast.boost

        if let data = defaults.data(forKey: DefaultsKey.namedPresets),
           let decoded = try? JSONDecoder().decode([EffectPreset].self, from: data) {
            namedPresets = decoded
        } else {
            namedPresets = []
        }
    }

    var parameters: EffectParameters {
        EffectParameters(
            wall: wall,
            distance: distance,
            bass: bass,
            room: room,
            echo: echo,
            boost: boost
        ).clamped
    }

    var selectedSource: AudioSourceOption {
        availableSources.first(where: { $0.id == selectedSourceID }) ?? .system
    }

    func refreshSources() {
        do {
            let ownBundleID = Bundle.main.bundleIdentifier ?? "com.aleksandr.NextDoor"
            var sources = try CoreAudioUtilities.audioSources(excludingBundleID: ownBundleID)
            if selectedSourceID != AudioSourceOption.system.id,
               !sources.contains(where: { $0.id == selectedSourceID }) {
                sources.append(selectedSource)
            }
            availableSources = sources
            if let selected = sources.first(where: { $0.id == selectedSourceID }) {
                persistSource(selected)
            }
        } catch {
            if !isEnabled {
                status = error.localizedDescription
            }
        }
    }

    func selectSource(id: String) {
        guard id != selectedSourceID,
              let source = availableSources.first(where: { $0.id == id }) else {
            return
        }

        selectedSourceID = id
        persistSource(source)

        if isEnabled {
            restartForSourceChange()
        } else {
            status = source.bundleID == nil ? "Готов" : "Источник: \(source.name)"
        }
    }

    func toggle() async {
        await setEnabled(!isEnabled)
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isBusy else { return }
        guard enabled != isEnabled else { return }

        if enabled {
            enable()
        } else {
            disable()
        }
    }

    func applyPreset() {
        apply(
            Self.defaultParameters,
            selectedPresetID: Self.lastPresetID,
            updateLast: true
        )
    }

    func selectPreset(id: String) {
        if id == Self.lastPresetID {
            apply(lastParameters, selectedPresetID: Self.lastPresetID)
            return
        }

        guard let preset = namedPresets.first(where: { $0.id == id }) else { return }
        apply(preset.parameters, selectedPresetID: preset.id)
    }

    @discardableResult
    func savePreset(named rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name.localizedCaseInsensitiveCompare("Последний") != .orderedSame else {
            return false
        }

        let currentParameters = parameters
        let presetID: String

        if let index = namedPresets.firstIndex(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            namedPresets[index].name = name
            namedPresets[index].parameters = currentParameters
            presetID = namedPresets[index].id
        } else {
            let preset = EffectPreset(
                id: UUID().uuidString,
                name: name,
                parameters: currentParameters
            )
            namedPresets.append(preset)
            presetID = preset.id
        }

        persistNamedPresets()
        selectedPresetID = presetID
        return true
    }

    func shutdown() {
        audioController.stop()
        isEnabled = false
    }

    private func enable() {
        isBusy = true
        status = "Подключаю системный звук…"
        refreshSources()

        do {
            try audioController.start(parameters: parameters, source: selectedSource)
            isEnabled = true
            status = sourceStatus
        } catch {
            audioController.stop()
            isEnabled = false
            status = error.localizedDescription
        }

        isBusy = false
    }

    private func disable() {
        isBusy = true
        audioController.stop()
        isEnabled = false
        status = "Обычный звук"
        isBusy = false
    }

    private func restartForSourceChange() {
        isBusy = true
        audioController.stop()

        do {
            try audioController.start(parameters: parameters, source: selectedSource)
            isEnabled = true
            status = sourceStatus
        } catch {
            audioController.stop()
            isEnabled = false
            status = error.localizedDescription
        }

        isBusy = false
    }

    private var sourceStatus: String {
        if selectedSource.bundleID == nil {
            return "Весь звук играет за стеной"
        }
        return "За стеной: \(selectedSource.name)"
    }

    private func persistSource(_ source: AudioSourceOption) {
        defaults.set(source.id, forKey: DefaultsKey.sourceID)
        defaults.set(source.name, forKey: DefaultsKey.sourceName)
        defaults.set(source.processBundleIDs, forKey: DefaultsKey.sourceBundleIDs)
    }

    private func apply(
        _ newParameters: EffectParameters,
        selectedPresetID: String,
        updateLast: Bool = false
    ) {
        let newParameters = newParameters.clamped
        isApplyingParameters = true
        wall = newParameters.wall
        distance = newParameters.distance
        bass = newParameters.bass
        room = newParameters.room
        echo = newParameters.echo
        boost = newParameters.boost
        isApplyingParameters = false

        self.selectedPresetID = selectedPresetID
        if updateLast {
            lastParameters = newParameters
            persistLast(newParameters)
        }
        audioController.apply(newParameters)
    }

    private func parametersDidChange() {
        guard !isApplyingParameters else { return }

        let currentParameters = parameters
        selectedPresetID = Self.lastPresetID
        lastParameters = currentParameters
        persistLast(currentParameters)
        audioController.apply(currentParameters)
    }

    private func persistLast(_ parameters: EffectParameters) {
        defaults.set(parameters.wall, forKey: DefaultsKey.wall)
        defaults.set(parameters.distance, forKey: DefaultsKey.distance)
        defaults.set(parameters.bass, forKey: DefaultsKey.bass)
        defaults.set(parameters.room, forKey: DefaultsKey.room)
        defaults.set(parameters.echo, forKey: DefaultsKey.echo)
        defaults.set(parameters.boost, forKey: DefaultsKey.boost)
    }

    private func persistNamedPresets() {
        guard let data = try? JSONEncoder().encode(namedPresets) else { return }
        defaults.set(data, forKey: DefaultsKey.namedPresets)
    }
}

private extension Double {
    var unitClamped: Double {
        min(max(self, 0), 1)
    }
}
