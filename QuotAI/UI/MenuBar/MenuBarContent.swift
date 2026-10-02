import SwiftUI

struct MenuBarContent: View {
    @ObservedObject var environment: AppEnvironment
    @ObservedObject private var store: UsageStore
    @ObservedObject private var settings: AppSettings

    init(environment: AppEnvironment) {
        self.environment = environment
        self.store = environment.store
        self.settings = environment.settings
    }

    var body: some View {
        let now = Date()
        let rows = store.enabledConnections.map { connection in
            RowModel.make(connection: connection,
                          runtime: store.runtime(for: connection.id),
                          showReset: true, showRemaining: false, now: now)
        }

        if rows.isEmpty {
            Text("No provider enabled")
        } else {
            ForEach(rows) { row in
                Button {
                    environment.showDetails(focus: row.id)
                } label: {
                    Text(summary(for: row))
                }
            }
        }

        Divider()

        Button(settings.panelVisible ? "Hide Panel" : "Show Panel") { environment.togglePanel() }
        Button("Refresh Now") { environment.refreshAll() }
            .keyboardShortcut("r")
        Button("Details…") { environment.showDetails() }
            .keyboardShortcut("d")
        Button("Settings…") { environment.showSettings() }
            .keyboardShortcut(",")

        Divider()

        Toggle("Keep on Top", isOn: $settings.keepOnTop)

        Divider()

        Button("Quit QuotAI") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func summary(for row: RowModel) -> String {
        var text = "\(row.title): \(row.valueText)"
        if let subtitle = row.subtitle { text += " — \(subtitle)" }
        return text
    }
}
