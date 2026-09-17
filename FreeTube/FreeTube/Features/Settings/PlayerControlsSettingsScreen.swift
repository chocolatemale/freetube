import SwiftUI

@available(iOS 17.0, *)
struct PlayerControlsSettingsScreen: View {
    @Bindable var model: SettingsViewModel

    var body: some View {
        List {
            Section {
                ForEach(model.playerTopControls.filter { $0 != .fullscreen }) { control in
                    HStack(spacing: 12) {
                        Image(systemName: control.systemImage)
                            .frame(width: 24)
                            .foregroundStyle(.secondary)
                        Toggle(
                            control.displayName,
                            isOn: Binding(
                                get: { model.isPlayerTopControlVisible(control) },
                                set: { model.setPlayerTopControlVisible($0, control: control) }
                            )
                        )
                    }
                }
                .onMove { source, destination in
                    var controls = model.playerTopControls.filter { $0 != .fullscreen }
                    controls.move(fromOffsets: source, toOffset: destination)
                    model.playerTopControls = controls
                }
            } footer: {
                Text("Drag controls to change their order. Hidden controls remain available here and can be restored at any time.")
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Player controls")
        .navigationBarTitleDisplayMode(.inline)
    }
}
