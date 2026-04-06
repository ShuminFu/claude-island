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

        let statusStream = self.viewModel.makeStatusStream()
        self.statusTask = Task(name: "notch-status-stream") { @MainActor [weak notchWindow, weak viewModel] in
            for await status in statusStream {
                guard let panel = notchWindow else { continue }
                switch status {
                case .opened:
                    // Panel needs to receive mouse events when opened for interactive content
                    panel.isContentActive = true
                    panel.ignoresMouseEvents = false
                    // Don't steal focus when opened by notification or hover.
                    // makeKey() on a .mainMenu+3 panel can trap the mouse cursor
                    // because macOS routes all events in the window frame to the key window.
                    let reason = viewModel?.openReason
                    if reason == .hotkey {
                        // Force activation for hotkey opens so local keyboard
                        // event monitor receives subsequent key events
                        NSApp.activate()
                        panel.makeKey()
                    } else if reason == .click {
                        panel.makeKey()
                    }
                    // hover / notification opens: no makeKey — user can still click
                    // the panel to give it key status if they need keyboard interaction
                case .closed,
                     .popping:
                    // When closed, ignore mouse events so the transparent window doesn't
                    // interfere with mouse tracking. Global event monitors handle hover
                    // detection and click-to-open independently.
                    panel.isContentActive = false
                    panel.ignoresMouseEvents = true
                    panel.resignKey()
                }
            }
        }

        // Perform boot animation after a brief delay (only on initial launch)
        if animateOnLaunch {
            self.bootAnimationTask = Task(name: "boot-animation-delay") { [weak self] in
                try? await Task.sleep(for: .seconds(0.3))
                guard !Task.isCancelled else { return }
                self?.viewModel.performBootAnimation()
            }
        }
    }

    deinit {
        statusTask?.cancel()
        bootAnimationTask?.cancel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Internal

    let viewModel: NotchViewModel

    // MARK: Private

    nonisolated private static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "NotchGeometry")

    private let screen: NSScreen
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
}
