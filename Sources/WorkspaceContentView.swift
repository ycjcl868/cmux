import SwiftUI
import Foundation
import AppKit
import Bonsplit

enum TmuxOverlayExperimentTarget: String, CaseIterable, Codable, Sendable {
    case surface
    case bonsplitPane
    case tmuxActivePane

    var usesWorkspacePaneOverlay: Bool {
        self == .bonsplitPane
    }

    var usesTmuxActivePaneOverlay: Bool {
        self == .tmuxActivePane
    }
}

struct TmuxOverlayExperimentSettings {
    static let enabledKey = "tmuxOverlayExperimentEnabled"
    static let targetKey = "tmuxOverlayExperimentTarget"
    static let defaultEnabled = false
    static let defaultTarget: TmuxOverlayExperimentTarget = .surface

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    static func target(defaults: UserDefaults = .standard) -> TmuxOverlayExperimentTarget {
        target(
            enabled: isEnabled(defaults: defaults),
            rawValue: defaults.string(forKey: targetKey)
        )
    }

    static func target(enabled: Bool, rawValue: String?) -> TmuxOverlayExperimentTarget {
        guard enabled else { return .surface }
        guard let rawValue,
              let target = TmuxOverlayExperimentTarget(rawValue: rawValue) else {
            return defaultTarget
        }
        return target
    }
}

private enum WorkspaceTitlebarInteractionMetrics {
    // Keep in sync with the minimal-mode titlebar strip so the monitor only
    // covers titlebar chrome.
    static let minimalModeTopStripHeight: CGFloat = MinimalModeChromeMetrics.titlebarHeight
}

struct TmuxPaneLayoutPane: Codable, Equatable, Sendable {
    let paneId: String
    let left: Int
    let top: Int
    let width: Int
    let height: Int
    let isActive: Bool
}

struct TmuxPaneLayoutReport: Codable, Equatable, Sendable {
    let panes: [TmuxPaneLayoutPane]

    var activePane: TmuxPaneLayoutPane? {
        panes.first(where: \.isActive) ?? panes.first
    }
}

func tmuxActivePaneOverlayRect(
    surfaceFrame: CGRect,
    cellSize: CGSize,
    pane: TmuxPaneLayoutPane
) -> CGRect? {
    guard cellSize.width > 0,
          cellSize.height > 0,
          pane.width > 0,
          pane.height > 0 else {
        return nil
    }

    return CGRect(
        x: surfaceFrame.origin.x + (CGFloat(pane.left) * cellSize.width),
        y: surfaceFrame.origin.y + (CGFloat(pane.top) * cellSize.height),
        width: CGFloat(pane.width) * cellSize.width,
        height: CGFloat(pane.height) * cellSize.height
    )
}

private extension PixelRect {
    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct TmuxWorkspacePaneOverlayRenderState: Equatable {
    let workspaceId: UUID
    let unreadRects: [CGRect]
    let flashRect: CGRect?
    let flashToken: UInt64
    let flashReason: WorkspaceAttentionFlashReason?
}

@MainActor
final class TmuxWorkspacePaneOverlayModel: ObservableObject {
    @Published private(set) var unreadRects: [CGRect] = []
    @Published private(set) var flashRect: CGRect?
    @Published private(set) var flashStartedAt: Date?
    @Published private(set) var flashReason: WorkspaceAttentionFlashReason?

    private var currentWorkspaceId: UUID?
    private var lastFlashTokenByWorkspaceId: [UUID: UInt64] = [:]

    func apply(
        _ state: TmuxWorkspacePaneOverlayRenderState,
        now: () -> Date = Date.init
    ) {
        unreadRects = state.unreadRects
        flashRect = state.flashRect
        flashReason = state.flashReason

        let didChangeWorkspace = currentWorkspaceId != state.workspaceId
        let previousFlashToken = lastFlashTokenByWorkspaceId[state.workspaceId]
        let didChangeFlashToken = previousFlashToken.map { state.flashToken != $0 } ?? (state.flashToken > 0)
        if didChangeFlashToken,
           state.flashRect != nil {
            flashStartedAt = now()
        } else if didChangeWorkspace {
            flashStartedAt = nil
        }
        currentWorkspaceId = state.workspaceId
        if (previousFlashToken == nil && state.flashToken == 0) ||
            !didChangeFlashToken ||
            state.flashRect != nil {
            lastFlashTokenByWorkspaceId[state.workspaceId] = state.flashToken
        }
    }

    func clear() {
        unreadRects = []
        flashRect = nil
        flashStartedAt = nil
        flashReason = nil
        currentWorkspaceId = nil
        lastFlashTokenByWorkspaceId = [:]
    }
}

/// View that renders a Workspace's content using BonsplitView
struct WorkspaceContentView: View {
    private struct DeferredThemeRefresh {
        let reason: String
        let backgroundOverride: NSColor?
        let backgroundEventId: UInt64?
        let backgroundSource: String?
        let notificationPayloadHex: String?
        let forceInitialApply: Bool
    }

