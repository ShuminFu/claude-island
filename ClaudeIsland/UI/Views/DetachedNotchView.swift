//
//  DetachedNotchView.swift
//  ClaudeIsland
//
//  SwiftUI view for the detached (floating) notch panel.
//  Shares the same NotchViewModel as NotchView for content sync.
//

import AppKit
import os.log
import SwiftUI

// MARK: - DetachedNotchView

struct DetachedNotchView: View {
    // MARK: Lifecycle

    init(
        viewModel: NotchViewModel,
        onDrag: @escaping (CGPoint) -> Void,
        onDragEnd: @escaping (CGPoint) -> Void,
    ) {
        self.viewModel = viewModel
        self.onDrag = onDrag
        self.onDragEnd = onDragEnd
    }

    // MARK: Internal

    nonisolated static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "DetachedNotchView")

    /// Height of the header row that carries the drag gesture and dock-back / menu buttons.
    /// This row replaces the standalone drag handle strip — its size now matches the notch's
    /// closed header so the detached and docked layouts share the same total height.
    static let headerHeight: CGFloat = 32

    var viewModel: NotchViewModel
    let onDrag: (CGPoint) -> Void
    let onDragEnd: (CGPoint) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header row: drag gesture on the background, pill affordance in the middle,
            // buttons layered on top to intercept their own taps first.
            ZStack {
                // Drag-eligible background. Color.clear with contentShape(Rectangle())
                // catches mouse events outside the buttons. SwiftUI dispatches taps to
                // child views first, so button clicks are not swallowed by this gesture.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(self.dragGesture)

                // Visual pill — centered, non-interactive so it never blocks hit-testing
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 32, height: 3)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 6)
                    .allowsHitTesting(false)

                // Dock-back / menu buttons on top
                self.headerRow
                    .padding(.horizontal, 12)
            }
            .frame(height: Self.headerHeight)

            // Main content
            self.contentView
                .frame(width: self.viewModel.openedSize.width - 24)
                .padding(.bottom, 12)
        }
        .frame(
            width: self.viewModel.openedSize.width,
            height: self.viewModel.openedSize.height + Self.headerHeight,
            alignment: .top,
        )
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1),
        )
        .preferredColorScheme(.dark)
        .onAppear {
            self.sessionMonitor.startMonitoring()
        }
    }

    // MARK: Private

    @State private var sessionMonitor = ClaudeSessionMonitor()
    @State private var dragStartOrigin: CGPoint?
    @State private var dragStartMouse: CGPoint?

    /// Drag gesture for moving the detached panel.
    /// Reads the current mouse location via `NSEvent.mouseLocation` so we get
    /// AppKit screen coordinates (Y up) directly, avoiding any conversion from
    /// SwiftUI's global coordinate space (Y down).
    ///
    /// This bypasses the NSEvent local-monitor path in `NotchDragController`,
    /// which is unreliable for clicks on a `.nonactivatingPanel` host view.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { _ in
                let mouseLocation = NSEvent.mouseLocation
                if self.dragStartOrigin == nil {
                    // Capture the panel's starting origin and the mouse anchor on the
                    // first event of the drag, then wait for actual movement.
                    self.dragStartOrigin = self.viewModel.detachedOrigin
                    self.dragStartMouse = mouseLocation
                    return
                }
                guard let startOrigin = self.dragStartOrigin,
                      let startMouse = self.dragStartMouse
                else { return }
                let dx = mouseLocation.x - startMouse.x
                let dy = mouseLocation.y - startMouse.y
                let newOrigin = CGPoint(x: startOrigin.x + dx, y: startOrigin.y + dy)
                self.viewModel.detachedOrigin = newOrigin
                self.viewModel.isInSnapZone = self.viewModel.geometry.isInSnapZone(mouseLocation)
                self.onDrag(newOrigin)
            }
            .onEnded { _ in
                let mouseLocation = NSEvent.mouseLocation
                self.dragStartOrigin = nil
                self.dragStartMouse = nil
                self.viewModel.isInSnapZone = false
                self.onDragEnd(mouseLocation)
            }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            // Clawd icon on left
            ClaudeCrabIcon(
                size: 14,
                color: AppSettings.clawdColor,
                animateLegs: false,
            )

            Spacer()

            // Dock back button (arrow icon snaps back to notch).
            // We use .onTapGesture rather than Button because SwiftUI Buttons
            // inside a .nonactivatingPanel can swallow the first click while
            // the panel is becoming key — tap gestures dispatch reliably.
            Image(systemName: "arrow.up.to.line")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .onTapGesture {
                    self.viewModel.snapBackToNotch()
                }
                .help("Dock back to notch")

            // Menu toggle.
            // The `.easeInOut(duration: 0.3)` here is deliberately paired with
            // the matching `NSAnimationContext` curve used by the controller's
            // `resizeDetachedPanelForContentType`. SwiftUI's `.easeInOut` maps
            // to the same cubic bezier `(0.42, 0, 0.58, 1.0)` that Core
            // Animation's `.easeInEaseOut` uses, so the SwiftUI `.frame`
            // animation and the NSWindow frame animation trace identical
            // curves over the same duration and the top edge stays locked.
            // A spring curve (what the docked notch uses) has no bezier
            // equivalent for NSWindow frame animations — the two sides would
            // drift and the top would tear mid-flight.
            Image(systemName: self.viewModel.contentType == .menu ? "xmark" : "line.3.horizontal")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        self.viewModel.toggleMenu()
                    }
                }
        }
    }

    private var contentView: some View {
        Group {
            switch self.viewModel.contentType {
            case .instances:
                ClaudeInstancesView(
                    sessionMonitor: self.sessionMonitor,
                    viewModel: self.viewModel,
                )
            case .menu:
                NotchMenuView(viewModel: self.viewModel)
            case let .chat(session):
                ChatView(
                    sessionID: session.sessionID,
                    initialSession: session,
                    sessionMonitor: self.sessionMonitor,
                    viewModel: self.viewModel,
                )
            }
        }
    }
}
