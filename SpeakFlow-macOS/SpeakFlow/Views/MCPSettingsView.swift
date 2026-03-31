import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "MCPSettingsView")

// MARK: - Data Models

/// Unified tool item — either a local MCP server or a Composio OAuth integration.
private struct ToolItem: Identifiable {
    let id: String
    let displayName: String
    let description: String
    let category: ToolCategory
    let icon: String
    let kind: ToolKind

    enum ToolKind {
        case composio                                  // OAuth via Composio
    }
}

private enum ToolCategory: String, CaseIterable {
    case communication = "Communication"
    case productivity = "Productivity"
    case devTools = "Dev Tools"
}

// MARK: - Curated Directory

private let toolDirectory: [ToolItem] = [
    // Communication
    ToolItem(id: "gmail", displayName: "Gmail", description: "Send & read emails", category: .communication, icon: "envelope.fill", kind: .composio),
    ToolItem(id: "slack", displayName: "Slack", description: "Send & read messages", category: .communication, icon: "bubble.left.fill", kind: .composio),
    ToolItem(id: "discord", displayName: "Discord", description: "Manage servers and messages", category: .communication, icon: "message.fill", kind: .composio),

    // Productivity
    ToolItem(id: "googlecalendar", displayName: "Google Calendar", description: "View & create events", category: .productivity, icon: "calendar", kind: .composio),
    ToolItem(id: "googledrive", displayName: "Google Drive", description: "Search & manage files", category: .productivity, icon: "externaldrive.fill", kind: .composio),
    ToolItem(id: "notion", displayName: "Notion", description: "Read & update pages", category: .productivity, icon: "doc.text", kind: .composio),
    ToolItem(id: "todoist", displayName: "Todoist", description: "Manage tasks & projects", category: .productivity, icon: "checklist", kind: .composio),
    ToolItem(id: "linear", displayName: "Linear", description: "Issues & project management", category: .productivity, icon: "list.bullet.rectangle", kind: .composio),

    // Dev Tools
    ToolItem(id: "github", displayName: "GitHub", description: "PRs, issues, repos", category: .devTools, icon: "chevron.left.forwardslash.chevron.right", kind: .composio),
    ToolItem(id: "gitlab", displayName: "GitLab", description: "Merge requests, issues, CI/CD", category: .devTools, icon: "chevron.left.forwardslash.chevron.right", kind: .composio),
    ToolItem(id: "sentry", displayName: "Sentry", description: "Error tracking & monitoring", category: .devTools, icon: "exclamationmark.triangle", kind: .composio),
]

// MARK: - Main View

struct MCPSettingsContent: View {
    @StateObject private var mcpManager = MCPServerManager.shared

    // Search
    @State private var searchText = ""

    // Add custom server
    @State private var showAddServer = false
    @State private var newServerName = ""
    @State private var newServerURL = ""
    @State private var newServerAPIKey = ""

    // Connection state
    @State private var connectingServer: String?
    @State private var composioConnections: Set<String> = Self.loadCachedComposioConnections()
    @State private var composioLoading: String?
    @State private var composioWaiting: Set<String> = []
    @State private var composioError: String?
    @State private var loadingConnections = false

    private static let composioCacheKey = "cachedComposioConnections"

    private static func loadCachedComposioConnections() -> Set<String> {
        let cached = UserDefaults.standard.stringArray(forKey: composioCacheKey) ?? []
        return Set(cached)
    }

    private static func saveCachedComposioConnections(_ connections: Set<String>) {
        UserDefaults.standard.set(Array(connections), forKey: composioCacheKey)
    }

    // Directory
    @State private var expandedCategories: Set<ToolCategory> = []

    // User servers only (hides built-in)
    private var allMyServers: [MCPServerConfig] {
        mcpManager.userServers
    }

    // Combined "connected" set: MCP connected + Composio active
    private var allConnected: Set<String> {
        mcpManager.connectedServers.union(composioConnections)
    }