    @ObservedObject var workspace: Workspace
    let isWorkspaceVisible: Bool
    let isWorkspaceInputActive: Bool
    let isFullScreen: Bool
    let workspacePortalPriority: Int
    let onThemeRefreshRequest: ((
        _ reason: String,
        _ backgroundEventId: UInt64?,
        _ backgroundSource: String?,
        _ notificationPayloadHex: String?
    ) -> Void)?
    @State private var config = WorkspaceContentView.resolveGhosttyAppearanceConfig(reason: "stateInit")
    @State private var lastAppliedUsesHostLayerBackground = GhosttyApp.shared.usesHostLayerBackground
    @State private var deferredThemeRefresh: DeferredThemeRefresh?
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var notificationStore: TerminalNotificationStore

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    static func panelVisibleInUI(
        isWorkspaceVisible: Bool,
        isSelectedInPane: Bool,
        isFocused: Bool
    ) -> Bool {
        guard isWorkspaceVisible else { return false }
        // During pane/tab reparenting, Bonsplit can transiently report selected=false
        // for the currently focused panel. Keep focused content visible to avoid blank frames.
        return isSelectedInPane || isFocused
    }

    var body: some View {
        let showLayoutTabStrip = workspace.layoutTabs.count > 1
        let isWorkspaceManuallyUnread = notificationStore.hasManualUnread(forTabId: workspace.id)
        let workspaceManualUnreadPanelId = workspace.representativePanelIdForWorkspaceManualUnread()

        VStack(spacing: 0) {
            if showLayoutTabStrip {
                LayoutTabStripView(workspace: workspace)
            }

            ZStack {
                ForEach(workspace.layoutTabs) { layoutTab in
                    let isSelected = layoutTab.id == workspace.selectedLayoutTabId
                    LayoutTabBonsplitView(
                        workspace: workspace,
                        layoutTab: layoutTab,
                        isSelected: isSelected,
                        isWorkspaceVisible: isWorkspaceVisible,
                        isWorkspaceInputActive: isWorkspaceInputActive && isSelected,
                        workspacePortalPriority: workspacePortalPriority,
                        config: config,
                        notificationStore: notificationStore
                    )
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            updateAgentHibernationPresentationVisibility()
            syncBonsplitNotificationBadges()
            refreshGhosttyAppearanceConfig(reason: "onAppear")
        }
        .onChange(of: isWorkspaceVisible) { _, isVisible in
            updateAgentHibernationPresentationVisibility()
            guard isVisible else { return }
            flushDeferredThemeRefreshIfNeeded()
        }
        .onChange(of: isWorkspaceInputActive) { _, _ in
            updateAgentHibernationPresentationVisibility()
        }
        .onDisappear {
            workspace.setAgentHibernationAutoResumePresentationVisible(false)
        }
        .onChange(of: notificationStore.notifications) { _, _ in
            syncBonsplitNotificationBadges()
        }
        .onChange(of: workspace.manualUnreadPanelIds) { _, _ in
            syncBonsplitNotificationBadges()
        }
        .onChange(of: workspace.restoredUnreadPanelIds) { _, _ in
            syncBonsplitNotificationBadges()
        }
        .onChange(of: isWorkspaceManuallyUnread) { _, _ in
            syncBonsplitNotificationBadges()
        }
        .onChange(of: workspaceManualUnreadPanelId) { _, _ in
            syncBonsplitNotificationBadges()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigDidReload)) { _ in
            refreshGhosttyAppearanceConfig(reason: "ghosttyConfigDidReload")
        }
        .onChange(of: colorScheme) { oldValue, newValue in
            refreshGhosttyAppearanceConfig(reason: "colorSchemeChanged:\(oldValue)->\(newValue)")
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)) { notification in
            let payloadHex = (notification.userInfo?[GhosttyNotificationKey.backgroundColor] as? NSColor)?.hexString() ?? "nil"
            let foregroundHex = (notification.userInfo?[GhosttyNotificationKey.foregroundColor] as? NSColor)?.hexString() ?? "nil"
            let eventId = (notification.userInfo?[GhosttyNotificationKey.backgroundEventId] as? NSNumber)?.uint64Value
            let source = (notification.userInfo?[GhosttyNotificationKey.backgroundSource] as? String) ?? "nil"
            logTheme(
                "theme notification workspace=\(workspace.id.uuidString) event=\(eventId.map(String.init) ?? "nil") source=\(source) payload=\(payloadHex) payloadFg=\(foregroundHex) appBg=\(GhosttyApp.shared.defaultBackgroundColor.hexString()) appFg=\(GhosttyApp.shared.defaultForegroundColor.hexString()) appOpacity=\(String(format: "%.3f", GhosttyApp.shared.defaultBackgroundOpacity))"
            )
            refreshGhosttyAppearanceConfig(
                reason: "ghosttyDefaultBackgroundDidChange",
                backgroundEventId: eventId,
                backgroundSource: source,
                notificationPayloadHex: payloadHex
            )
        }
        .ignoresSafeArea(.container, edges: (isMinimalMode && !isFullScreen) ? .top : [])
    }

