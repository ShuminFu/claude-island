//
//  NotchViewController.swift
//  ClaudeIsland
//
//  Hosts the SwiftUI NotchView in AppKit with click-through support
//

import AppKit
import SwiftUI

// MARK: - NotchViewController

class NotchViewController: NSViewController {
    // MARK: Lifecycle

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Internal

    override func loadView() {
        // The NotchPanel is resized to exactly the visible content rect when opening,
        // so the window boundaries themselves limit which clicks reach Claude Island.
        // No custom hit-test rect needed.
        view = NSHostingView(rootView: NotchView(viewModel: self.viewModel))
    }

    // MARK: Private

    private let viewModel: NotchViewModel
}