    // Filtered directory
    private var filteredDirectory: [ToolItem] {
        if searchText.isEmpty { return [] }
        let query = searchText.lowercased()
        return toolDirectory.filter {
            $0.displayName.lowercased().contains(query) ||
            $0.description.lowercased().contains(query) ||
            $0.category.rawValue.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MCP Servers")
                .font(.system(size: 22, weight: .bold))

            Text("Connect tools to extend Agent capabilities — browser control, email, calendar, code repos, and more.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            // Search bar + Browse All
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    TextField("Search tools...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(7)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )

                Button {
                    openBrowseAll()
                } label: {
                    Label("Browse All", systemImage: "arrow.up.right.square")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }

            // Search results
            if !searchText.isEmpty {
                SectionCard(title: "Search Results", icon: "magnifyingglass") {
                    if filteredDirectory.isEmpty {
                        HStack {
                            Text("No results for \"\(searchText)\"")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Search online") {
                                openBrowseAll()
                            }
                            .font(.system(size: 11))
                            .buttonStyle(.plain)
                            .foregroundColor(.accentColor)
                        }
                    } else {
                        ForEach(filteredDirectory) { item in
                            directoryRow(item)
                            if item.id != filteredDirectory.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }

            // My Connections (scrollable list — user servers only)
            SectionCard(title: "My Connections", icon: "puzzlepiece.extension") {
                if allMyServers.isEmpty && composioConnections.isEmpty && composioWaiting.isEmpty {
                    Text("No tools connected yet. Add from the directory below.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                } else {
                    let composioActiveItems = composioConnections.sorted().filter { !mcpManager.servers.keys.contains($0) }
                    let waitingOnly = composioWaiting.subtracting(composioConnections).sorted().filter { !mcpManager.servers.keys.contains($0) }
                    let totalRows = allMyServers.count + composioActiveItems.count + waitingOnly.count

                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 0) {
                            // MCP servers (user only)
                            ForEach(Array(allMyServers.enumerated()), id: \.element.id) { index, server in
                                myServerRow(server)
                                if index < allMyServers.count - 1 || !composioActiveItems.isEmpty || !waitingOnly.isEmpty {
                                    Divider().padding(.leading, 28)
                                }
                            }

                            // Composio connected items
                            ForEach(Array(composioActiveItems.enumerated()), id: \.element) { index, appName in
                                composioConnectedRow(appName)
                                if index < composioActiveItems.count - 1 || !waitingOnly.isEmpty {
                                    Divider().padding(.leading, 28)
                                }
                            }

                            // Composio waiting items (opened browser, not yet confirmed)
                            ForEach(Array(waitingOnly.enumerated()), id: \.element) { index, appName in
                                composioWaitingRow(appName)
                                if index < waitingOnly.count - 1 {
                                    Divider().padding(.leading, 28)
                                }
                            }
                        }
                        .padding(1)
                    }
                    .frame(height: min(CGFloat(totalRows) * 52, 280))
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                }

                HStack {
                    // Add custom server
                    if showAddServer {
                        VStack(alignment: .leading, spacing: 8) {
                            Divider()
                            TextField("Name", text: $newServerName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                            TextField("URL (e.g. https://mcp.example.com/sse)", text: $newServerURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                            TextField("API Key (optional)", text: $newServerAPIKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))

                            HStack {
                                Button("Cancel") {
                                    showAddServer = false
                                    resetForm()
                                }
                                .font(.system(size: 11))

                                Button("Add") {
                                    addCustomServer()
                                }
                                .font(.system(size: 11))
                                .disabled(newServerName.isEmpty || newServerURL.isEmpty)
                            }
                        }
                    } else {
                        Button {
                            showAddServer = true
                        } label: {
                            Label("Add Custom Server", systemImage: "plus.circle")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)

                        Spacer()

                        if loadingConnections {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Button {
                            loadComposioConnections()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                    }
                }
                .padding(.top, 4)

                if let error = composioError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
            }

            // Discover (categorized directory — Composio only)
            SectionCard(title: "Discover", icon: "square.grid.2x2") {
                ForEach(ToolCategory.allCases, id: \.self) { category in
                    let items = toolDirectory.filter { $0.category == category }
                    let isExpanded = expandedCategories.contains(category)

                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if isExpanded {
                                    expandedCategories.remove(category)
                                } else {
                                    expandedCategories.insert(category)
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.secondary)
                                    .frame(width: 12)

                                Text(category.rawValue)
                                    .font(.system(size: 12, weight: .medium))

                                Text("\(items.count)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color(nsColor: .separatorColor).opacity(0.3))
                                    .cornerRadius(4)

                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 6)

                        if isExpanded {
                            VStack(spacing: 0) {
                                ForEach(items) { item in
                                    directoryRow(item)
                                        .padding(.leading, 16)
                                    if item.id != items.last?.id {
                                        Divider().padding(.leading, 16)
                                    }
                                }
                            }
                        }
                    }

                    if category != ToolCategory.allCases.last {
                        Divider()
                    }
                }
            }

            // Config file
            HStack {
                Text("Config: ~/.speakflow/mcp.json")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Button("Open in Finder") {
                    let url = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent(".speakflow/mcp.json")
                    NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
                }
                .font(.system(size: 10))
            }
        }
        .onAppear {
            logger.info("MCPSettingsView onAppear, token present: \(KeychainService.shared.accessToken != nil)")
            loadComposioConnections()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Re-sync after returning from browser OAuth or re-activating the app.
            loadComposioConnections()
        }
    }

    // MARK: - Row Views

    /// Row in My Connections list (MCP server — user only)
    @ViewBuilder
    private func myServerRow(_ server: MCPServerConfig) -> some View {
        let isActive = mcpManager.connectedServers.contains(server.name)
        let errorMsg = mcpManager.connectionErrors[server.name]
        let isLegacyStdio: Bool = {
            if case .stdio = server.transport { return true }
            return false
        }()

        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(displayName(for: server.name))
                        .font(.system(size: 12, weight: .medium))
                    if isLegacyStdio {
                        Text("(legacy)")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                    }
                    if isActive {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                    } else if errorMsg != nil {
                        Circle()
                            .fill(.red)
                            .frame(width: 6, height: 6)
                    }
                }
                // Show URL for SSE, command for legacy stdio
                if let url = server.urlString {
                    Text(url)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else if let command = server.command, let args = server.args {
                    Text("\(command) \(args.joined(separator: " "))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                if let errorMsg {
                    Text(errorMsg)
                        .font(.system(size: 9))
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
            }

            Spacer()

            if connectingServer == server.name {
                ProgressView()
                    .controlSize(.small)
            }

            // Retry button when disconnected with error
            if errorMsg != nil && connectingServer != server.name {
                Button {
                    connectServer(name: server.name)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }

            // Delete button
            Button {
                mcpManager.removeServer(name: server.name)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)

            Toggle("", isOn: Binding(
                get: { server.enabled },
                set: { newValue in
                    if newValue {
                        mcpManager.toggleServer(name: server.name, enabled: true)
                        connectServer(name: server.name)
                    } else {
                        mcpManager.toggleServer(name: server.name, enabled: false)
                    }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(isActive ? .green : (server.enabled ? .orange : .gray))
        }
        .padding(.vertical, 6)
    }

    /// Row in My Connections list (Composio connected / active)
    @ViewBuilder
    private func composioConnectedRow(_ appName: String) -> some View {
        let item = toolDirectory.first(where: { $0.id == appName })
        HStack(spacing: 8) {
            if let icon = item?.icon {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(.accentColor)
                    .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName(for: appName))
                    .font(.system(size: 12, weight: .medium))
                Text("Connected via Composio")
                    .font(.system(size: 9))
                    .foregroundColor(.green)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { true },
                set: { _ in disconnectComposio(appName: appName) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(.green)
        }
        .padding(.vertical, 6)
    }

    /// Row in My Connections list (Composio waiting for OAuth)
    @ViewBuilder
    private func composioWaitingRow(_ appName: String) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName(for: appName))
                    .font(.system(size: 12, weight: .medium))
                Text("Complete in browser")
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { true },
                set: { _ in composioWaiting.remove(appName) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(.orange)
        }
        .padding(.vertical, 6)
    }

    /// Row in Discover directory — just a toggle
    @ViewBuilder
    private func directoryRow(_ item: ToolItem) -> some View {
        let isOn = isToolActive(item)
        let isLoading = composioLoading == item.id
        let isWaiting = composioWaiting.contains(item.id)

        HStack(spacing: 8) {
            Image(systemName: item.icon)
                .font(.system(size: 12))
                .foregroundColor(.accentColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .font(.system(size: 12, weight: .medium))
                Text(item.description)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Toggle("", isOn: Binding(
                    get: { isOn || isWaiting },
                    set: { newValue in
                        if newValue {
                            addToolItem(item)
                        } else {
                            removeToolItem(item)
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(isWaiting && !isOn ? .orange : .green)
            }
        }
        .padding(.vertical, 4)
    }

    private func isToolActive(_ item: ToolItem) -> Bool {
        allConnected.contains(item.id) || mcpManager.servers[item.id] != nil
    }

    // MARK: - Actions

    private func addToolItem(_ item: ToolItem) {
        connectComposio(appName: item.id)
    }

    private func removeToolItem(_ item: ToolItem) {
        disconnectComposio(appName: item.id)
    }

    private func addCustomServer() {
        let name = newServerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = newServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = newServerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        var headers: [String: String]? = nil
        if !apiKey.isEmpty {
            headers = ["Authorization": "Bearer \(apiKey)"]
        }

        let config = MCPServerConfig(
            name: name,
            transport: .sse(url: url, headers: headers),
            enabled: true
        )
        mcpManager.addServer(config)
        connectServer(name: name)
        showAddServer = false
        resetForm()
    }

    private func connectServer(name: String) {
        connectingServer = name
        Task {
            do {
                try await MCPServerManager.shared.connectServer(name: name)
            } catch {
                logger.error("Failed to connect \(name): \(error.localizedDescription)")
            }
            await MainActor.run {
                connectingServer = nil
            }
        }
    }

    private func resetForm() {
        newServerName = ""
        newServerURL = ""
        newServerAPIKey = ""
    }

    // MARK: - Composio

    private func loadComposioConnections() {
        logger.info("loadComposioConnections called, current cache: \(composioConnections.count)")
        loadingConnections = true
        composioError = nil
        Task {
            do {
                let connections = try await ComposioService.shared.getConnections()
                logger.info("Composio API returned \(connections.count) connections")
                let activeApps = Set(
                    connections
                        .filter(\.isActive)
                        .map { normalizedToolID(forComposioApp: $0.appName) }
                        .filter { !$0.isEmpty }
                )
                let pendingApps = Set(
                    connections
                        .filter(\.isPending)
                        .map { normalizedToolID(forComposioApp: $0.appName) }
                        .filter { !$0.isEmpty }
                )
                await MainActor.run {
                    let previousCount = composioConnections.count
                    if activeApps.isEmpty && !composioConnections.isEmpty {
                        // API returned empty but we have cached connections — likely a backend/timing issue.
                        // Keep the cache to avoid silent data loss.
                        logger.warning("Composio API returned 0 active connections but cache has \(previousCount) — keeping cache")
                        loadingConnections = false
                        return
                    }
                    logger.info("Composio connections updated: \(previousCount) → \(activeApps.count)")
                    composioConnections = activeApps
                    Self.saveCachedComposioConnections(activeApps)
                    loadingConnections = false
                    // Keep local waiting state, but clear any app that is now active.
                    composioWaiting = composioWaiting.union(pendingApps).subtracting(activeApps)
                }
            } catch {
                logger.error("loadComposioConnections failed: \(error.localizedDescription)")
                await MainActor.run {
                    loadingConnections = false
                    // Don't clear cached connections on error — keep showing last known state
                    if composioConnections.isEmpty {
                        composioError = error.localizedDescription
                    }
                }
            }
        }
    }

    private func connectComposio(appName: String) {
        composioLoading = appName
        composioError = nil
        Task {
            do {
                let redirectUrl = try await ComposioService.shared.connect(appName: appName)
                await MainActor.run {
                    composioLoading = nil
                    if redirectUrl == "already_connected" {
                        // Already connected — just refresh
                        composioConnections.insert(appName)
                        composioWaiting.remove(appName)
                        Self.saveCachedComposioConnections(composioConnections)
                    } else {
                        // Need OAuth — open browser
                        composioWaiting.insert(appName)
                        if let url = URL(string: redirectUrl) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                refreshComposioConnectionsSoon()
            } catch {
                await MainActor.run {
                    composioLoading = nil
                    composioError = error.localizedDescription
                }
            }
        }
    }

    private func disconnectComposio(appName: String) {
        composioError = nil
        Task {
            do {
                // Find the connection ID
                let connections = try await ComposioService.shared.getConnections()
                if let conn = connections.first(where: { normalizedToolID(forComposioApp: $0.appName) == appName.lowercased() }) {
                    try await ComposioService.shared.disconnect(connectionId: conn.id)
                }
                await MainActor.run {
                    composioConnections.remove(appName)
                    composioWaiting.remove(appName)
                    Self.saveCachedComposioConnections(composioConnections)
                }
            } catch {
                await MainActor.run {
                    composioError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Browse All

    private func openBrowseAll() {
        Task {
            let token = (try? await AuthService.shared.getValidToken()) ?? ""
            let base = Constants.apiBaseURL.replacingOccurrences(of: "/api/v1", with: "")
            let url = URL(string: "\(base)/integrations#token=\(token)")!
            _ = await MainActor.run {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Helpers

    private func displayName(for id: String) -> String {
        toolDirectory.first(where: { $0.id == id })?.displayName ?? id
    }

    private func normalizedToolID(forComposioApp appName: String) -> String {
        let raw = appName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)

        if raw.isEmpty { return "" }
        if raw == "googlemail" || raw.contains("gmail") { return "gmail" }
        if raw == "gdrive" || raw.contains("googledrive") { return "googledrive" }
        if raw == "gcal" || raw.contains("googlecalendar") { return "googlecalendar" }
        return raw
    }

    private func refreshComposioConnectionsSoon() {
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                loadComposioConnections()
            }
        }
    }
}

// MARK: - Section Card

private struct SectionCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                content()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
    }
}