    private func syncBonsplitNotificationBadges() {
        let manualUnread = workspace.manualUnreadPanelIds
        let restoredUnread = workspace.restoredUnreadPanelIds
        let isWorkspaceManuallyUnread = notificationStore.hasManualUnread(forTabId: workspace.id)
        let workspaceManualUnreadPanelId = workspace.representativePanelIdForWorkspaceManualUnread()

        for layoutTab in workspace.layoutTabs {
            let controller = layoutTab.bonsplitController
            for paneId in controller.allPaneIds {
                for tab in controller.tabs(inPane: paneId) {
                    let panelId = workspace.panelIdFromSurfaceId(tab.id)
                    let expectedKind = panelId.flatMap { workspace.panelKind(panelId: $0) }
                    let expectedPinned = panelId.map { workspace.isPanelPinned($0) } ?? false
                    let shouldShow = panelId.map {
                        Workspace.shouldShowUnreadIndicator(
                            hasUnreadNotification: notificationStore.hasVisibleNotificationIndicator(
                                forTabId: workspace.id,
                                surfaceId: $0
                            ),
                            hasPanelUnreadIndicator: manualUnread.contains($0) || restoredUnread.contains($0),
                            isWorkspaceManuallyUnread: isWorkspaceManuallyUnread,
                            isWorkspaceManualUnreadRepresentative: workspaceManualUnreadPanelId == $0
                        )
                    } ?? false
                    let kindUpdate: String?? = expectedKind.map { .some($0) }

                    if tab.showsNotificationBadge != shouldShow ||
                        tab.isPinned != expectedPinned ||
                        (expectedKind != nil && tab.kind != expectedKind) {
                        controller.updateTab(
                            tab.id,
                            kind: kindUpdate,
                            showsNotificationBadge: shouldShow,
                            isPinned: expectedPinned
                        )
                    }
                }
            }
        }
    }

    private static let tmuxWorkspacePaneTopChromeHeight: CGFloat = MinimalModeChromeMetrics.titlebarHeight

