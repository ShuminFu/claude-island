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

        // Mouse events are always enabled. The window has backgroundColor = .clear
        // and isOpaque = false, so macOS per-pixel transparency handles click routing:
        // - Clicks on transparent areas pass through to menu bar / windows behind
        // - Clicks on the pill (non-transparent SwiftUI content) are delivered here
        // For edge cases where non-zero alpha pixels exist outside the hitTestRect,
        // NotchPanel.sendEvent temporarily ignores + reposts so the click passes through.
        notchWindow.ignoresMouseEvents = false

        let statusStream = self.viewModel.makeStatusStream()
        self.statusTask = Task(name: "notch-status-stream") { @MainActor [weak notchWindow, weak viewModel] in
            for await status in statusStream {
                switch status {
                case .opened:
                    // Ensure mouse events are enabled (safety reset after any repost)
                    notchWindow?.ignoresMouseEvents = false
                    // Don't steal focus when opened by notification (task finished)
                    if viewModel?.openReason != .notification {
                        if viewModel?.openReason == .hotkey {
                            // Force activation for hotkey opens so local keyboard
                            // event monitor receives subsequent key events
                            NSApp.activate()
                        }
                        notchWindow?.makeKey()
                    }
                case .closed,
                     .popping:
                    // Ensure mouse events are enabled (safety reset after any repost)
                    notchWindow?.ignoresMouseEvents = false
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
