import AppIntents
import SwiftUI
import WidgetKit

struct ToggleNextDoorControl: ControlWidget {
    static let kind = "com.aleksandr.NextDoor.ToggleEffect"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: ToggleNextDoorIntent()) {
                Label("За стеной", systemImage: "waveform")
            }
        }
        .displayName("За стеной")
        .description("Включает или выключает приглушённый звук.")
    }
}

struct ToggleNextDoorIntent: AppIntent {
    static let title: LocalizedStringResource = "Переключить звук за стеной"
    static let description = IntentDescription("Включает или выключает эффект во всём системном звуке.")

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "nextdoor://toggle")!))
    }
}

@main
struct NextDoorControlBundle: WidgetBundle {
    var body: some Widget {
        ToggleNextDoorControl()
    }
}
