//
//  NotchWindowController+Detach.swift
//  ClaudeIsland
//
//  Drag-to-detach lifecycle for the notch panel.
//  Extracted for type body length compliance.
//

import AppKit
import Observation
import SwiftUI

extension NotchWindowController {
    // MARK: - Setup

    func setupDetachableNotch(viewModel: NotchViewModel) {
        self.dragController = NotchDragController(
            viewModel: viewModel,
            getDetachedPanelFrame: { [weak self] in
                self?.detachedPanel?.frame
            },
            onCreateDetachedPanel: { [weak self] in
                self?.createDetachedPanel()
            },
            onDestroyDetachedPanel: { [weak self] in
                self?.snapBackHandledByDragController = true
                self?.destroyDetachedPanel(animated: false)
            },
            onUpdateDetachedPanel: { [weak self] in
                self?.updateDetachedPanelPosition()
            },
        )

        let windowModeStream = viewModel.makeWindowModeStream()
        self.windowModeTask = Task(name: "window-mode-stream") { @MainActor [weak self] in
            for await mode in windowModeStream {
                self?.handleWindowModeChange(mode)
            }
        }

        // Observe openedSize so the detached panel window frame tracks content
        // type toggles (instances ↔ menu ↔ chat). Without this, SwiftUI content
        // grows beyond the fixed NSPanel contentView bounds and gets clipped at
        // the top — visible as jitter/tearing when the user taps the header's
        // menu toggle in detached mode.
        self.observeDetachedPanelContentSize()
    }

    /// Shared animation parameters for content-type transitions.
    /// Both sides of the transition (SwiftUI `.frame` on `openedSize` and the
    /// NSWindow frame) must use these exact values so the two curves agree.
    /// SwiftUI's `.easeInOut(duration: 0.3)` and Core Animation's
    /// `.easeInEaseOut` both map to the cubic bezier `(0.42, 0, 0.58, 1.0)`,
    /// so pairing them produces pixel-identical curves over the same duration.
    ///
    /// A spring (what the docked notch uses) is not an option here: NSWindow
    /// frame animations only accept `CAMediaTimingFunction`, which has no
    /// spring representation, so any attempt to pair a SwiftUI spring with an
    /// NSWindow animation leaves the two sides on different curves and the
    /// top edge tears mid-flight.
    private static let contentSizeAnimationDuration: CFTimeInterval = 0.3

    /// Register a one-shot observation of the view model's `openedSize` and
    /// drive the NSPanel frame to match content-type transitions.
    ///
    /// The resize is dispatched to the next main-actor turn because
    /// `withObservationTracking`'s `onChange` fires from `willSet` — before
    /// the stored property is mutated. Reading `openedSize` synchronously
    /// returns the stale value, making the resize a no-op. The one-tick
    /// delay lets the mutation land first; SwiftUI's own view update is
    /// similarly deferred, so both sides still animate in the same frame.
    func observeDetachedPanelContentSize() {
        withObservationTracking {
            // openedSize transitively reads contentType and selectorUpdateToken.
            _ = self.viewModel.openedSize
            _ = self.viewModel.windowMode
        } onChange: { [weak self] in
            // IMPORTANT: withObservationTracking fires onChange from the
            // registrar's willSet — BEFORE the stored property is mutated.
            // Reading openedSize synchronously here returns the stale value,
            // so the resize becomes a no-op. Dispatch to the next main-actor
            // turn so the mutation has landed before we read the new size.
            DispatchQueue.main.async {
                self?.resizeDetachedPanelForContentType()
                self?.observeDetachedPanelContentSize()
            }
        }
    }

