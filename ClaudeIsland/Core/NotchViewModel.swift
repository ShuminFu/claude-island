//
//  NotchViewModel.swift
//  ClaudeIsland
//
//  State management for the dynamic island
//

import AppKit
import Observation
import SwiftUI

// MARK: - NotchStatus

enum NotchStatus: Equatable {
    case closed
    case opened
    case popping
}

// MARK: - NotchOpenReason

enum NotchOpenReason {
    case click
    case hover
    case hotkey
    case notification
    case boot
    case unknown
}

// MARK: - NotchContentType

enum NotchContentType: Equatable {
    case instances
    case menu
    case chat(SessionState)

    // MARK: Internal

    var id: String {
        switch self {
        case .instances: "instances"
        case .menu: "menu"
        case let .chat(session): "chat-\(session.sessionID)"
        }
    }
}

// MARK: - ChatScrollCommand

enum ChatScrollCommand: Equatable {
    case stepUp
    case stepDown
    case jumpTop
    case jumpBottom
    case nextUserMessage
    case previousUserMessage
}

// MARK: - WindowMode

/// Window docking mode for the notch panel
enum WindowMode: Sendable, Equatable {
    case docked // Anchored in the notch (standard behavior)
    case detaching // Drag in progress, following mouse
    case detached // Independent floating window
}

// MARK: - NotchViewModel

/// State management for the dynamic island notch UI
/// Uses @Observable macro for efficient property-level change tracking (macOS 14+)
@Observable
final class NotchViewModel { // swiftlint:disable:this type_body_length
    // MARK: Lifecycle

    // MARK: - Initialization

    init(deviceNotchRect: CGRect, screenRect: CGRect, hasPhysicalNotch: Bool) {
        self.geometry = NotchGeometry(
            deviceNotchRect: deviceNotchRect,
            screenRect: screenRect,
        )
        self.hasPhysicalNotch = hasPhysicalNotch
        self.layoutEngine = ModuleLayoutEngine(registry: self.moduleRegistry)
        self.setupEventHandlers()
        self.observeSelectors()
    }

    // MARK: Internal

    var openReason: NotchOpenReason = .unknown
    var contentType: NotchContentType = .instances
    var isHovering = false

    // MARK: - Window Mode State

    /// Current window docking mode
    var windowMode: WindowMode = .docked {
        didSet {
            self.windowModeContinuation?.yield(self.windowMode)
        }
    }

    /// Whether the notch panel is locked in the notch (prevents dragging)
    var isLocked: Bool = AppSettings.isNotchLocked

    /// Whether the detached panel is within the magnetic snap radius
    var isInSnapZone = false

    /// Screen-coordinate origin for the detached panel during drag
    var detachedOrigin: CGPoint = .zero

    /// User-set size from interactive resize of the detached panel.
    /// Overrides the content-type default in `openedSize` while detached.
    /// Persists across content-type switches within a single detach session;
    /// cleared only when the panel is docked back via `snapBackToNotch()`.
    var detachedUserSize: CGSize?

    /// True while the user is actively dragging a resize handle.
    /// Suppresses the observation-driven `resizeDetachedPanelForContentType`
    /// animated resize so it doesn't fight the direct `panel.setFrame()` calls.
    var isUserResizing = false

    // MARK: - Keyboard Navigation State

    /// Selected instance stableID for keyboard navigation
    var selectedInstanceID: String?

    /// Whether keyboard navigation is active (shows selection highlight).
    /// Becomes true on first arrow key, false on mouse hover over any row.
    var isKeyboardNavigating = false

    /// When true, ChatView should NOT auto-focus its text input on appear.
    /// Set when entering chat via keyboard navigation (Vim "normal mode" behavior).
    /// ChatView reads this once on appear and resets it.
    var suppressChatInputFocus = false

    /// When true, ChatView should focus its text input (enter "insert mode").
    /// Set by Tab key in keyboard monitor. ChatView observes and resets.
    var requestChatInputFocus = false