    static func resolveGhosttyAppearanceConfig(
        reason: String = "unspecified",
        backgroundOverride: NSColor? = nil,
        loadConfig: () -> GhosttyConfig = { GhosttyConfig.load() },
        defaultBackground: () -> NSColor = { GhosttyApp.shared.defaultBackgroundColor },
        defaultBackgroundOpacity: () -> Double = { GhosttyApp.shared.defaultBackgroundOpacity }
    ) -> GhosttyConfig {
        var next = loadConfig()
        let loadedBackgroundHex = next.backgroundColor.hexString()
        let defaultBackgroundHex: String
        let resolvedBackground: NSColor

        if let backgroundOverride {
            resolvedBackground = backgroundOverride
            defaultBackgroundHex = "skipped"
        } else {
            let fallback = defaultBackground()
            resolvedBackground = fallback
            defaultBackgroundHex = fallback.hexString()
        }

        next.backgroundColor = resolvedBackground
        next.backgroundOpacity = defaultBackgroundOpacity()
        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme resolve reason=\(reason) loadedBg=\(loadedBackgroundHex) overrideBg=\(backgroundOverride?.hexString() ?? "nil") defaultBg=\(defaultBackgroundHex) finalBg=\(next.backgroundColor.hexString()) opacity=\(String(format: "%.3f", next.backgroundOpacity)) theme=\(next.theme ?? "nil")"
            )
        }
        return next
    }

    private enum TmuxWorkspacePaneOverlayTrimMode {
        case workspaceLocal
        case windowContent
    }

    private static func tmuxWorkspacePaneContentRect(
        _ rect: CGRect,
        trimMode: TmuxWorkspacePaneOverlayTrimMode
    ) -> CGRect {
        let topInset = min(tmuxWorkspacePaneTopChromeHeight, max(0, rect.height - 1))
        switch trimMode {
        case .workspaceLocal, .windowContent:
            return CGRect(
                x: rect.origin.x,
                y: rect.origin.y + topInset,
                width: rect.width,
                height: max(0, rect.height - topInset)
            )
        }
    }

    private static func tmuxWorkspacePaneRect(
        layoutSnapshot: LayoutSnapshot?,
        paneId: PaneID?,
        includeContainerOffset: Bool,
        trimMode: TmuxWorkspacePaneOverlayTrimMode
    ) -> CGRect? {
        guard let layoutSnapshot,
              let paneId,
              let paneRect = layoutSnapshot.panes
                .first(where: { $0.paneId == paneId.id.uuidString })?
                .frame
                .cgRect else {
            return nil
        }

        let rect: CGRect
        if includeContainerOffset {
            rect = paneRect.offsetBy(
                dx: 0,
                dy: -CGFloat(layoutSnapshot.containerFrame.y)
            )
        } else {
            rect = paneRect.offsetBy(
                dx: -CGFloat(layoutSnapshot.containerFrame.x),
                dy: -CGFloat(layoutSnapshot.containerFrame.y)
            )
        }
        return tmuxWorkspacePaneContentRect(rect, trimMode: trimMode)
    }

    private static func tmuxWorkspacePaneRects(
        workspace: Workspace,
        notificationStore: TerminalNotificationStore,
        layoutSnapshot: LayoutSnapshot?,
        includeContainerOffset: Bool,
        trimMode: TmuxWorkspacePaneOverlayTrimMode
    ) -> [CGRect] {
        guard let layoutSnapshot else { return [] }
        let isWorkspaceManuallyUnread = notificationStore.hasManualUnread(forTabId: workspace.id)
        let workspaceManualUnreadPanelId = workspace.representativePanelIdForWorkspaceManualUnread()

        return layoutSnapshot.panes.compactMap { pane in
            guard let selectedTabId = pane.selectedTabId,
                  let tabUUID = UUID(uuidString: selectedTabId),
                  let panelId = workspace.panelIdFromSurfaceId(TabID(uuid: tabUUID)) else {
                return nil
            }

            let shouldShowUnread = Workspace.shouldShowUnreadIndicator(
                hasUnreadNotification: notificationStore.hasVisibleNotificationIndicator(
                    forTabId: workspace.id,
                    surfaceId: panelId
                ),
                hasPanelUnreadIndicator: workspace.manualUnreadPanelIds.contains(panelId) ||
                    workspace.restoredUnreadPanelIds.contains(panelId),
                isWorkspaceManuallyUnread: isWorkspaceManuallyUnread,
                isWorkspaceManualUnreadRepresentative: workspaceManualUnreadPanelId == panelId
            )
            guard shouldShowUnread else { return nil }

            let paneRect = pane.frame.cgRect
            let rect: CGRect
            if includeContainerOffset {
                rect = paneRect.offsetBy(
                    dx: 0,
                    dy: -CGFloat(layoutSnapshot.containerFrame.y)
                )
            } else {
                rect = paneRect.offsetBy(
                    dx: -CGFloat(layoutSnapshot.containerFrame.x),
                    dy: -CGFloat(layoutSnapshot.containerFrame.y)
                )
            }
            return tmuxWorkspacePaneContentRect(rect, trimMode: trimMode)
        }
    }

    static func tmuxWorkspacePaneOverlayRect(
        layoutSnapshot: LayoutSnapshot?,
        paneId: PaneID?
    ) -> CGRect? {
        tmuxWorkspacePaneRect(
            layoutSnapshot: layoutSnapshot,
            paneId: paneId,
            includeContainerOffset: false,
            trimMode: .workspaceLocal
        )
    }

    static func tmuxWorkspacePaneWindowOverlayRect(
        layoutSnapshot: LayoutSnapshot?,
        paneId: PaneID?
    ) -> CGRect? {
        tmuxWorkspacePaneRect(
            layoutSnapshot: layoutSnapshot,
            paneId: paneId,
            includeContainerOffset: true,
            trimMode: .windowContent
        )
    }

    static func effectiveTmuxLayoutSnapshot(
        cachedSnapshot: LayoutSnapshot?,
        liveSnapshot: LayoutSnapshot?
    ) -> LayoutSnapshot? {
        if let liveSnapshot,
           tmuxLayoutSnapshotHasRenderableGeometry(liveSnapshot) {
            return liveSnapshot
        }
        if let cachedSnapshot,
           tmuxLayoutSnapshotHasRenderableGeometry(cachedSnapshot) {
            return cachedSnapshot
        }
        return cachedSnapshot ?? liveSnapshot
    }

    static func tmuxWorkspacePaneUnreadRects(
        workspace: Workspace,
        notificationStore: TerminalNotificationStore,
        layoutSnapshot: LayoutSnapshot?
    ) -> [CGRect] {
        tmuxWorkspacePaneRects(
            workspace: workspace,
            notificationStore: notificationStore,
            layoutSnapshot: layoutSnapshot,
            includeContainerOffset: false,
            trimMode: .workspaceLocal
        )
    }

    static func tmuxWorkspacePaneWindowUnreadRects(
        workspace: Workspace,
        notificationStore: TerminalNotificationStore,
        layoutSnapshot: LayoutSnapshot?
    ) -> [CGRect] {
        tmuxWorkspacePaneRects(
            workspace: workspace,
            notificationStore: notificationStore,
            layoutSnapshot: layoutSnapshot,
            includeContainerOffset: true,
            trimMode: .windowContent
        )
    }

    private static func tmuxLayoutSnapshotHasRenderableGeometry(_ snapshot: LayoutSnapshot) -> Bool {
        snapshot.containerFrame.width > 1 &&
            snapshot.containerFrame.height > 1 &&
            snapshot.panes.contains { pane in
                pane.frame.width > 1 && pane.frame.height > 1
            }
    }

    private func flushDeferredThemeRefreshIfNeeded() {
        guard isWorkspaceVisible,
              let deferredRefresh = deferredThemeRefresh else { return }
        deferredThemeRefresh = nil
        refreshGhosttyAppearanceConfig(
            reason: deferredRefresh.reason,
            backgroundOverride: deferredRefresh.backgroundOverride,
            backgroundEventId: deferredRefresh.backgroundEventId,
            backgroundSource: deferredRefresh.backgroundSource,
            notificationPayloadHex: deferredRefresh.notificationPayloadHex,
            forceInitialApply: deferredRefresh.forceInitialApply
        )
    }

    private func updateAgentHibernationPresentationVisibility() {
        workspace.setAgentHibernationAutoResumePresentationVisible(isWorkspaceVisible && isWorkspaceInputActive)
    }

    private func refreshGhosttyAppearanceConfig(
        reason: String,
        backgroundOverride: NSColor? = nil,
        backgroundEventId: UInt64? = nil,
        backgroundSource: String? = nil,
        notificationPayloadHex: String? = nil,
        forceInitialApply: Bool = false
    ) {
        guard isWorkspaceVisible else {
            let existing = deferredThemeRefresh
            deferredThemeRefresh = DeferredThemeRefresh(
                reason: reason,
                backgroundOverride: backgroundOverride,
                backgroundEventId: backgroundEventId,
                backgroundSource: backgroundSource,
                notificationPayloadHex: notificationPayloadHex,
                forceInitialApply: forceInitialApply
                    || reason == "onAppear"
                    || existing?.forceInitialApply == true
            )
            return
        }
        deferredThemeRefresh = nil

        let previousSignature = Self.ghosttyAppearanceSignature(
            config,
            usesHostLayerBackground: lastAppliedUsesHostLayerBackground
        )
        let previousBackgroundHex = config.backgroundColor.hexString()
        let next = Self.resolveGhosttyAppearanceConfig(
            reason: reason,
            backgroundOverride: backgroundOverride
        )
        let nextUsesHostLayerBackground = GhosttyApp.shared.usesHostLayerBackground
        let nextSignature = Self.ghosttyAppearanceSignature(
            next,
            usesHostLayerBackground: nextUsesHostLayerBackground
        )
        let eventLabel = backgroundEventId.map(String.init) ?? "nil"
        let sourceLabel = backgroundSource ?? "nil"
        let payloadLabel = notificationPayloadHex ?? "nil"
        let configChanged = previousSignature != nextSignature
        let backgroundChanged = previousBackgroundHex != next.backgroundColor.hexString()
        let opacityChanged = abs(config.backgroundOpacity - next.backgroundOpacity) > 0.0001
        let blurChanged = config.backgroundBlur != next.backgroundBlur
        let shouldForceInitialApply = forceInitialApply || reason == "onAppear"
        let shouldRequestTitlebarRefresh = backgroundChanged || opacityChanged || blurChanged || shouldForceInitialApply
        let shouldApplyChrome = configChanged || shouldForceInitialApply
        let shouldRefreshWindowBackground = backgroundChanged || opacityChanged || blurChanged || shouldForceInitialApply
        if !shouldApplyChrome && !shouldRefreshWindowBackground && !shouldRequestTitlebarRefresh {
            logTheme(
                "theme refresh skip workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) source=\(sourceLabel) payload=\(payloadLabel)"
            )
            return
        }
        logTheme(
            "theme refresh begin workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) source=\(sourceLabel) payload=\(payloadLabel) previousBg=\(previousBackgroundHex) nextBg=\(next.backgroundColor.hexString()) overrideBg=\(backgroundOverride?.hexString() ?? "nil")"
        )
        withTransaction(Transaction(animation: nil)) {
            if configChanged {
                config = next
            }
            if shouldApplyChrome {
                lastAppliedUsesHostLayerBackground = nextUsesHostLayerBackground
            }
            if shouldRequestTitlebarRefresh {
                onThemeRefreshRequest?(
                    reason,
                    backgroundEventId,
                    backgroundSource,
                    notificationPayloadHex
                )
            }
        }
        if !shouldRequestTitlebarRefresh {
            logTheme(
                "theme refresh titlebar-skip workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) previousBg=\(previousBackgroundHex) nextBg=\(next.backgroundColor.hexString())"
            )
        }
        logTheme(
            "theme refresh config-applied workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) configBg=\(config.backgroundColor.hexString())"
        )
        let chromeReason =
            "refreshGhosttyAppearanceConfig:reason=\(reason):event=\(eventLabel):source=\(sourceLabel):payload=\(payloadLabel)"
        if shouldApplyChrome {
            workspace.applyGhosttyChrome(from: next, reason: chromeReason)
        }
        if shouldRefreshWindowBackground {
            if let terminalPanel = workspace.focusedTerminalPanel {
                terminalPanel.applyWindowBackgroundIfActive()
                logTheme(
                    "theme refresh terminal-applied workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) panel=\(workspace.focusedPanelId?.uuidString ?? "nil")"
                )
            } else {
                logTheme(
                    "theme refresh terminal-skipped workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) focusedPanel=\(workspace.focusedPanelId?.uuidString ?? "nil")"
                )
            }
        }
        logTheme(
            "theme refresh end workspace=\(workspace.id.uuidString) reason=\(reason) event=\(eventLabel) chromeBg=\(workspace.bonsplitController.configuration.appearance.chromeColors.backgroundHex ?? "nil")"
        )
    }

    private func logTheme(_ message: String) {
        guard GhosttyApp.shared.backgroundLogEnabled else { return }
        GhosttyApp.shared.logBackground(message)
    }
}

