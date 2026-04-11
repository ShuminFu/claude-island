//
//  NotchWindowController.swift
//  ClaudeIsland
//
//  Controls the notch window positioning and lifecycle
//

import AppKit
import os.log
import SwiftUI

class NotchWindowController: NSWindowController {
    // MARK: Lifecycle

    init(screen: NSScreen, animateOnLaunch: Bool = true) {
        self.screen = screen

        let screenFrame = screen.frame
        let notchSize = screen.notchSize
        Self.logNotchGeometry(for: screen)

        // Window covers full width at top, tall enough for largest content (chat view)
        let windowHeight: CGFloat = 750
        let windowFrame = NSRect(
            x: screenFrame.origin.x,
            y: screenFrame.maxY - windowHeight,
            width: screenFrame.width,
            height: windowHeight,
        )

        // Device notch rect - positioned at center
        let deviceNotchRect = CGRect(
            x: (screenFrame.width - notchSize.width) / 2,
            y: 0,
            width: notchSize.width,
            height: notchSize.height,
        )

        // Create view model
        self.viewModel = NotchViewModel(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenFrame,
            windowHeight: windowHeight,
            hasPhysicalNotch: screen.hasPhysicalNotch,
        )

        // Create the window
        let notchWindow = NotchPanel(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
        )

        super.init(window: notchWindow)

        // Create the SwiftUI view with pass-through hosting
        let hostingController = NotchViewController(viewModel: viewModel)
        notchWindow.contentViewController = hostingController

        notchWindow.setFrame(windowFrame, display: true)

        // Start ignoring mouse events — the notch begins closed.
        // Global event monitors handle hover detection and click-to-open.
        // When the notch opens, the status stream handler enables mouse events
        // so interactive content (buttons, scroll views) works.
        notchWindow.ignoresMouseEvents = true

        self.setupStatusStream(panel: notchWindow, viewModel: self.viewModel)
        self.setupBootAnimation(animateOnLaunch: animateOnLaunch)
        self.setupDetachableNotch(viewModel: self.viewModel)
    }

    deinit {
        statusTask?.cancel()
        bootAnimationTask?.cancel()
        windowModeTask?.cancel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Internal

    nonisolated static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "NotchWindowController")

    let viewModel: NotchViewModel
    let screen: NSScreen

    // MARK: - Detachable Notch (shared with NotchWindowController+Detach.swift)

    var detachedPanel: DetachedPanel?
    var detachedHostingView: FirstMouseHostingView<DetachedNotchView>?
    var dragController: NotchDragController?
    var windowModeTask: Task<Void, Never>?

    /// Whether the snap-back was triggered by the snap zone (already handled by drag controller)
    /// vs an explicit action like clicking the notch (needs animated snap-back).
    var snapBackHandledByDragController = false

    /// Constrain detached panel to screen bounds on screen change
    func constrainDetachedPanelToScreen() {
        guard let panel = self.detachedPanel else { return }
        let screenFrame = self.screen.visibleFrame
        var frame = panel.frame

        // Ensure at least 50pt of the panel remains on screen
        frame.origin.x = max(screenFrame.minX - frame.width + 50, min(frame.origin.x, screenFrame.maxX - 50))
        frame.origin.y = max(screenFrame.minY, min(frame.origin.y, screenFrame.maxY - 50))

        panel.setFrame(frame, display: true)
    }

    // MARK: Private

    private var statusTask: Task<Void, Never>?
    private var bootAnimationTask: Task<Void, Never>?

    private static func logNotchGeometry(for screen: NSScreen) {
        let leftAuxWidth = screen.auxiliaryTopLeftArea?.width ?? 0
        let rightAuxWidth = screen.auxiliaryTopRightArea?.width ?? 0
        let baseWidth = screen.notchExclusionBaseWidth
        let reservedWidth = screen.reservedNotchExclusionWidth
        Self.logger.debug(
            """
            notch geometry: safeTop=\(screen.safeAreaInsets.top, privacy: .public), leftAux=\(leftAuxWidth, privacy: .public), rightAux=\(
                rightAuxWidth,
                privacy: .public,
            ), baseWidth=\(baseWidth, privacy: .public), reservedWidth=\(reservedWidth, privacy: .public)
            """,
        )
    }

    private func setupStatusStream(panel notchWindow: NotchPanel, viewModel: NotchViewModel) {
        // Install the drag-header claim hook once — it reads the live view model so it
        // covers the currently-opened panel rect (content-type toggles resize it).
        // This prevents NotchPanel.sendEvent from reposting mouseDown events that land
        // on the rounded-corner cutouts of the NotchShape, which would otherwise warp
        // the hardware cursor and make drag-to-detach twitch at the very top of the screen.
        notchWindow.shouldClaimMouseDown = { [weak viewModel] screenLocation in
            guard let vm = viewModel, vm.status == .opened, vm.windowMode == .docked else {
                return false
            }
            let panelRect = vm.geometry.openedScreenRect(for: vm.openedSize)
            // Match NotchDragController's drag header rect (top 40pt of the opened panel)
            // with an inclusive `maxY` check so the very top row of pixels still counts.
            let headerMinY = panelRect.maxY - 40
            return screenLocation.x >= panelRect.minX
                && screenLocation.x <= panelRect.maxX
                && screenLocation.y >= headerMinY
                && screenLocation.y <= panelRect.maxY
        }

        let statusStream = viewModel.makeStatusStream()
        self.statusTask = Task(name: "notch-status-stream") { @MainActor [weak notchWindow, weak viewModel] in
            for await status in statusStream {
                guard let panel = notchWindow else { continue }
                switch status {
                case .opened:
                    panel.isContentActive = true
                    panel.ignoresMouseEvents = false
                    let reason = viewModel?.openReason
                    if reason == .hotkey {
                        NSApp.activate()
                        panel.makeKey()
                    } else if reason == .click {
                        panel.makeKey()
                    }
                case .closed,
                     .popping:
                    panel.isContentActive = false
                    panel.ignoresMouseEvents = true
                    panel.resignKey()
                }
            }
        }
    }

    private func setupBootAnimation(animateOnLaunch: Bool) {
        guard animateOnLaunch else { return }
        self.bootAnimationTask = Task(name: "boot-animation-delay") { [weak self] in
            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled else { return }
            self?.viewModel.performBootAnimation()
        }
    }
}