    /// Signal for keyboard-driven chat scroll commands. ChatView observes and resets to nil.
    var chatScrollCommand: ChatScrollCommand?

    // MARK: - Geometry

    let geometry: NotchGeometry
    let spacing: CGFloat = 12
    let hasPhysicalNotch: Bool

    let moduleRegistry = ModuleRegistry.shared
    let layoutEngine: ModuleLayoutEngine

    /// Tracks selector expansion state changes to trigger view updates
    /// (With @Observable, views reading openedSize will observe this and re-compute when selectors change)
    private(set) var selectorUpdateToken: UInt = 0

    // MARK: - Observable State

    var status: NotchStatus = .closed {
        didSet {
            self.statusContinuation?.yield(self.status)
        }
    }

    var deviceNotchRect: CGRect {
        self.geometry.deviceNotchRect
    }

    var screenRect: CGRect {
        self.geometry.screenRect
    }

    /// Dynamic opened size based on content type
    /// Note: References selectorUpdateToken to ensure views re-compute when pickers expand/collapse
    var openedSize: CGSize {
        // Touch token to establish observation dependency
        _ = self.selectorUpdateToken

        // In detached mode, respect the user's manual resize override
        if self.windowMode == .detached, let userSize = self.detachedUserSize {
            return userSize
        }

        switch self.contentType {
        case .chat:
            // Large size for chat view
            return CGSize(
                width: min(self.screenRect.width * 0.5, 600),
                height: 580,
            )
        case .menu:
            // Compact size for settings menu
            return CGSize(
                width: min(self.screenRect.width * 0.4, 480),
                height: 500 + self.screenSelector.expandedPickerHeight + self.soundSelector.expandedPickerHeight + self.suppressionSelector
                    .expandedPickerHeight + self.clawdSelector.expandedPickerHeight,
            )
        case .instances:
            return CGSize(
                width: min(self.screenRect.width * 0.4, 480),
                height: 320,
            )
        }
    }

    // MARK: - Animation

    var animation: Animation {
        .easeOut(duration: 0.25)
    }

    /// Create a stream of status changes for use in non-SwiftUI contexts (e.g., window controllers).
    /// Single-consumer: calling again finishes the previous stream.
    /// Yields the current status immediately.
    func makeStatusStream() -> AsyncStream<NotchStatus> {
        // Finish any previous stream so its consumer doesn't hang
        self.statusContinuation?.finish()

        let (stream, continuation) = AsyncStream.makeStream(of: NotchStatus.self, bufferingPolicy: .bufferingNewest(1))
        self.statusContinuation = continuation
        continuation.onTermination = { [weak self] _ in
            Task(name: "status-stream-cleanup") { @MainActor [weak self] in
                self?.statusContinuation = nil
            }
        }
        // Yield current status immediately
        continuation.yield(self.status)
        return stream
    }

    // MARK: - Window Mode Stream

    /// Create a stream of window mode changes for use in non-SwiftUI contexts (e.g., window controllers).
    /// Single-consumer: calling again finishes the previous stream.
    /// Yields the current mode immediately.
    func makeWindowModeStream() -> AsyncStream<WindowMode> {
        self.windowModeContinuation?.finish()

        // bufferingNewest(1): only mode transitions (docked/detaching/detached) are consumed here.
        // Position updates go through @Observable (detachedOrigin) directly, so dropping
        // intermediate yields is safe.
        let (stream, continuation) = AsyncStream.makeStream(of: WindowMode.self, bufferingPolicy: .bufferingNewest(1))
        self.windowModeContinuation = continuation
        continuation.onTermination = { [weak self] _ in
            Task(name: "window-mode-stream-cleanup") { @MainActor [weak self] in
                self?.windowModeContinuation = nil
            }
        }
        continuation.yield(self.windowMode)
        return stream
    }

    // MARK: - Lock / Detach

    /// Toggle the lock state and persist to settings
    func toggleLock() {
        self.isLocked.toggle()
        AppSettings.isNotchLocked = self.isLocked
    }