extension WorkspaceContentView {
    static func terminalAgentContext(panel: any Panel, workspace: Workspace) -> String {
        var parts: [String] = []
        if let terminalPanel = panel as? TerminalPanel {
            if let initialCommand = terminalPanel.surface.initialCommand {
                parts.append("initialCommand:\(initialCommand)")
            }
            if let tmuxStartCommand = terminalPanel.surface.tmuxStartCommand {
                parts.append("tmuxStartCommand:\(tmuxStartCommand)")
            }
        }
        if let restoredAgent = workspace.restoredAgentSnapshotsByPanelId[panel.id] {
            parts.append("restoredAgent:\(restoredAgent.kind.rawValue)")
        }
        if let agentPIDKeys = workspace.agentPIDKeysByPanelId[panel.id], !agentPIDKeys.isEmpty {
            for key in agentPIDKeys.sorted() {
                parts.append("agentPIDKey:\(key)")
            }
        }
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    #if DEBUG
    static func debugPanelLookup(tab: Bonsplit.Tab, workspace: Workspace) {
        let found = workspace.panel(for: tab.id) != nil
        if !found {
            let ts = ISO8601DateFormatter().string(from: Date())
            let line = "[\(ts)] PANEL NOT FOUND for tabId=\(tab.id) ws=\(workspace.id) panelCount=\(workspace.panels.count)\n"
            let logPath = "/tmp/cmux-panel-debug.log"
            if let handle = FileHandle(forWritingAtPath: logPath) {
                defer { try? handle.close() }
                guard (try? handle.seekToEnd()) != nil else { return }
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
            }
        }
    }
    #else
    static func debugPanelLookup(tab: Bonsplit.Tab, workspace: Workspace) {
        _ = tab
        _ = workspace
    }
    #endif
}

/// View shown for empty panes
struct EmptyPanelView: View {
    @ObservedObject var workspace: Workspace
    let paneId: PaneID
    @ObservedObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared

