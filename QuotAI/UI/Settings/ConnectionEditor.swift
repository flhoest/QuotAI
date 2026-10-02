import SwiftUI
import AppKit

struct ConnectionEditor: View {
    @ObservedObject var store: UsageStore
    let connection: Connection

    @State private var name: String
    @State private var refreshInterval: TimeInterval
    @State private var primaryMetricID: String?
    @State private var budgetText: String
    @State private var manualPercentText: String
    @State private var manualRemaining: String
    @State private var manualHasReset: Bool
    @State private var manualReset: Date

    @State private var keyInput = ""
    @State private var replacingKey = false
    @State private var testState: TestState = .idle
    @State private var message: Message?
    @State private var bridgeSnippet: String?

    enum TestState: Equatable {
        case idle, running
        case success(String)
        case info(String)
        case failure(String)
    }

    struct Message: Equatable {
        let text: String
        let isError: Bool
    }

    init(store: UsageStore, connection: Connection) {
        self.store = store
        self.connection = connection
        _name = State(initialValue: connection.name)
        _refreshInterval = State(initialValue: connection.refreshInterval)
        _primaryMetricID = State(initialValue: connection.primaryMetricID)
        _budgetText = State(initialValue: connection.monthlyBudgetUSD.map { String($0) } ?? "")
        _manualPercentText = State(initialValue: connection.manual?.usedPercent.map { String($0) } ?? "")
        _manualRemaining = State(initialValue: connection.manual?.remainingText ?? "")
        _manualHasReset = State(initialValue: connection.manual?.resetsAt != nil)
        _manualReset = State(initialValue: connection.manual?.resetsAt ?? Date().addingTimeInterval(3600))
    }

