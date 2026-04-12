//
//  ClaudeInstancesView.swift
//  ClaudeIsland
//
//  Minimal instances list matching Dynamic Island aesthetic
//

import AppKit
import SwiftUI

// MARK: - ClaudeInstancesView

struct ClaudeInstancesView: View {
    // MARK: Internal

    /// Session monitor is @Observable, so SwiftUI automatically tracks property access
    var sessionMonitor: ClaudeSessionMonitor

    /// View model is @Observable, so SwiftUI automatically tracks property access
    var viewModel: NotchViewModel

    var body: some View {
        Group {
            if self.sessionMonitor.instances.isEmpty {
                self.emptyState
            } else {
                self.instancesList
            }
        }
        .onAppear {
            self.sortedInstances = self.sessionMonitor.instances.sortedByPriority()
        }
        .onChange(of: self.sessionMonitor.instances) { _, newInstances in
            self.sortedInstances = newInstances.sortedByPriority()
        }
    }

    // MARK: Private

    // MARK: - Instances List

    /// Cached sorted instances — only recomputed when the source array changes,
    /// not on every body evaluation (decouples from viewModel property changes).
    @State private var sortedInstances: [SessionState] = []

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No sessions")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.4))

            Text("Run claude in terminal")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.25))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var instancesList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(self.sortedInstances) { session in
                        InstanceRow(
                            session: session,
                            isSelected: self.viewModel.isKeyboardNavigating
                                && self.viewModel.selectedInstanceID == session.stableID,
                            onFocus: { self.focusSession(session) },
                            onChat: { self.openChat(session) },
                            onArchive: { self.archiveSession(session) },
                            onApprove: { self.approveSession(session) },
                            onAlwaysAllow: { self.approveSessionAlways(session) },
                            onReject: { self.rejectSession(session) },
                            onHoverStart: { self.viewModel.isKeyboardNavigating = false },
                        )
                        .id(session.stableID)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: self.viewModel.selectedInstanceID) { _, newID in
                if let newID {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
        }
    }

    private func focusSession(_ session: SessionState) {
        Task(name: "focus-terminal") {
            var activated = false
            if let pid = session.pid {
                activated = await TerminalFocuser.shared.focusTerminal(forClaudePID: pid)
            }
            if !activated {
                activated = await TerminalFocuser.shared.focusTerminal(forWorkingDirectory: session.cwd)
            }

            // Flash the tab title to help user locate the correct tab
            if activated, AppSettings.enableTabFlashOnFocus {
                let tty = session.terminalTTY ?? session.tty
                if let tty {
                    await TerminalFocuser.shared.flashTabTitle(tty: tty, projectName: session.projectName)
                }
            }
        }
    }

    private func openChat(_ session: SessionState) {
        self.viewModel.showChat(for: session)
    }

    private func approveSession(_ session: SessionState) {
        self.sessionMonitor.approvePermission(sessionID: session.sessionID)
    }

    private func approveSessionAlways(_ session: SessionState) {
        self.sessionMonitor.approvePermissionAlways(sessionID: session.sessionID)
    }

    private func rejectSession(_ session: SessionState) {
        self.sessionMonitor.denyPermission(sessionID: session.sessionID, reason: nil)
    }

    private func archiveSession(_ session: SessionState) {
        self.sessionMonitor.archiveSession(sessionID: session.sessionID)
    }
}

// MARK: - InlineApprovalButtons

/// Compact inline approval buttons with staggered animation
struct InlineApprovalButtons: View {
    // MARK: Internal

    let onApprove: () -> Void
    let onAlwaysAllow: () -> Void
    let onReject: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            // Allow (once)
            Button {
                self.onApprove()
            } label: {
                HStack(spacing: 3) {
                    Text("a")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.black.opacity(0.4))
                    Text("Allow")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.black)
                }
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.9))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(self.showAllowButton ? 1 : 0)
            .scaleEffect(self.showAllowButton ? 1 : 0.8)

            // Always allow
            Button {
                self.onAlwaysAllow()
            } label: {
                HStack(spacing: 3) {
                    Text("s")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))
                    Text("Always")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.15))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(self.showAlwaysButton ? 1 : 0)
            .scaleEffect(self.showAlwaysButton ? 1 : 0.8)

            // Deny
            Button {
                self.onReject()
            } label: {
                HStack(spacing: 3) {
                    Text("d")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))
                    Text("Deny")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.1))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .opacity(self.showDenyButton ? 1 : 0)
            .scaleEffect(self.showDenyButton ? 1 : 0.8)
        }
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.0)) {
                self.showAllowButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                self.showAlwaysButton = true
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.1)) {
                self.showDenyButton = true
            }
        }
    }

    // MARK: Private

    @State private var showAllowButton = false
    @State private var showAlwaysButton = false
    @State private var showDenyButton = false
}

