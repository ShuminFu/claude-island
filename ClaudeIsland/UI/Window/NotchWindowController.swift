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

        // Initial (closed) window frame — full width, enough height to cover the notch bar
        // and any module pill expansions. ignoresMouseEvents = true while closed, so the
        // exact size has no effect on click-through; the size is generous to avoid clipping
        // the closed-state pill animation.
        let closedHeight: CGFloat = 80
        let windowFrame = NSRect(
            x: screenFrame.origin.x,
            y: screenFrame.maxY - closedHeight,
            width: screenFrame.width,
            height: closedHeight,
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
            hasPhysicalNotch: screen.hasPhysicalNotch,
        )
        self.closedWindowFrame = windowFrame

        // Create the window
        let notchWindow = NotchPanel(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
        )

        super.init(window: notchWindow)

        let hostingController = NotchViewController(viewModel: viewModel)
        notchWindow.contentViewController = hostingController

        notchWindow.setFrame(windowFrame, display: true)

        // Start ignoring mouse events — the notch begins closed.
        // Global event monitors handle hover detection and click-to-open.
        // When the notch opens, the window is resized to the content rect and
        // mouse events are enabled so buttons and scroll views work.
        notchWindow.ignoresMouseEvents = true

        self.setupStatusStream(panel: notchWindow, viewModel: self.viewModel)
        self.setupBootAnimation(animateOnLaunch: animateOnLaunch)
        self.setupDetachableNotch(viewModel: self.viewModel)
        self.observeDockedPanelContentSize()
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

    /// Window frame used when the notch is closed. Restored whenever the notch closes
    /// so the next open always starts a resize from a known baseline.
    private let closedWindowFrame: NSRect

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
        let statusStream = viewModel.makeStatusStream()
        self.statusTask = Task(name: "notch-status-stream") { @MainActor [weak self, weak notchWindow, weak viewModel] in
            for await status in statusStream {
                guard let panel = notchWindow else { continue }
                switch status {
                case .opened:
                    panel.isContentActive = true
                    // Resize to the visible content rect BEFORE enabling mouse events so
                    // there is never a moment where the large closed frame is interactive.
                    if let vm = viewModel {
                        panel.setFrame(vm.geometry.openedScreenRect(for: vm.openedSize), display: true)
                    }
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
                    // Restore the closed frame so the next open starts from a clean baseline.
                    if let closedFrame = self?.closedWindowFrame {
                        panel.setFrame(closedFrame, display: true)
                    }
                    panel.resignKey()
                }
            }
        }
    }

    // MARK: - Docked panel content-size observation

    /// Observe `openedSize` changes while the notch is open and docked, and resize the
    /// NotchPanel to match — mirrors `resizeDetachedPanelForContentType` for the docked case.
    func observeDockedPanelContentSize() {
        withObservationTracking {
            _ = self.viewModel.openedSize
            _ = self.viewModel.windowMode
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.resizeDockedPanelForContentType()
                self?.observeDockedPanelContentSize()
            }
        }
    }

    private func resizeDockedPanelForContentType() {
        guard self.viewModel.status == .opened,
              self.viewModel.windowMode == .docked,
              let panel = self.window else { return }
        let newFrame = self.viewModel.geometry.openedScreenRect(for: self.viewModel.openedSize)
        guard abs(panel.frame.width - newFrame.width) > 0.5 ||
              abs(panel.frame.height - newFrame.height) > 0.5 else { return }
        panel.setFrame(newFrame, display: true)
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