    /// Animate the detached panel window to match the view model's current
    /// `openedSize`, pinning the top edge so content grows/shrinks downward
    /// (mirrors `DetachedNotchView`'s `alignment: .top`).
    ///
    /// Uses the same duration and bezier curve as the SwiftUI `withAnimation`
    /// wrapping the menu toggle. See `contentSizeAnimationDuration` above for
    /// why the two sides are paired this way rather than using a spring.
    func resizeDetachedPanelForContentType() {
        guard let panel = self.detachedPanel,
              self.viewModel.windowMode == .detached
        else { return }

        // The user is actively dragging a resize handle — the panel frame is
        // being set directly via panel.setFrame() on every drag tick. Running
        // the animated resize here would fight those direct calls (different
        // origin due to centering logic + 0.3s animation curve vs. immediate).
        guard !self.viewModel.isUserResizing else { return }

        let newSize = self.viewModel.openedSize
        let newHeight = newSize.height + DetachedNotchView.headerHeight
        let newWidth = newSize.width
        let currentFrame = panel.frame

        // Skip no-op updates so identical selector changes don't thrash the window.
        if abs(currentFrame.width - newWidth) < 0.5,
           abs(currentFrame.height - newHeight) < 0.5 {
            return
        }

        // Pin the top edge (maxY) so the window grows and shrinks downward
        // from where the user left it. Center x so width changes
        // (instances ↔ chat) don't shift the anchor sideways.
        let newOriginY = currentFrame.maxY - newHeight
        let newOriginX = currentFrame.midX - newWidth / 2

        // Clamp the horizontal origin so the panel stays reachable on screen.
        let screenFrame = self.screen.visibleFrame
        let clampedOriginX = max(
            screenFrame.minX - newWidth + 50,
            min(newOriginX, screenFrame.maxX - 50),
        )

        let newFrame = NSRect(
            x: clampedOriginX,
            y: newOriginY,
            width: newWidth,
            height: newHeight,
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.contentSizeAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(newFrame, display: true)
        }

        // Keep the view model in sync so any subsequent drag reads the new origin.
        self.viewModel.detachedOrigin = CGPoint(x: newFrame.origin.x, y: newFrame.origin.y)
    }

    // MARK: - Window Mode Handling