// MARK: - IconButton

struct IconButton: View {
    // MARK: Internal

    let icon: String
    let action: () -> Void

    var body: some View {
        Button {
            self.action()
        } label: {
            Image(systemName: self.icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(self.isHovered ? .white.opacity(0.8) : .white.opacity(0.4))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(self.isHovered ? Color.white.opacity(0.1) : Color.clear),
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { self.isHovered = $0 }
    }

    // MARK: Private

    @State private var isHovered = false
}

// MARK: - CompactTerminalButton

struct CompactTerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            if self.isEnabled {
                self.onTap()
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "terminal")
                    .font(.system(size: 8, weight: .medium))
                Text("Go to Terminal")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(self.isEnabled ? .white.opacity(0.9) : .white.opacity(0.3))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(self.isEnabled ? Color.white.opacity(0.15) : Color.white.opacity(0.05))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - TerminalButton

struct TerminalButton: View {
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            if self.isEnabled {
                self.onTap()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "terminal")
                    .font(.system(size: 9, weight: .medium))
                Text("Terminal")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(self.isEnabled ? .black : .white.opacity(0.4))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(self.isEnabled ? Color.white.opacity(0.95) : Color.white.opacity(0.1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Right Click Modifier

extension View {
    func onRightClick(perform action: @escaping () -> Void) -> some View {
        overlay {
            RightClickDetector(action: action)
        }
    }

    /// Like SwiftUI's `.onHover`, but uses an `.activeAlways` AppKit tracking area
    /// so events fire even when the host app is not active. Required for the
    /// detached panel: SwiftUI's `.onHover` only fires when the panel's app is the
    /// active app, so hover highlight + auto-mark-as-read break when the user is
    /// working in another app.
    func onAlwaysActiveHover(_ action: @escaping (Bool) -> Void) -> some View {
        background(AlwaysActiveHoverDetector(onChange: action))
    }
}

// MARK: - AlwaysActiveHoverDetector

struct AlwaysActiveHoverDetector: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context _: Context) -> AlwaysActiveHoverNSView {
        AlwaysActiveHoverNSView(onChange: self.onChange)
    }

    func updateNSView(_ nsView: AlwaysActiveHoverNSView, context _: Context) {
        nsView.onChange = self.onChange
    }
}

// MARK: - AlwaysActiveHoverNSView

final class AlwaysActiveHoverNSView: NSView {
    // MARK: Lifecycle

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Internal

    var onChange: (Bool) -> Void

    /// Only remove and re-add *our own* tracking area, mirroring `FirstMouseHostingView`.
    /// Storing the reference means we never accidentally remove tracking areas that
    /// SwiftUI or other subsystems installed on this view.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = self.hoverArea {
            self.removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: self.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil,
        )
        self.addTrackingArea(area)
        self.hoverArea = area
    }

    override func mouseEntered(with _: NSEvent) {
        self.onChange(true)
    }

    override func mouseExited(with _: NSEvent) {
        self.onChange(false)
    }

    /// Don't intercept clicks — this is purely a hover detector.
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    // MARK: Private

    private var hoverArea: NSTrackingArea?
}

// MARK: - RightClickDetector

struct RightClickDetector: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context _: Context) -> RightClickNSView {
        RightClickNSView(action: self.action)
    }

    func updateNSView(_ nsView: RightClickNSView, context _: Context) {
        nsView.action = self.action
    }
}

// MARK: - RightClickNSView

final class RightClickNSView: NSView {
    // MARK: Lifecycle

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Internal

    var action: () -> Void

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, self.monitor == nil else { return }

        self.monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, event.window == self.window else { return event }
            let locationInView = convert(event.locationInWindow, from: nil)

            if bounds.contains(locationInView) {
                self.action()
                return nil
            }
            return event
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    // MARK: Private

    private var monitor: Any?
}
