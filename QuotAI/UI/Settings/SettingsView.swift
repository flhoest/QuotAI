import SwiftUI

struct SettingsView: View {
    @ObservedObject var environment: AppEnvironment
    @State private var selection: SettingsSection = .general

    enum SettingsSection: String, CaseIterable, Identifiable {
        case general, connections
        var id: String { rawValue }
        var title: String { self == .general ? "General" : "Connections" }
        var icon: String { self == .general ? "gearshape.fill" : "link" }
        var tint: Color { self == .general ? .gray : Color("AccentIndigo") }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            Group {
                switch selection {
                case .general: GeneralSettingsView(environment: environment)
                case .connections: ConnectionsSettingsView(environment: environment)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 880, minHeight: 560)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                appIcon.frame(width: 30, height: 30)
                Text("QuotAI").font(.system(size: 15, weight: .bold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)

            List(selection: $selection) {
                ForEach(SettingsSection.allCases) { section in
                    Label {
                        Text(section.title).font(.system(size: 13, weight: .medium))
                    } icon: {
                        SettingsIconBadge(systemImage: section.icon, tint: section.tint, size: 22)
                    }
                    .tag(section)
                }
            }
            .listStyle(.sidebar)
            .scrollDisabled(true)

            Divider()
            VStack(alignment: .leading, spacing: 1) {
                Text("QuotAI \(Self.appVersion)").font(.caption).foregroundStyle(.secondary)
                Text("© 2026 Let's Talk About Tech").font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .frame(width: 200)
    }

    private var appIcon: some View {
        Group {
            if let icon = NSApplication.shared.applicationIconImage {
                Image(nsImage: icon).resizable()
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color("AccentIndigo"))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}

// MARK: - Connections

struct ConnectionsSettingsView: View {
    @ObservedObject var environment: AppEnvironment
    @ObservedObject private var store: UsageStore
    @State private var selection: UUID?
    @State private var confirmingDelete = false

    init(environment: AppEnvironment) {
        self.environment = environment
        self.store = environment.store
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 210, idealWidth: 230, maxWidth: 300)
            Group {
                if let id = selection, let connection = store.connections.first(where: { $0.id == id }) {
                    ConnectionEditor(store: store, connection: connection)
                        .id(id)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "link.badge.plus").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Select a connection, or add one with +")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 460)
        }
        .onAppear { if selection == nil { selection = store.connections.first?.id } }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.connections) { connection in
                    SidebarRow(connection: connection, runtime: store.runtime(for: connection.id))
                        .tag(connection.id)
                }
                .onMove { indices, destination in
                    store.move(fromOffsets: indices, toOffset: destination)
                }
            }
            .listStyle(.sidebar)
            Text("Drag to reorder — this is the order shown in the panel and in Details too.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.bottom, 6)
            Divider()
            HStack(spacing: 2) {
                Menu {
                    ForEach(ProviderKind.allCases) { kind in
                        Button(ProviderDescriptor.descriptor(for: kind).displayName) {
                            let connection = Connection(kind: kind, isEnabled: false)
                            store.add(connection)
                            selection = connection.id
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(SettingsIconButtonStyle())
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 26)
                .help("Add a connection")

                Button {
                    confirmingDelete = true
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(SettingsIconButtonStyle())
                .disabled(selection == nil)
                .help("Delete the selected connection and its saved key")
                Spacer()
            }
            .padding(8)
        }
        .confirmationDialog("Delete this connection?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Connection and Key", role: .destructive) {
                if let id = selection {
                    store.remove(id)
                    selection = store.connections.first?.id
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The key saved in the Keychain for this connection is deleted too.")
        }
    }
}

struct SidebarRow: View {
    let connection: Connection
    let runtime: ConnectionRuntime

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let brandLogo = connection.kind.brandLogo {
                    SettingsIconBadge(image: brandLogo, tint: connection.kind.accentColor, size: 22)
                } else {
                    SettingsIconBadge(systemImage: connection.descriptor.symbol, tint: connection.kind.accentColor, size: 22)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(connection.name).lineLimit(1).font(.system(size: 12.5, weight: .medium))
                Text(connection.isEnabled ? runtime.status.label : "Disabled")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
            StatusDot(tone: tone)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var tone: Tone {
        guard connection.isEnabled else { return .neutral }
        switch runtime.status {
        case .connected: return .ok
        case .stale: return .warning
        case .failed: return .error
        default: return .neutral
        }
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @ObservedObject var environment: AppEnvironment
    @ObservedObject private var settings: AppSettings
    @State private var loginError: String?

    init(environment: AppEnvironment) {
        self.environment = environment
        self.settings = environment.settings
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsCard(title: "Panel", icon: "macwindow", tint: Color("AccentIndigo")) {
                    Toggle("Keep the panel above other windows", isOn: $settings.keepOnTop)
                    Toggle("Show the panel when QuotAI starts", isOn: $settings.showPanelAtLaunch)
                    Toggle("Add a border to main window", isOn: $settings.showPanelBorder)
                    Toggle("Mini mode (name and % only)", isOn: $settings.miniMode)
                    HStack {
                        Text("Opacity").frame(width: 60, alignment: .leading)
                        Slider(value: $settings.panelOpacity, in: 0.4...1.0)
                        Text("\(Int(settings.panelOpacity * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                    Button("Reset Panel Position and Size") { environment.resetPanelPosition() }
                        .controlSize(.small)
                    Text("Drag the panel anywhere, on any screen. Its position and size are remembered.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                SettingsCard(title: "Status colors", icon: "paintpalette.fill", tint: .orange) {
                    HStack {
                        Text("Orange above").frame(width: 90, alignment: .leading)
                        Slider(value: Binding(
                            get: { settings.warningThreshold },
                            set: { settings.warningThreshold = min($0, settings.criticalThreshold - 1) }),
                            in: 1...99)
                        Text("\(Int(settings.warningThreshold))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                    HStack {
                        Text("Red above").frame(width: 90, alignment: .leading)
                        Slider(value: Binding(
                            get: { settings.criticalThreshold },
                            set: { settings.criticalThreshold = max($0, settings.warningThreshold + 1) }),
                            in: 1...99)
                        Text("\(Int(settings.criticalThreshold))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                    Text("Gauges stay green up to the orange threshold, turn orange up to the red threshold, and red above that.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                SettingsCard(title: "Shown in the compact view", icon: "list.bullet.rectangle", tint: .teal) {
                    Toggle("Time until the next reset", isOn: $settings.showResetTime)
                    Toggle("Remaining quota", isOn: $settings.showRemaining)
                    Toggle("Time of the last update", isOn: $settings.showLastUpdate)
                }

                SettingsCard(title: "System", icon: "power", tint: .gray) {
                    Toggle("Open QuotAI at login", isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { newValue in
                            do { try settings.setLaunchAtLogin(newValue) }
                            catch { loginError = "macOS could not change the login item: \(error.localizedDescription)" }
                        }))
                    if let loginError {
                        Text(loginError).font(.caption).foregroundStyle(.red)
                    }
                    Text("QuotAI runs from the menu bar and has no Dock icon.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                aboutCard
            }
            .padding(22)
        }
    }

    private var aboutCard: some View {
        HStack(spacing: 12) {
            appIcon.frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("QuotAI \(SettingsView.appVersion)").font(.system(size: 12.5, weight: .semibold))
                Text("Open-source menu-bar quota tracker for Claude, Codex & OpenAI")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }

    private var appIcon: some View {
        Group {
            if let icon = NSApplication.shared.applicationIconImage {
                Image(nsImage: icon).resizable()
            } else {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color("AccentIndigo"))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