    private var descriptor: ProviderDescriptor { connection.descriptor }
    private var current: Connection { store.connections.first(where: { $0.id == connection.id }) ?? connection }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    generalSection
                    accessSection
                    if descriptor.supportsBudget { budgetSection }
                    if descriptor.supportsManualEntry { manualSection }
                    displaySection
                    testSection
                    permissionsSection
                    aboutSection
                }
                .padding(20)
            }
            Divider()
            saveBar
        }
    }

    // MARK: - Sections

    private var generalSection: some View {
        SettingsCard(title: "Connection", icon: descriptor.symbol, badgeImage: connection.kind.brandLogo, tint: connection.kind.accentColor) {
            TextField("Name", text: $name)
            Toggle("Enabled", isOn: Binding(
                get: { current.isEnabled },
                set: { newValue in
                    var updated = current
                    updated.isEnabled = newValue
                    store.update(updated)
                }))
            LabeledContent("Provider", value: descriptor.displayName)
        }
    }

    @ViewBuilder
    private var accessSection: some View {
        SettingsCard(title: "Access method", icon: "key.fill", tint: .blue) {
            switch descriptor.authMethod {
            case .localBridge:
                bridgeControls
            case .localProcess(let description):
                localProcessControls(description: description)
            case .adminKey(let placeholder), .apiKey(let placeholder):
                keyControls(placeholder: placeholder)
            case .manualOnly:
                Text("No official API exists for this data, so no key is needed or accepted. You can optionally type values in below.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func localProcessControls(description: String) -> some View {
        let executable = CodexCLILocator.locate()
        return VStack(alignment: .leading, spacing: 10) {
            Text(description)
                .font(.callout).foregroundStyle(.secondary)
            Label(executable != nil ? "codex CLI found at \(executable!.path)" : "codex CLI not found",
                  systemImage: executable != nil ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(executable != nil ? Color.green : Color.secondary)
            if executable == nil {
                Text("Install the codex CLI, then run `codex login` in a terminal. QuotAI looks for it in your PATH and in common install locations (Homebrew, npm, ~/.local/bin, …).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("This protocol is not on a public documentation page — its shape was captured directly from your installed CLI and confirmed with a live call. It may change without notice on a codex update; QuotAI falls back to your manual entry below if so.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var bridgeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("QuotAI reads Claude Code's official statusLine data from a local file. It never asks for your Claude password, cookies or session token.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Label(ClaudeBridge.isScriptInstalled() ? "Helper script installed" : "Helper script not installed",
                      systemImage: ClaudeBridge.isScriptInstalled() ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(ClaudeBridge.isScriptInstalled() ? Color.green : Color.secondary)
                Spacer()
                Button(ClaudeBridge.isScriptInstalled() ? "Reinstall Script" : "Install Helper Script") { installBridge() }
            }
            if let snippet = bridgeSnippet ?? (ClaudeBridge.isScriptInstalled() ? ClaudeBridge.settingsSnippet(scriptURL: ClaudeBridge.defaultScriptURL) : nil) {
                Text("Add this to your Claude Code user settings (~/.claude/settings.json). QuotAI never edits that file.")
                    .font(.callout)
                Text(snippet)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
                HStack {
                    Button("Copy Snippet") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(snippet, forType: .string)
                    }
                    Button("Reveal Script in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([ClaudeBridge.defaultScriptURL])
                    }
                }
                Text("Already have a statusLine command? See the README to chain it with the helper script.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message { messageView(message) }
        }
    }

    private func keyControls(placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.hasSecret(for: connection.id) && !replacingKey {
                HStack {
                    Label("Key saved in the macOS Keychain", systemImage: "key.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Replace…") { replacingKey = true }
                    Button("Remove Key", role: .destructive) { removeKey() }
                }
            } else {
                SecureField(placeholder, text: $keyInput)
                    .textContentType(.password)
                HStack {
                    Button("Save Key in Keychain") { saveKey() }
                        .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if replacingKey { Button("Cancel") { replacingKey = false; keyInput = "" } }
                }
                Text("The key is stored only in your Keychain, never in preferences, files or logs. It is never shown again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message { messageView(message) }
        }
    }

    private var budgetSection: some View {
        SettingsCard(title: "Monthly budget (optional)", icon: "dollarsign.circle.fill", tint: .green) {
            TextField("Budget in USD, e.g. 200", text: $budgetText)
            Text("No provider API returns your spending cap. If you enter a budget here, QuotAI shows the month-to-date cost as a percentage of it, labelled \"Computed from your budget\".")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var manualSection: some View {
        SettingsCard(title: "Manual entry (optional)", icon: "pencil.circle.fill", tint: .purple) {
            TextField("Quota used (0–100 %)", text: $manualPercentText)
            TextField("Remaining, free text (e.g. \"about 2 h\")", text: $manualRemaining)
            Toggle("I know the next reset time", isOn: $manualHasReset)
            if manualHasReset {
                DatePicker("Next reset", selection: $manualReset)
            }
            HStack {
                Text("Values you type are always displayed as \"Entered by you\", never as official data.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") {
                    manualPercentText = ""; manualRemaining = ""; manualHasReset = false
                }
            }
        }
    }

    private var displaySection: some View {
        SettingsCard(title: "Display and refresh", icon: "slider.horizontal.3", tint: .teal) {
            Picker("Main value", selection: $primaryMetricID) {
                Text("Automatic").tag(String?.none)
                ForEach(current.metricChoices(from: store.runtime(for: connection.id).snapshot), id: \.id) { metric in
                    Text(metric.label).tag(Optional(metric.id))
                }
            }
            Picker("Refresh every", selection: $refreshInterval) {
                ForEach(intervalOptions, id: \.self) { seconds in
                    Text(Self.intervalLabel(seconds)).tag(seconds)
                }
            }
            Text("Minimum for this provider: \(Self.intervalLabel(descriptor.minimumRefreshInterval)), to respect its rate limits.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var testSection: some View {
        SettingsCard(title: "Test", icon: "bolt.fill", tint: .yellow) {
            HStack {
                Button("Test Connection") { runTest() }
                    .disabled(testState == .running)
                if testState == .running { ProgressView().controlSize(.small) }
            }
            switch testState {
            case .success(let text):
                Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            case .info(let text):
                Label(text, systemImage: "info.circle.fill").foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .failure(let text):
                Label(text, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle, .running:
                EmptyView()
            }
        }
    }

    private var permissionsSection: some View {
        SettingsCard(title: "Required permissions", icon: "checkmark.shield.fill", tint: .mint) {
            ForEach(descriptor.requiredPermissions, id: \.self) { permission in
                Label(permission, systemImage: "checkmark.shield")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var aboutSection: some View {
        SettingsCard(title: "What is officially available", icon: "doc.text.magnifyingglass", tint: .gray) {
            Text(descriptor.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
            ForEach(descriptor.capabilities) { capability in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon(for: capability.availability))
                        .foregroundStyle(color(for: capability.availability))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(capability.title).font(.callout)
                        Text(capability.detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text("Sources (method verified on \(descriptor.verifiedOn))").font(.caption.weight(.semibold)).padding(.top, 4)
            ForEach(descriptor.sources) { source in
                Link(source.title, destination: source.url).font(.caption)
            }
            Link(descriptor.accountLinkTitle, destination: descriptor.accountURL).font(.caption)
        }
    }

    /// A fixed bar at the bottom of the window, rather than one more card at the end of the
    /// scroll area — Save/Revert stay reachable without hunting for them after a long scroll.
    private var saveBar: some View {
        HStack {
            if let message, !descriptor.authMethod.needsSecret, descriptor.authMethod != .localBridge { messageView(message) }
            Spacer()
            Button("Revert") { revert() }.disabled(!isDirty)
            Button("Save Changes") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!isDirty)
        }
        .padding(14)
    }

    // MARK: - Actions

    private var intervalOptions: [TimeInterval] {
        let base: [TimeInterval] = [5, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        var options = base.filter { $0 >= descriptor.minimumRefreshInterval }
        if !options.contains(refreshInterval) { options.append(refreshInterval); options.sort() }
        return options
    }

    static func intervalLabel(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds)) seconds" : (seconds == 60 ? "1 minute" : "\(Int(seconds / 60)) minutes")
    }

    private func parsedBudget() -> (value: Double?, valid: Bool) {
        let trimmed = budgetText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if trimmed.isEmpty { return (nil, true) }
        if let value = Double(trimmed), value > 0, value.isFinite { return (value, true) }
        return (nil, false)
    }

    private func parsedManual() -> (value: ManualQuota?, valid: Bool) {
        let percentText = manualPercentText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        var percent: Double?
        if !percentText.isEmpty {
            guard let value = Double(percentText), (0...100).contains(value) else { return (nil, false) }
            percent = value
        }
        let remaining = manualRemaining.trimmingCharacters(in: .whitespacesAndNewlines)
        let quota = ManualQuota(usedPercent: percent,
                                remainingText: remaining.isEmpty ? nil : remaining,
                                resetsAt: manualHasReset ? manualReset : nil,
                                enteredAt: current.manual?.enteredAt ?? Date())
        return (quota.isEmpty ? nil : quota, true)
    }

    /// The connection as currently edited (enabled state always comes from the store).
    private func editedConnection() -> Connection? {
        var edited = current
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.name = trimmedName.isEmpty ? descriptor.shortName : trimmedName
        edited.refreshInterval = max(refreshInterval, descriptor.minimumRefreshInterval)
        edited.primaryMetricID = primaryMetricID
        if descriptor.supportsBudget {
            let budget = parsedBudget()
            guard budget.valid else { return nil }
            edited.monthlyBudgetUSD = budget.value
        }
        if descriptor.supportsManualEntry {
            let manual = parsedManual()
            guard manual.valid else { return nil }
            if let quota = manual.value, quota != current.manual {
                var stamped = quota
                stamped.enteredAt = Date()
                edited.manual = stamped
            } else if manual.value == nil {
                edited.manual = nil
            }
        }
        return edited
    }

    private var isDirty: Bool {
        guard let edited = editedConnection() else { return true }   // invalid input: allow Save to explain
        return edited != current
    }

    private func save() {
        guard let edited = editedConnection() else {
            message = Message(text: "Check the values: the budget must be a positive number and the quota a percentage between 0 and 100.", isError: true)
            return
        }
        message = nil
        store.update(edited)
    }

    private func revert() {
        name = current.name
        refreshInterval = current.refreshInterval
        primaryMetricID = current.primaryMetricID
        budgetText = current.monthlyBudgetUSD.map { String($0) } ?? ""
        manualPercentText = current.manual?.usedPercent.map { String($0) } ?? ""
        manualRemaining = current.manual?.remainingText ?? ""
        manualHasReset = current.manual?.resetsAt != nil
        manualReset = current.manual?.resetsAt ?? Date().addingTimeInterval(3600)
        message = nil
    }

    private func saveKey() {
        do {
            try store.setSecret(keyInput, for: connection.id)
            keyInput = ""
            replacingKey = false
            message = Message(text: "Key saved in the Keychain.", isError: false)
        } catch {
            message = Message(text: "The Keychain refused the request (status \((error as? SecretStoreError).map { "\($0)" } ?? "unknown")).", isError: true)
        }
    }

    private func removeKey() {
        do {
            try store.removeSecret(for: connection.id)
            message = Message(text: "Key removed from the Keychain.", isError: false)
        } catch {
            message = Message(text: "Could not remove the key from the Keychain.", isError: true)
        }
    }

    private func installBridge() {
        do {
            let url = try ClaudeBridge.installScript()
            bridgeSnippet = ClaudeBridge.settingsSnippet(scriptURL: url)
            message = Message(text: "Script installed at \(url.path).", isError: false)
            store.refresh(connection.id)
        } catch {
            message = Message(text: "Could not install the script: \(error.localizedDescription)", isError: true)
        }
    }

    private func runTest() {
        guard let edited = editedConnection() else {
            testState = .failure("Fix the invalid values first.")
            return
        }
        testState = .running
        let typedKey = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let result = await store.test(edited, secret: typedKey.isEmpty ? nil : typedKey)
            switch result {
            case .success(let snapshot):
                let summary = snapshot.metrics.prefix(3).map { "\($0.label): \(Formatters.value(of: $0))" }.joined(separator: " · ")
                let extra = snapshot.notes.first.map { " \($0)" } ?? ""
                testState = .success(snapshot.metrics.isEmpty ? "Connection OK." + extra : "Connection OK. \(summary)")
            case .failure(let error):
                testState = error.isInformational ? .info(error.userMessage) : .failure(error.userMessage)
            }
        }
    }

    // MARK: - Helpers

    private func messageView(_ message: Message) -> some View {
        Label(message.text, systemImage: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle")
            .font(.caption)
            .foregroundStyle(message.isError ? Color.red : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func icon(for availability: Availability) -> String {
        switch availability {
        case .official: return "checkmark.seal.fill"
        case .userProvided: return "hand.point.up.left.fill"
        case .unavailable: return "nosign"
        }
    }

    private func color(for availability: Availability) -> Color {
        switch availability {
        case .official: return .green
        case .userProvided: return .orange
        case .unavailable: return .secondary
        }
    }
}

extension Connection {
    /// Metrics that can be picked as the main value: those of the last snapshot, plus the current choice.
    func metricChoices(from snapshot: UsageSnapshot?) -> [(id: String, label: String)] {
        var choices = (snapshot?.metrics ?? []).map { (id: $0.id, label: $0.label) }
        if let selected = primaryMetricID, !choices.contains(where: { $0.id == selected }) {
            choices.append((id: selected, label: selected))
        }
        return choices
    }
}
