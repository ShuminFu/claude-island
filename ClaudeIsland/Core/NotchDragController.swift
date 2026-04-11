//
//  NotchDragController.swift
//  ClaudeIsland
//
//  Manages the drag state machine for detaching the notch panel.
//  Uses local NSEvent monitors (separate from EventMonitors singleton)
//  to avoid consuming the single-consumer streams used by NotchViewModel.
//

import AppKit
import os.log

// MARK: - NotchDragController

/// Coordinates drag-to-detach gestures and magnetic snap-back.
/// Installs its own local NSEvent monitors for mouseDown, mouseDragged, mouseUp.
@MainActor
final class NotchDragController {
    // MARK: Lifecycle

    init(
        viewModel: NotchViewModel,
        getDetachedPanelFrame: @escaping () -> NSRect?,
        onCreateDetachedPanel: @escaping () -> Void,
        onDestroyDetachedPanel: @escaping () -> Void,
        onUpdateDetachedPanel: @escaping () -> Void,
    ) {
        self.viewModel = viewModel
        self.getDetachedPanelFrame = getDetachedPanelFrame
        self.onCreateDetachedPanel = onCreateDetachedPanel
        self.onDestroyDetachedPanel = onDestroyDetachedPanel
        self.onUpdateDetachedPanel = onUpdateDetachedPanel
        self.installMonitors()
    }

    deinit {
        // Capture monitors locally to remove from deinit (non-isolated context)
        let downMonitor = self.mouseDownMonitor
        let dragMonitor = self.mouseDraggedMonitor
        let upMonitor = self.mouseUpMonitor
        if let downMonitor { NSEvent.removeMonitor(downMonitor) }
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        if let upMonitor { NSEvent.removeMonitor(upMonitor) }
    }

    // MARK: Private