    private struct ShortcutHint: View {
        let text: String

        var body: some View {
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.white.opacity(0.18), in: Capsule())
        }
    }

    private func focusPane() {
        workspace.bonsplitController.focusPane(paneId)
    }

    private func createTerminal() {
        #if DEBUG
        cmuxDebugLog("emptyPane.newTerminal pane=\(paneId.id.uuidString.prefix(5))")
        #endif
        focusPane()
        _ = workspace.newTerminalSurface(inPane: paneId)
    }

    private func createBrowser() {
        #if DEBUG
        cmuxDebugLog("emptyPane.newBrowser pane=\(paneId.id.uuidString.prefix(5))")
        #endif
        focusPane()
        _ = workspace.newBrowserSurface(inPane: paneId)
    }

    private var newSurfaceShortcut: StoredShortcut {
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .newSurface)
    }

    private var openBrowserShortcut: StoredShortcut {
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .openBrowser)
    }

    @ViewBuilder
    private func emptyPaneActionButton(
        title: String,
        systemImage: String,
        shortcut: StoredShortcut,
        action: @escaping () -> Void
    ) -> some View {
        if let key = shortcut.keyEquivalent {
            Button(action: action) {
                HStack(spacing: 10) {
                    Label(title, systemImage: systemImage)
                    ShortcutHint(text: shortcut.displayString)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(key, modifiers: shortcut.eventModifiers)
        } else {
            Button(action: action) {
                HStack(spacing: 10) {
                    Label(title, systemImage: systemImage)
                    ShortcutHint(text: shortcut.displayString)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("Empty Panel")
                .font(.headline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                emptyPaneActionButton(
                    title: "Terminal",
                    systemImage: "terminal.fill",
                    shortcut: newSurfaceShortcut,
                    action: createTerminal
                )

                emptyPaneActionButton(
                    title: "Browser",
                    systemImage: "globe",
                    shortcut: openBrowserShortcut,
                    action: createBrowser
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: GhosttyBackgroundTheme.currentColor()))
#if DEBUG
        .onAppear {
            DebugUIEventCounters.emptyPanelAppearCount += 1
        }
#endif
    }
}

// MARK: - Layout Tab Bonsplit View

/// Renders a single layout tab's BonsplitView content.
struct LayoutTabBonsplitView: View {
    let workspace: Workspace
    @ObservedObject var layoutTab: LayoutTab
    let isSelected: Bool
    let isWorkspaceVisible: Bool
    let isWorkspaceInputActive: Bool
    let workspacePortalPriority: Int
    let config: GhosttyConfig
    let notificationStore: TerminalNotificationStore

    var body: some View {
        let controller = layoutTab.bonsplitController
        let appearance = PanelAppearance.fromConfig(config)
        let isSplit = controller.allPaneIds.count > 1 ||
            workspace.panels.count > 1
        let usesWorkspacePaneOverlay = TmuxOverlayExperimentSettings.target().usesWorkspacePaneOverlay
        let isWorkspaceManuallyUnread = notificationStore.hasManualUnread(forTabId: workspace.id)
        let workspaceManualUnreadPanelId = workspace.representativePanelIdForWorkspaceManualUnread()

        let _ = { controller.isInteractive = isWorkspaceInputActive }()

        let _ = {
            controller.onFileDrop = { [weak workspace] urls, paneId in
                guard let workspace else { return false }
                guard let tabId = controller.selectedTab(inPane: paneId)?.id,
                      let panelId = workspace.panelIdFromSurfaceId(tabId),
                      let panel = workspace.panels[panelId] as? TerminalPanel else { return false }
                return panel.hostedView.handleDroppedURLs(urls)
            }
        }()

        BonsplitView(controller: controller) { tab, paneId in
            let _ = WorkspaceContentView.debugPanelLookup(tab: tab, workspace: workspace)
            if let panel = workspace.panel(for: tab.id) {
                let isFocused = isWorkspaceInputActive && workspace.focusedPanelId == panel.id
                let isSelectedInPane = controller.selectedTab(inPane: paneId)?.id == tab.id
                let isVisibleInUI = WorkspaceContentView.panelVisibleInUI(
                    isWorkspaceVisible: isWorkspaceVisible && isSelected,
                    isSelectedInPane: isSelectedInPane,
                    isFocused: isFocused
                )
                let showsNotificationRing = Workspace.shouldShowUnreadIndicator(
                    hasUnreadNotification: notificationStore.hasVisibleNotificationIndicator(
                        forTabId: workspace.id,
                        surfaceId: panel.id
                    ),
                    hasPanelUnreadIndicator: workspace.manualUnreadPanelIds.contains(panel.id) ||
                        workspace.restoredUnreadPanelIds.contains(panel.id),
                    isWorkspaceManuallyUnread: isWorkspaceManuallyUnread,
                    isWorkspaceManualUnreadRepresentative: workspaceManualUnreadPanelId == panel.id
                )
                PanelContentView(
                    panel: panel,
                    workspaceId: workspace.id,
                    paneId: paneId,
                    isFocused: isFocused,
                    isSelectedInPane: isSelectedInPane,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: workspacePortalPriority,
                    isSplit: isSplit,
                    appearance: appearance,
                    hasUnreadNotification: showsNotificationRing && !usesWorkspacePaneOverlay,
                    terminalAgentContext: WorkspaceContentView.terminalAgentContext(panel: panel, workspace: workspace),
                    onFocus: {
                        guard isWorkspaceInputActive else { return }
                        guard workspace.panels[panel.id] != nil else { return }
                        workspace.focusPanel(panel.id, trigger: .terminalFirstResponder)
                    },
                    onRequestPanelFocus: {
                        guard isWorkspaceInputActive else { return }
                        guard workspace.panels[panel.id] != nil else { return }
                        AppDelegate.shared?.noteMainPanelKeyboardFocusIntent(
                            workspaceId: workspace.id,
                            panelId: panel.id,
                            in: NSApp.keyWindow ?? NSApp.mainWindow
                        )
                        workspace.focusPanel(panel.id)
                    },
                    onResumeAgentHibernation: {
                        guard isWorkspaceInputActive else { return }
                        guard workspace.panels[panel.id] != nil else { return }
                        workspace.resumeAgentHibernation(panelId: panel.id, focus: true)
                    },
                    onAutoResumeAgentHibernation: {
                        guard isWorkspaceInputActive else { return }
                        guard workspace.panels[panel.id] != nil else { return }
                        workspace.resumeAgentHibernation(panelId: panel.id, focus: false)
                    },
                    onTriggerFlash: { workspace.triggerDebugFlash(panelId: panel.id) }
                )
                .onTapGesture {
                    controller.focusPane(paneId)
                }
            } else {
                EmptyPanelView(workspace: workspace, paneId: paneId)
            }
        } emptyPane: { paneId in
            EmptyPanelView(workspace: workspace, paneId: paneId)
                .onTapGesture {
                    controller.focusPane(paneId)
                }
        }
        .internalOnlyTabDrag()
        .id(splitZoomRenderIdentity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var splitZoomRenderIdentity: String {
        layoutTab.bonsplitController.zoomedPaneId.map { "zoom:\($0.id.uuidString)" } ?? "unzoomed"
    }
}

// MARK: - Layout Tab Strip View

/// Horizontal tab strip showing layout tabs within a workspace.
struct LayoutTabStripView: View {
    @ObservedObject var workspace: Workspace
    @State private var isCommandHeld = false
    @State private var commandHoldMonitor: Any?
    @State private var commandHoldWorkItem: DispatchWorkItem?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(workspace.layoutTabs.enumerated()), id: \.element.id) { index, layoutTab in
                let isSelected = layoutTab.id == workspace.selectedLayoutTabId
                let shortcutDigit: Int? = index < 8 ? index + 1 : (index == workspace.layoutTabs.count - 1 ? 9 : nil)
                LayoutTabItemView(
                    layoutTab: layoutTab,
                    index: index + 1,
                    isSelected: isSelected,
                    shortcutHint: isCommandHeld ? shortcutDigit.map { "⌘\($0)" } : nil,
                    onSelect: { workspace.selectLayoutTab(id: layoutTab.id) },
                    onClose: workspace.layoutTabs.count > 1 ? { workspace.closeLayoutTab(id: layoutTab.id) } : nil
                )
            }

            Button {
                workspace.createLayoutTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "layoutTab.newTab", defaultValue: "New Tab"))

            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.06))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
        .onAppear { startCommandHoldMonitor() }
        .onDisappear { stopCommandHoldMonitor() }
    }

    private func startCommandHoldMonitor() {
        guard commandHoldMonitor == nil else { return }
        commandHoldMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let normalized = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if normalized == [.command] {
                guard !isCommandHeld, commandHoldWorkItem == nil else { return event }
                let workItem = DispatchWorkItem { [self] in
                    self.isCommandHeld = true
                }
                commandHoldWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
            } else {
                cancelCommandHold()
            }
            return event
        }
    }

    private func cancelCommandHold() {
        commandHoldWorkItem?.cancel()
        commandHoldWorkItem = nil
        isCommandHeld = false
    }

    private func stopCommandHoldMonitor() {
        if let monitor = commandHoldMonitor {
            NSEvent.removeMonitor(monitor)
            commandHoldMonitor = nil
        }
        cancelCommandHold()
    }
}