    /// Begin detaching the panel (drag started past threshold).
    /// The detached panel starts at the notch's opened panel position.
    func beginDetach() {
        guard !self.isLocked, self.status == .opened else { return }
        let panelRect = self.geometry.openedScreenRect(for: self.openedSize)
        self.detachedOrigin = panelRect.origin
        self.windowMode = .detaching
    }

    /// Update detached panel position during drag
    func updateDetach(mouseLocation: CGPoint, dragOffset: CGPoint) {
        guard self.windowMode == .detaching else { return }
        self.detachedOrigin = CGPoint(
            x: mouseLocation.x - dragOffset.x,
            y: mouseLocation.y - dragOffset.y,
        )
        self.isInSnapZone = self.geometry.isInSnapZone(mouseLocation)
    }

    /// End detach: snap back if in snap zone, otherwise finalize detached state
    func endDetach(mouseLocation: CGPoint) {
        guard self.windowMode == .detaching else { return }
        if self.geometry.isInSnapZone(mouseLocation) {
            self.windowMode = .docked
            self.isInSnapZone = false
        } else {
            self.windowMode = .detached
            self.isInSnapZone = false
        }
    }

    /// Explicitly return to docked mode (e.g., clicking notch while detached)
    func snapBackToNotch() {
        guard self.windowMode == .detached || self.windowMode == .detaching else { return }
        self.isInSnapZone = false
        self.windowMode = .docked
        // Clear the user resize so the next detach starts at content-type defaults.
        self.detachedUserSize = nil
    }

    /// Reset keyboard selection state
    func resetKeyboardSelection() {
        self.selectedInstanceID = nil
        self.isKeyboardNavigating = false
    }

    func notchOpen(reason: NotchOpenReason = .unknown) {
        self.openReason = reason
        self.status = .opened

        // Don't restore chat on notification - show instances list instead
        if reason == .notification {
            self.currentChatSession = nil
            return
        }

        // Restore chat session if we had one open before
        if let chatSession = currentChatSession {
            // Avoid unnecessary updates if already showing this chat
            if case let .chat(current) = contentType, current.sessionID == chatSession.sessionID {
                return
            }
            self.contentType = .chat(chatSession)
        }
    }

    func notchClose() {
        // Save chat session before closing if in chat mode
        if case let .chat(session) = contentType {
            self.currentChatSession = session
        }
        self.resetKeyboardSelection()
        self.status = .closed
        self.contentType = .instances
    }

    func notchPop() {
        guard self.status == .closed, self.windowMode == .docked else { return }
        self.status = .popping
    }

    func notchUnpop() {
        guard self.status == .popping else { return }
        self.status = .closed
    }

    func toggleNotch() {
        if self.status == .opened {
            self.notchClose()
        } else {
            self.notchOpen(reason: .hotkey)
        }
    }

    func toggleMenu() {
        self.resetKeyboardSelection()
        self.detachedUserSize = nil
        self.contentType = self.contentType == .menu ? .instances : .menu
    }

    func showChat(for session: SessionState) {
        // Avoid unnecessary updates if already showing this chat
        if case let .chat(current) = contentType, current.sessionID == session.sessionID {
            return
        }
        // Preserve selectedInstanceID so we can restore highlight when returning to instances
        self.isKeyboardNavigating = false
        self.detachedUserSize = nil
        self.contentType = .chat(session)

        // Mark session as read when user opens chat
        if session.hasUnreadUpdate {
            Task(name: "mark-as-read") {
                await SessionStore.shared.process(.markAsRead(sessionID: session.sessionID))
            }
        }
    }

    /// Go back to instances list and restore keyboard selection highlight
    func exitChat() {
        self.currentChatSession = nil
        // Restore keyboard navigation highlight if we still have a selected instance
        // (selectedInstanceID was preserved when entering chat)
        self.isKeyboardNavigating = self.selectedInstanceID != nil
        self.detachedUserSize = nil
        self.contentType = .instances
    }