    nonisolated private static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "NotchDragController")

    /// Drag threshold in points before starting a detach
    private static let dragThreshold: CGFloat = 5

    /// Height of the detached panel's draggable header area. Matches
    /// `DetachedNotchView.headerHeight` — the single header row that carries the
    /// drag gesture, dock-back button, and menu toggle.
    private static let detachedHeaderHeight: CGFloat = 32

    private weak var viewModel: NotchViewModel?
    private let getDetachedPanelFrame: () -> NSRect?
    private let onCreateDetachedPanel: () -> Void
    private let onDestroyDetachedPanel: () -> Void
    private let onUpdateDetachedPanel: () -> Void

    /// Whether we are tracking a potential drag (mouse is down in header area)
    private var isTracking = false
    /// Screen location where the mouse first went down
    private var mouseDownLocation: CGPoint = .zero
    /// Offset from mouse to panel origin at drag start
    private var dragOffset: CGPoint = .zero
    /// Whether we are dragging the detached (floating) panel
    private var isDraggingDetachedPanel = false

    // Local event monitors (do not conflict with EventMonitors singleton)
    // nonisolated(unsafe) allows cleanup in deinit without Sendable issues
    nonisolated(unsafe) private var mouseDownMonitor: Any?
    nonisolated(unsafe) private var mouseDraggedMonitor: Any?
    nonisolated(unsafe) private var mouseUpMonitor: Any?

    // MARK: - Monitor Management

    private func installMonitors() {
        // Local monitors capture events within our app (needed when our panel is active).
        self.mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleMouseDown()
            }
            return event
        }

        self.mouseDraggedMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleMouseDragged(NSEvent.mouseLocation)
            }
            return event
        }

        self.mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleMouseUp()
            }
            return event
        }
    }

    private func removeMonitors() {
        if let monitor = self.mouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            self.mouseDownMonitor = nil
        }
        if let monitor = self.mouseDraggedMonitor {
            NSEvent.removeMonitor(monitor)
            self.mouseDraggedMonitor = nil
        }
        if let monitor = self.mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            self.mouseUpMonitor = nil
        }
    }

    // MARK: - Event Handlers

    private func handleMouseDown() {
        guard let vm = self.viewModel else { return }
        let location = NSEvent.mouseLocation

        switch vm.windowMode {
        case .docked:
            // Only start tracking if: unlocked, opened, and docked
            guard !vm.isLocked, vm.status == .opened else { return }

            // Check if mouse is in the opened panel header area (top ~40pt of the panel).
            // Uses a manual inclusive check instead of `CGRect.contains` so y = panelRect.maxY
            // (cursor flush against the very top of the screen, where macOS clamps it) still
            // counts as a valid drag start — `contains` uses a half-open interval on maxY and
            // would reject it otherwise.
            let panelRect = vm.geometry.openedScreenRect(for: vm.openedSize)
            let headerMinY = panelRect.maxY - 40
            guard location.x >= panelRect.minX,
                  location.x <= panelRect.maxX,
                  location.y >= headerMinY,
                  location.y <= panelRect.maxY
            else { return }

            self.isTracking = true
            self.isDraggingDetachedPanel = false
            self.mouseDownLocation = location
            self.dragOffset = CGPoint(
                x: location.x - panelRect.origin.x,
                y: location.y - panelRect.origin.y,
            )

        case .detached:
            // Check if mouse is in the detached panel's header area for dragging
            guard let panelFrame = self.getDetachedPanelFrame() else { return }
            let headerRect = CGRect(
                x: panelFrame.origin.x,
                y: panelFrame.maxY - Self.detachedHeaderHeight,
                width: panelFrame.width,
                height: Self.detachedHeaderHeight,
            )
            guard headerRect.contains(location) else { return }

            self.isTracking = true
            self.isDraggingDetachedPanel = true
            self.mouseDownLocation = location
            self.dragOffset = CGPoint(
                x: location.x - panelFrame.origin.x,
                y: location.y - panelFrame.origin.y,
            )

        case .detaching:
            break
        }
    }

    private func handleMouseDragged(_ location: CGPoint) {
        guard let vm = self.viewModel, self.isTracking else { return }

        switch vm.windowMode {
        case .docked:
            // Check if drag exceeds threshold
            let dx = location.x - self.mouseDownLocation.x
            let dy = location.y - self.mouseDownLocation.y
            let distance = sqrt(dx * dx + dy * dy)
            guard distance > Self.dragThreshold else { return }

            Self.logger.debug("Drag threshold exceeded, beginning detach")
            vm.beginDetach()
            // `beginDetach` silently returns when the view-model isn't eligible to
            // detach (locked, or status flipped to .closed between mouseDown and
            // mouseDragged — e.g. when the async global mouse-down stream delivers
            // `handleMouseDown` after our local monitor and closes the notch).
            // If the transition didn't happen, abort so we don't create an
            // orphan DetachedPanel while windowMode is still `.docked` (which
            // would leave the dock-back button wired to a no-op snapBackToNotch).
            guard vm.windowMode == .detaching else {
                Self.logger
                    .debug("beginDetach rejected (windowMode=\(String(describing: vm.windowMode), privacy: .public)) — aborting drag")
                self.isTracking = false
                return
            }
            self.onCreateDetachedPanel()

            // Sync with the actual created panel frame. The detached panel may be
            // offset from the docked panelRect (e.g., -dragHandleHeight in Y so the
            // header row stays under the cursor), so we recompute dragOffset and
            // seed vm.detachedOrigin from the real frame. Without this, the first
            // mouseDragged event in `.detaching` state would jump the panel by the
            // offset because dragOffset was computed against panelRect, not the
            // actual frame.
            if let detachedFrame = self.getDetachedPanelFrame() {
                self.dragOffset = CGPoint(
                    x: self.mouseDownLocation.x - detachedFrame.origin.x,
                    y: self.mouseDownLocation.y - detachedFrame.origin.y,
                )
                vm.detachedOrigin = detachedFrame.origin
            }

        case .detaching:
            vm.updateDetach(mouseLocation: location, dragOffset: self.dragOffset)
            self.onUpdateDetachedPanel()

        case .detached:
            guard self.isDraggingDetachedPanel else { return }
            // Move the detached panel and update snap zone indicator
            vm.detachedOrigin = CGPoint(
                x: location.x - self.dragOffset.x,
                y: location.y - self.dragOffset.y,
            )
            vm.isInSnapZone = vm.geometry.isInSnapZone(location)
            self.onUpdateDetachedPanel()
        }
    }

    private func handleMouseUp() {
        guard let vm = self.viewModel, self.isTracking else { return }
        self.isTracking = false

        let location = NSEvent.mouseLocation

        switch vm.windowMode {
        case .detaching:
            vm.endDetach(mouseLocation: location)
            if vm.windowMode == .docked {
                Self.logger.debug("Snapping back to notch (from detaching)")
                self.onDestroyDetachedPanel()
            } else {
                Self.logger.debug("Panel detached at (\(location.x, privacy: .public), \(location.y, privacy: .public))")
            }

        case .detached:
            guard self.isDraggingDetachedPanel else { return }
            self.isDraggingDetachedPanel = false

            if vm.geometry.isInSnapZone(location) {
                Self.logger.debug("Snapping back to notch (from detached)")
                vm.snapBackToNotch()
                self.onDestroyDetachedPanel()
            }
            vm.isInSnapZone = false

        case .docked:
            break
        }
    }
}
