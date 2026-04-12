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

// MARK: - ResizeDirection

/// Resize edges and corners available on the detached panel.
/// The top edge is intentionally omitted — the header strip already owns that
/// area as a window-drag target and adding a resize zone there would conflict.
private enum ResizeDirection {
    case south, east, west, southEast, southWest

    /// Cursor pushed while hovering.
    /// `NSCursor.push/pop` rather than cursor rects: push/pop survives `makeKey()`
    /// calls (which invalidate cursor rects), so the cursor stays correct while dragging
    /// even after the panel becomes key on first click.
    var cursor: NSCursor {
        switch self {
        case .south: return .resizeUpDown
        case .east, .west: return .resizeLeftRight
        case .southEast, .southWest:
            // No public diagonal cursor — crosshair clearly signals "drag freely here"
            return .crosshair
        }
    }

    private static let minWidth: CGFloat = 320
    private static let minHeight: CGFloat = 232  // 200pt content + 32pt header

    /// Compute the new window frame given the mouse delta from `startFrame`.
    /// Axis: AppKit screen coordinates (Y increases upward).
    /// dy < 0 when the cursor moves downward.
    func newFrame(from start: NSRect, dx: CGFloat, dy: CGFloat) -> NSRect {
        let minW = Self.minWidth
        let minH = Self.minHeight
        switch self {
        case .south:
            // Top (maxY) fixed; bottom (minY) moves.  dy < 0 ⟹ taller.
            let newH = max(minH, start.height - dy)
            return NSRect(x: start.minX, y: start.maxY - newH, width: start.width, height: newH)
        case .east:
            let newW = max(minW, start.width + dx)
            return NSRect(x: start.minX, y: start.minY, width: newW, height: start.height)
        case .west:
            let newW = max(minW, start.width - dx)
            return NSRect(x: start.maxX - newW, y: start.minY, width: newW, height: start.height)
        case .southEast:
            let newW = max(minW, start.width + dx)
            let newH = max(minH, start.height - dy)
            return NSRect(x: start.minX, y: start.maxY - newH, width: newW, height: newH)
        case .southWest:
            let newW = max(minW, start.width - dx)
            let newH = max(minH, start.height - dy)
            return NSRect(x: start.maxX - newW, y: start.maxY - newH, width: newW, height: newH)
        }
    }
}

// MARK: - ResizeHandle

/// Transparent hit-area view for a single resize edge or corner.
///
/// Cursor management uses `NSCursor.push/pop` so the resize cursor survives
/// the `makeKey()` call triggered by `FirstMouseHostingView.mouseEntered`.
/// When the cursor exits the hit area mid-drag we skip the pop and defer it
/// to `onEnded`, keeping the cursor stable for the lifetime of the drag.
private struct ResizeHandle: View {
    // MARK: Lifecycle

    init(
        direction: ResizeDirection,
        showsGripIndicator: Bool = false,
        currentPanelFrame: @escaping () -> NSRect?,
        onResize: @escaping (NSRect) -> Void,
        onResizeEnd: @escaping () -> Void = {},
    ) {
        self.direction = direction
        self.showsGripIndicator = showsGripIndicator
        self.currentPanelFrame = currentPanelFrame
        self.onResize = onResize
        self.onResizeEnd = onResizeEnd
    }

    // MARK: Internal

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering, !self.isCursorPushed {
                        self.direction.cursor.push()
                        self.isCursorPushed = true
                    } else if !hovering, self.dragState == nil, self.isCursorPushed {
                        NSCursor.pop()
                        self.isCursorPushed = false
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { _ in
                            let mouse = NSEvent.mouseLocation
                            if self.dragState == nil {
                                guard let frame = self.currentPanelFrame() else { return }
                                self.dragState = DragState(startFrame: frame, startMouse: mouse)
                                return
                            }
                            guard let state = self.dragState else { return }
                            let dx = mouse.x - state.startMouse.x
                            let dy = mouse.y - state.startMouse.y
                            self.onResize(self.direction.newFrame(from: state.startFrame, dx: dx, dy: dy))
                        }
                        .onEnded { _ in
                            self.dragState = nil
                            self.onResizeEnd()
                            if self.isCursorPushed {
                                NSCursor.pop()
                                self.isCursorPushed = false
                            }
                        },
                )

            if self.showsGripIndicator {
                self.gripLines.allowsHitTesting(false)
            }
        }
    }

    // MARK: Private

    private struct DragState {
        let startFrame: NSRect
        let startMouse: NSPoint
    }

    private let direction: ResizeDirection
    private let showsGripIndicator: Bool
    private let currentPanelFrame: () -> NSRect?
    private let onResize: (NSRect) -> Void
    private let onResizeEnd: () -> Void

    @State private var dragState: DragState?
    @State private var isCursorPushed = false

    /// SE-corner diagonal-line indicator. Four `/`-oriented parallel lines
    /// that connect the bottom edge to the right edge of the canvas, stacked
    /// toward the corner — matching the classic macOS grow-box style.
    private var gripLines: some View {
        Canvas { ctx, size in
            for i in 2 ..< 4 {
                let offset = CGFloat(i + 1) * 4.5
                let start = CGPoint(x: size.width - offset, y: size.height - 2)
                let end = CGPoint(x: size.width - 2, y: size.height - offset)
                var path = Path()
                path.move(to: start)
                path.addLine(to: end)
                ctx.stroke(path, with: .color(.white.opacity(0.3)), lineWidth: 1.5)
            }
        }
    }
}