/// A single layout tab item in the strip.
private struct LayoutTabItemView: View {
    @ObservedObject var layoutTab: LayoutTab
    let index: Int
    let isSelected: Bool
    let shortcutHint: String?
    let onSelect: () -> Void
    let onClose: (() -> Void)?

    @State private var isHovering = false
    @State private var isEditing = false
    @State private var editingTitle = ""

    private func beginEditing() {
        editingTitle = layoutTab.title
        isEditing = true
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 9))
                .foregroundStyle(isSelected ? .white.opacity(0.9) : .white.opacity(0.4))

            if isEditing {
                TextField("", text: $editingTitle, onCommit: {
                    let trimmed = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        layoutTab.title = trimmed
                    }
                    isEditing = false
                })
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .frame(minWidth: 60, maxWidth: 120)
            } else {
                Text(layoutTab.title)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .white.opacity(0.9) : .white.opacity(0.5))
            }

            if let shortcutHint {
                Text(shortcutHint)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.15), in: Capsule())
            } else if let onClose {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(isHovering || isSelected ? 0.4 : 0.15))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.white.opacity(0.12) : (isHovering ? Color.white.opacity(0.06) : Color.clear))
        )
        .onTapGesture(count: 2) {
            beginEditing()
        }
        .onTapGesture { onSelect() }
        .contextMenu {
            Button(String(localized: "layoutTab.rename", defaultValue: "Rename Tab")) {
                beginEditing()
            }
            if let onClose {
                Divider()
                Button(String(localized: "layoutTab.close", defaultValue: "Close Tab")) {
                    onClose()
                }
            }
        }
        .onHover { isHovering = $0 }
    }
}

#if DEBUG
@MainActor
enum DebugUIEventCounters {
    static var emptyPanelAppearCount: Int = 0

    static func resetEmptyPanelAppearCount() {
        emptyPanelAppearCount = 0
    }
}
#endif