    /// Focus the terminal for the currently open chat session and close the notch
    private func focusTerminalForCurrentChat() {
        guard case let .chat(session) = contentType else { return }
        self.notchClose()
        Task(name: "focus-terminal-from-chat") {
            var activated = false
            if let pid = session.pid {
                activated = await TerminalFocuser.shared.focusTerminal(forClaudePID: pid)
            }
            if !activated {
                activated = await TerminalFocuser.shared.focusTerminal(forWorkingDirectory: session.cwd)
            }

            if activated, AppSettings.enableTabFlashOnFocus {
                let tty = session.terminalTTY ?? session.tty
                if let tty {
                    await TerminalFocuser.shared.flashTabTitle(tty: tty, projectName: session.projectName)
                }
            }
        }
    }

    /// Perform boot animation: expand briefly then collapse
    func performBootAnimation() {
        guard self.windowMode == .docked else { return }
        self.notchOpen(reason: .boot)
        self.bootAnimationTask?.cancel()
        self.bootAnimationTask = Task(name: "boot-animation") {
            try? await Task.sleep(for: .seconds(1.0))
            guard !Task.isCancelled, self.openReason == .boot else { return }
            self.notchClose()
        }
    }

    // MARK: - Keyboard Navigation

    /// Handle a keyboard event using the configured navigation style.
    /// Returns true if the event was consumed.
    /// Called from the local NSEvent monitor on the main thread.
    ///
    /// Spatial model (Apple "negative one screen"):
    ///   Menu ←── Instances List ──→ Chat
    func handleKeyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], sortedInstances: [SessionState]) -> Bool {
        let keymap = NavigationKeymap.keymap(for: AppSettings.navigationStyle)
        let action = keymap.action(for: keyCode)

        switch self.contentType {
        case .instances:
            guard let action else { return false }
            return self.handleInstancesAction(action, sortedInstances: sortedInstances)
        case .chat:
            return self.handleChatAction(action, keyCode: keyCode, modifiers: modifiers)
        case .menu:
            guard let action else { return false }
            return self.handleMenuAction(action)
        }
    }

    // MARK: Private

    // MARK: - Keyboard Navigation Helpers

    private func handleInstancesAction(_ action: NavigationAction, sortedInstances: [SessionState]) -> Bool {
        switch action {
        case .up:
            self.isKeyboardNavigating = true
            self.moveSelection(by: -1, in: sortedInstances)
            return true

        case .down:
            self.isKeyboardNavigating = true
            self.moveSelection(by: 1, in: sortedInstances)
            return true

        case .right, .confirm:
            // Navigate right → enter selected chat (suppress auto-focus for Vim normal mode)
            self.suppressChatInputFocus = true
            guard let selectedID = self.selectedInstanceID,
                  let session = sortedInstances.first(where: { $0.stableID == selectedID })
            else { return false }
            self.showChat(for: session)
            return true

        case .left:
            // Navigate left → menu
            self.toggleMenu()
            return true

        case .close:
            if self.windowMode == .detached {
                // In detached mode Escape snaps the panel back to the notch.
                // Calling notchClose() here would set status → .closed and tear
                // down the keyboard monitor while the floating panel is still
                // visible, leaving the UI in a broken state.
                self.snapBackToNotch()
            } else {
                self.notchClose()
            }
            return true
        }
    }

    private func handleChatAction(_ action: NavigationAction?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        // Navigation actions (from keymap)
        if let action {
            switch action {
            case .left, .close:
                self.exitChat()
                return true
            case .right, .confirm:
                self.focusTerminalForCurrentChat()
                return true
            case .up:
                self.chatScrollCommand = .stepUp
                return true
            case .down:
                self.chatScrollCommand = .stepDown
                return true
            }
        }

        // Chat-specific keys (not in navigation keymap)
        let hasShift = modifiers.contains(.shift)
        switch keyCode {
        case 5: // g key
            self.chatScrollCommand = hasShift ? .jumpBottom : .jumpTop
            return true
        case 45: // n key
            self.chatScrollCommand = hasShift ? .previousUserMessage : .nextUserMessage
            return true
        default:
            return false
        }
    }

    private func handleMenuAction(_ action: NavigationAction) -> Bool {
        switch action {
        case .right, .close:
            // Navigate right or back → return to instances
            self.resetKeyboardSelection()
            self.contentType = .instances
            return true
        default:
            return false
        }
    }

    private func moveSelection(by delta: Int, in sortedInstances: [SessionState]) {
        guard !sortedInstances.isEmpty else { return }

        if let currentID = self.selectedInstanceID,
           let currentIndex = sortedInstances.firstIndex(where: { $0.stableID == currentID }) {
            let newIndex = (currentIndex + delta + sortedInstances.count) % sortedInstances.count
            self.selectedInstanceID = sortedInstances[newIndex].stableID
        } else {
            // No selection yet — select first (down) or last (up)
            self.selectedInstanceID = delta > 0
                ? sortedInstances.first?.stableID
                : sortedInstances.last?.stableID
        }
    }

    private var statusContinuation: AsyncStream<NotchStatus>.Continuation?
    private var windowModeContinuation: AsyncStream<WindowMode>.Continuation?

    // MARK: - Dependencies

    private let screenSelector = ScreenSelector.shared
    private let soundSelector = SoundSelector.shared
    private let suppressionSelector = SuppressionSelector.shared
    private let clawdSelector = ClawdSelector.shared

    /// Task for mouse location stream
    @ObservationIgnored private var mouseLocationTask: Task<Void, Never>?
    /// Task for mouse down stream
    @ObservationIgnored private var mouseDownTask: Task<Void, Never>?
    private let events = EventMonitors.shared

    /// Task for hover delay before opening notch
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    /// Task for debounced hover-exit (prevents oscillation at boundaries)
    @ObservationIgnored private var hoverExitTask: Task<Void, Never>?
    /// Task for boot animation auto-close
    @ObservationIgnored private var bootAnimationTask: Task<Void, Never>?
    /// Task for reposting mouse clicks to windows behind us
    @ObservationIgnored private var repostClickTask: Task<Void, Never>?

    /// The chat session we're viewing (persists across close/open)
    private var currentChatSession: SessionState?

    /// Tracks whether observation loop is active
    @ObservationIgnored private var isObservingSelectors = false

    /// Whether we're in chat mode (sticky behavior)
    private var isInChatMode: Bool {
        if case .chat = self.contentType { return true }
        return false
    }

    private func observeSelectors() {
        // Use withObservationTracking to observe @Observable properties across objects
        self.startSelectorObservation()
    }

    private func startSelectorObservation() {
        guard !self.isObservingSelectors else { return }
        self.isObservingSelectors = true
        self.observeSelectorChanges()
    }

    private func observeSelectorChanges() {
        withObservationTracking {
            // Access the properties we want to observe
            _ = self.screenSelector.isPickerExpanded
            _ = self.soundSelector.isPickerExpanded
            _ = self.suppressionSelector.isPickerExpanded
            _ = self.clawdSelector.isColorPickerExpanded
        } onChange: { [weak self] in
            // Dispatch to main actor since onChange may be called from any context
            Task(name: "selector-change") { @MainActor [weak self] in
                self?.selectorUpdateToken &+= 1
                // Re-register for next change
                self?.observeSelectorChanges()
            }
        }
    }

    // MARK: - Event Handling

    private func setupEventHandlers() {
        // Mouse location stream with manual 50ms throttle
        let locationStream = self.events.makeMouseLocationStream()
        self.mouseLocationTask = Task(name: "mouse-location-stream") { [weak self] in
            let clock = ContinuousClock()
            var lastProcessed: ContinuousClock.Instant = .now - .milliseconds(50)
            for await location in locationStream {
                let now = clock.now
                guard now - lastProcessed >= .milliseconds(50) else { continue }
                lastProcessed = now
                self?.handleMouseMove(location)
            }
        }

        // Mouse down stream
        let mouseDownStream = self.events.makeMouseDownStream()
        self.mouseDownTask = Task(name: "mouse-down-stream") { [weak self] in
            for await _ in mouseDownStream {
                self?.handleMouseDown()
            }
        }
    }

    private func handleMouseMove(_ location: CGPoint) {
        // Skip hover-to-open when content is detached or being dragged
        guard self.windowMode == .docked else { return }

        let inNotch = self.geometry.isPointInNotch(location)
        let inOpened = self.status == .opened && self.geometry.isPointInOpenedPanel(location, size: self.openedSize)

        let newHovering = inNotch || inOpened

        if newHovering {
            // Immediately enter hover — cancel any pending exit debounce
            self.hoverExitTask?.cancel()
            self.hoverExitTask = nil

            guard !self.isHovering else { return }
            self.isHovering = true

            // Start hover timer to auto-expand after 1 second
            self.hoverTask?.cancel()
            if self.status == .closed || self.status == .popping {
                self.hoverTask = Task(name: "hover-expand") {
                    try? await Task.sleep(for: .seconds(1.0))
                    guard !Task.isCancelled, self.isHovering else { return }
                    self.notchOpen(reason: .hover)
                }
            }
        } else {
            // Debounce hover exit to prevent oscillation at boundaries.
            // When opened, also prevents rapid re-renders during the expand animation.
            guard self.isHovering, self.hoverExitTask == nil else { return }
            self.hoverTask?.cancel()
            self.hoverTask = nil
            self.hoverExitTask = Task(name: "hover-exit-debounce") {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                self.isHovering = false
                self.hoverExitTask = nil
            }
        }
    }

    private func handleMouseDown() {
        let location = NSEvent.mouseLocation

        // When detached, clicking the notch snaps the panel back.
        // First click only triggers snap-back; a second click triggers
        // the normal open/close path once the panel is docked again.
        if self.windowMode == .detached {
            if self.geometry.isPointInNotch(location) {
                self.snapBackToNotch()
            }
            return
        }

        // Skip normal handling during drag
        guard self.windowMode == .docked else { return }

        switch self.status {
        case .opened:
            if self.geometry.isPointOutsidePanel(location, size: self.openedSize) {
                self.notchClose()
                // Re-post the click so it reaches the window/app behind us
                self.repostClickAt(location)
            } else if self.geometry.notchScreenRect.contains(location) {
                // Clicking notch while opened - only close if NOT in chat mode.
                // When unlocked, the notch area overlaps the drag-to-detach
                // header, so the async global mouse-down handler was racing
                // `NotchDragController`'s synchronous tracking: `notchClose()`
                // could flip `status` to `.closed` before the drag crossed its
                // 5pt threshold, making `beginDetach()` reject and leaving the
                // detach flow in a broken state. Skip the auto-close while
                // unlocked — the user can still close via click-outside,
                // hotkey, or by dragging out.
                if !self.isInChatMode, self.isLocked {
                    self.notchClose()
                }
            }
        case .closed,
             .popping:
            if self.geometry.isPointInNotch(location) {
                self.notchOpen(reason: .click)
            }
        }
    }

    /// Re-posts a mouse click at the given screen location so it reaches windows behind us
    private func repostClickAt(_ location: CGPoint) {
        // Cancel any pending repost task
        self.repostClickTask?.cancel()
        // Small delay to let the window's ignoresMouseEvents update
        self.repostClickTask = Task(name: "repost-click") {
            try? await Task.sleep(for: .seconds(0.05))
            guard !Task.isCancelled else { return }

            // Convert to CGEvent coordinate system (screen coordinates with Y from top-left)
            guard let screen = NSScreen.main else { return }
            let screenHeight = screen.frame.height
            let cgPoint = CGPoint(x: location.x, y: screenHeight - location.y)

            // Create and post mouse down event
            if let mouseDown = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: cgPoint,
                mouseButton: .left,
            ) {
                mouseDown.post(tap: .cghidEventTap)
            }

            // Create and post mouse up event
            if let mouseUp = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: cgPoint,
                mouseButton: .left,
            ) {
                mouseUp.post(tap: .cghidEventTap)
            }
        }
    }
}