// MARK: - DetachedNotchView

struct DetachedNotchView: View {
    // MARK: Lifecycle

    init(
        viewModel: NotchViewModel,
        currentPanelOrigin: @escaping () -> CGPoint?,
        currentPanelFrame: @escaping () -> NSRect?,
        onDrag: @escaping (CGPoint) -> Void,
        onDragEnd: @escaping (CGPoint) -> Void,
        onResizeGrip: @escaping (NSRect) -> Void,
        onResizeEnd: @escaping () -> Void,
    ) {
        self.viewModel = viewModel
        self.currentPanelOrigin = currentPanelOrigin
        self.currentPanelFrame = currentPanelFrame
        self.onDrag = onDrag
        self.onDragEnd = onDragEnd
        self.onResizeGrip = onResizeGrip
        self.onResizeEnd = onResizeEnd
    }

    // MARK: Internal

    nonisolated static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "DetachedNotchView")

    /// Height of the header row that carries the drag gesture and dock-back / menu buttons.
    static let headerHeight: CGFloat = 32

    var viewModel: NotchViewModel
    let currentPanelOrigin: () -> CGPoint?
    let currentPanelFrame: () -> NSRect?
    let onDrag: (CGPoint) -> Void
    let onDragEnd: (CGPoint) -> Void
    let onResizeGrip: (NSRect) -> Void
    let onResizeEnd: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header row: drag gesture on the background, pill affordance in the middle,
            // buttons layered on top to intercept their own taps first.
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(self.dragGesture)

                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 32, height: 3)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 6)
                    .allowsHitTesting(false)

                self.headerRow
                    .padding(.horizontal, 12)
            }
            .frame(height: Self.headerHeight)
            .background(Color.black)
            .zIndex(1)

            self.contentView
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        // Use a fixed frame at the target size so SwiftUI lays out content
        // exactly once per content-type switch. Without this, the 0.3s NSWindow
        // resize animation continuously changes the hosting view bounds, causing
        // SwiftUI to re-layout ChatView/ScrollView at every intermediate size
        // (~18 passes at 60 fps) — visible as stutter. With a fixed frame,
        // SwiftUI sees an unchanged proposal on each animation tick and skips
        // descendant layout. The window clips the content during the animation
        // and progressively reveals it (a "Dynamic Island unfold" effect).
        .frame(
            width: self.viewModel.openedSize.width,
            height: self.viewModel.openedSize.height + Self.headerHeight,
            alignment: .top
        )
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1),
        )
        // Resize handles sit in an overlay AFTER clipShape so they are not clipped
        // and cover the full rectangular window frame (including rounded-corner zones).
        .overlay { self.resizeHandleOverlay }
        .preferredColorScheme(.dark)
        .onAppear {
            self.sessionMonitor.startMonitoring()
        }
    }

    // MARK: Private

    @State private var sessionMonitor = ClaudeSessionMonitor()
    @State private var dragStartOrigin: CGPoint?
    @State private var dragStartMouse: CGPoint?

    // MARK: - Resize handle overlay

    /// Five handles cover all user-reachable resize directions.
    /// Top-edge resize is omitted because the header strip is a drag target there.
    /// Corners are placed last (highest z-index) so they take priority over the
    /// edge handles in the overlap zone at each bottom corner.
    private var resizeHandleOverlay: some View {
        let edge: CGFloat = 10      // hit-area thickness for edge handles
        let corner: CGFloat = 20    // hit-area side length for corner handles

        return ZStack {
            // Bottom edge
            ResizeHandle(direction: .south, currentPanelFrame: self.currentPanelFrame, onResize: self.onResizeGrip, onResizeEnd: self.onResizeEnd)
                .frame(height: edge)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            // Right edge
            ResizeHandle(direction: .east, currentPanelFrame: self.currentPanelFrame, onResize: self.onResizeGrip, onResizeEnd: self.onResizeEnd)
                .frame(width: edge)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)

            // Left edge
            ResizeHandle(direction: .west, currentPanelFrame: self.currentPanelFrame, onResize: self.onResizeGrip, onResizeEnd: self.onResizeEnd)
                .frame(width: edge)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            // SW corner (above edges in z-order)
            ResizeHandle(direction: .southWest, currentPanelFrame: self.currentPanelFrame, onResize: self.onResizeGrip, onResizeEnd: self.onResizeEnd)
                .frame(width: corner, height: corner)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

            // SE corner with diagonal-line visual (highest z-order)
            ResizeHandle(direction: .southEast, showsGripIndicator: true, currentPanelFrame: self.currentPanelFrame, onResize: self.onResizeGrip, onResizeEnd: self.onResizeEnd)
                .frame(width: corner, height: corner)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }

    // MARK: - Drag gesture (window move)

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { _ in
                let mouseLocation = NSEvent.mouseLocation
                if self.dragStartOrigin == nil {
                    self.dragStartOrigin = self.currentPanelOrigin() ?? self.viewModel.detachedOrigin
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

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            ClaudeCrabIcon(
                size: 14,
                color: AppSettings.clawdColor,
                animateLegs: false,
            )

            Spacer()

            Image(systemName: "arrow.up.to.line")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .onTapGesture {
                    self.viewModel.snapBackToNotch()
                }
                .help("Dock back to notch")

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

    // MARK: - Content

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
        .animation(nil, value: self.viewModel.contentType)
    }
}