    func handleWindowModeChange(_ mode: WindowMode) {
        Self.logger
            .debug(
                "[mode-change] mode=\(String(describing: mode), privacy: .public), flag=\(self.snapBackHandledByDragController, privacy: .public), hasPanel=\(self.detachedPanel != nil, privacy: .public)",
            )
        switch mode {
        case .docked:
            if self.snapBackHandledByDragController {
                // Drag controller already destroyed the panel — just reset the flag
                self.snapBackHandledByDragController = false
            } else if self.detachedPanel != nil {
                // Explicit snap-back (e.g., dock-back button or clicking notch) — animate
                self.destroyDetachedPanel(animated: true)
            }

        case .detaching:
            break

        case .detached:
            self.detachedPanel?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Panel Lifecycle

    func createDetachedPanel() {
        guard self.detachedPanel == nil else { return }

        let vm = self.viewModel
        let panelSize = vm.openedSize
        let panelRect = vm.geometry.openedScreenRect(for: panelSize)

        // Create the detached panel at the notch's screen position.
        // Height = opened content + header row (which carries the drag gesture / dock-back
        // button). The header now replaces the old standalone drag strip, so the detached
        // and docked layouts share the same header height and the content no longer shifts.
        let panelHeight = panelSize.height + DetachedNotchView.headerHeight
        let panel = DetachedPanel(
            contentRect: NSRect(
                x: panelRect.origin.x,
                y: panelRect.origin.y - DetachedNotchView.headerHeight,
                width: panelSize.width,
                height: panelHeight,
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
        )

        // Host the detached SwiftUI view.
        // Use FirstMouseHostingView so clicks (e.g., the dock-back button) fire on the
        // first tap even when the panel is not currently key — `.nonactivatingPanel`
        // otherwise consumes the first click for key-window promotion.
        //
        // The drag gesture lives inside DetachedNotchView (SwiftUI), not in
        // NotchDragController's NSEvent local monitor — local monitors don't fire
        // reliably for clicks on a non-activating panel's hosting view, so the
        // panel could not be re-dragged once it was already detached.
        let hostingView = FirstMouseHostingView(
            rootView: DetachedNotchView(
                viewModel: vm,
                currentPanelOrigin: { [weak self] in
                    // Return the panel's actual current frame origin. During a
                    // content-type resize animation this is mid-interpolation
                    // while `viewModel.detachedOrigin` already holds the target
                    // — anchoring from the target is what caused the drag to
                    // teleport. Also sync `detachedOrigin` so non-drag consumers
                    // read the same value the drag is anchored from.
                    guard let self, let panel = self.detachedPanel else { return nil }
                    let origin = panel.frame.origin
                    self.viewModel.detachedOrigin = origin
                    return origin
                },
                currentPanelFrame: { [weak self] in
                    self?.detachedPanel?.frame
                },
                onDrag: { [weak self] origin in
                    self?.detachedPanel?.setFrameOrigin(NSPoint(x: origin.x, y: origin.y))
                },
                onDragEnd: { [weak self] location in
                    guard let self else { return }
                    if self.viewModel.geometry.isInSnapZone(location) {
                        self.snapBackHandledByDragController = true
                        self.viewModel.snapBackToNotch()
                        self.destroyDetachedPanel(animated: false)
                    }
                },
                onResizeGrip: { [weak self] newFrame in
                    guard let self, let panel = self.detachedPanel else { return }
                    self.viewModel.isUserResizing = true
                    // Update the view model BEFORE setFrame so SwiftUI's .frame()
                    // modifier already has the correct size when display is forced.
                    let contentHeight = newFrame.height - DetachedNotchView.headerHeight
                    self.viewModel.detachedUserSize = CGSize(width: newFrame.width, height: contentHeight)
                    self.viewModel.detachedOrigin = newFrame.origin
                    panel.setFrame(newFrame, display: true)
                    Self.logger.debug("[resize-grip] new frame \(newFrame.width, privacy: .public)×\(newFrame.height, privacy: .public)")
                },
                onResizeEnd: { [weak self] in
                    self?.viewModel.isUserResizing = false
                },
            ),
        )
        // Disable SwiftUI-driven window resizing (macOS 14+ default is .preferredContentSize).
        // Without this, NSHostingView resizes the panel whenever the SwiftUI preferred
        // content size changes — e.g. returning from chat to a long instances list whose
        // ScrollView ideal height exceeds the 320 pt target, expanding the window beyond
        // the size set by resizeDetachedPanelForContentType().
        // All resizing is handled explicitly via panel.setFrame() / panel.animator().setFrame().
        hostingView.sizingOptions = []
        panel.contentView = hostingView

        self.detachedPanel = panel
        self.detachedHostingView = hostingView

        // Fade the floating panel in instead of popping it on screen. NotchView's
        // opacity (docked ↔ detached) is animated on the SwiftUI side with a matching
        // duration, so the two surfaces crossfade and the handoff feels continuous.
        panel.alphaValue = 0
        panel.orderFront(nil)
        panel.makeKey()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        }

        // Hide the notch panel — NotchView opacity is driven by windowMode,
        // but we also need to stop the NotchPanel from receiving mouse events.
        // Do NOT call notchClose() here: changing contentType/status during a drag
        // triggers SwiftUI re-layout which causes jitter and feedback loops.
        //
        // Also clear `isContentActive`: `enablePassthroughBriefly` periodically
        // restores `ignoresMouseEvents = !isContentActive`, which would silently
        // re-enable mouse reception during detach and cause the transparent
        // NotchPanel overlay to repost (and cursor-warp) events on top of the
        // floating DetachedPanel.
        if let notchPanel = self.window as? NotchPanel {
            notchPanel.isContentActive = false
            notchPanel.ignoresMouseEvents = true
        }

        Self.logger.debug("Created detached panel")
    }

    func destroyDetachedPanel(animated: Bool) {
        guard let panel = self.detachedPanel else { return }

        // NotchDragController may still be tracking mouse events during the fade,
        // so disable header-drag pickup while we're tearing the panel down.
        panel.ignoresMouseEvents = true

        if animated {
            // Explicit snap-back (dock-back button, click-notch-while-detached).
            // Animate the panel back to the notch position while fading out.
            let targetRect = self.viewModel.geometry.openedScreenRect(for: self.viewModel.openedSize)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(targetRect, display: true)
                panel.animator().alphaValue = 0.0
            } completionHandler: { [weak self] in
                // Completion handler runs on the main thread but is declared nonisolated,
                // so hop to the main actor explicitly.
                Task(name: "finalize-destroy-detached") { @MainActor [weak self] in
                    self?.finalizeDestroyDetachedPanel()
                }
            }
        } else {
            // Drag-to-snap release. Crossfade against NotchView's matching 0.18s
            // opacity animation so we don't leave a 180ms blank spot where the
            // panel used to be.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 0.0
            } completionHandler: { [weak self] in
                Task(name: "finalize-destroy-detached-quick") { @MainActor [weak self] in
                    self?.finalizeDestroyDetachedPanel()
                }
            }
        }
    }

    func finalizeDestroyDetachedPanel() {
        self.detachedPanel?.close()
        self.detachedPanel = nil
        self.detachedHostingView = nil

        // Restore notch panel interaction — the NotchView becomes visible again
        // via windowMode == .docked opacity check. Status was never changed, so
        // the panel is still in .opened state with all content intact, meaning
        // `isContentActive` should be restored to `true` (mirrors the
        // `.opened` case in `setupStatusStream`).
        if self.viewModel.windowMode == .docked, let notchPanel = self.window as? NotchPanel {
            notchPanel.isContentActive = true
            notchPanel.ignoresMouseEvents = false
            notchPanel.makeKey()
        }

        Self.logger.debug("Destroyed detached panel")
    }

    func updateDetachedPanelPosition() {
        guard let panel = self.detachedPanel else { return }
        let origin = self.viewModel.detachedOrigin
        panel.setFrameOrigin(NSPoint(x: origin.x, y: origin.y))
    }
}
