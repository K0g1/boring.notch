import Defaults
import SwiftUI

struct HomeLayoutView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @Default(.homeLayouts) private var layouts
    @Default(.showOnAllDisplays) private var allDisplays
    @Default(.showCalendar) private var showCalendar
    @Default(.boringShelf) private var showShelf
    let albumArtNamespace: Namespace.ID

    private var panels: [HomePanel] {
        let key = HomeLayout.key(screenUUID: vm.screenUUID, allDisplays: allDisplays)
        return HomeLayout.panels(from: layouts[key] ?? layouts[HomeLayout.sharedKey])
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(panels) { panel in
                // Only selected panels are constructed, and the parent exists only while open.
                panelView(panel)
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
        }
        .onDisappear { vm.isHoveringCalendar = false }
    }

    @ViewBuilder
    private func panelView(_ panel: HomePanel) -> some View {
        switch panel {
        case .media:
            if panels.count == 2 {
                MusicPlayerView(albumArtNamespace: albumArtNamespace, compact: true)
            } else {
                MusicControlsView(compact: true)
            }
        case .agenda:
            if showCalendar {
                CalendarView()
                    .onHover { vm.isHoveringCalendar = $0 }
                    .onDisappear { vm.isHoveringCalendar = false }
            } else {
                unavailable(.agenda, message: "Enable Calendar in Settings to see your agenda.")
            }
        case .shelf:
            if showShelf {
                ShelfView(compact: true)
            } else {
                unavailable(.shelf, message: "Enable Shelf in Settings to add files and links.")
            }
        case .utilities:
            HomeUtilitiesPanel()
        }
    }

    private func unavailable(_ panel: HomePanel, message: String) -> some View {
        VStack(spacing: 8) {
            Label(panel.title, systemImage: panel.symbol).font(.headline)
            Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Settings…") { SettingsWindowController.shared.showWindow() }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HomeUtilitiesPanel: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var focus = FocusSessionStore.shared
    @Default(.showMirror) private var showMirror

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Utilities", systemImage: "slider.horizontal.3").font(.headline)
            Button { focus.showingControls = true } label: {
                if focus.session != nil {
                    FocusSessionReadout(compact: true)
                } else {
                    Label("Timer & Focus", systemImage: "timer")
                }
            }
            if showMirror {
                Button { vm.toggleCameraPreview() } label: {
                    Label(vm.isCameraExpanded ? "Close mirror" : "Mirror", systemImage: "web.camera")
                }
            }
            Button { SettingsWindowController.shared.showWindow() } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(6)
    }
}
