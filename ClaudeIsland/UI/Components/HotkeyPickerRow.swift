//
//  HotkeyPickerRow.swift
//  ClaudeIsland
//
//  Global hotkey configuration row for settings menu
//

import SwiftUI

// MARK: - HotkeyPickerRow

struct HotkeyPickerRow: View {
    // MARK: Internal

    var body: some View {
        VStack(spacing: 0) {
            // Main row - shows current shortcut
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.isExpanded.toggle()
                    if !self.isExpanded {
                        self.hotkeyManager.stopRecording()
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 12))
                        .foregroundColor(self.textColor)
                        .frame(width: 16)

                    Text("Global Hotkey")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(self.textColor)

                    Spacer()

                    if self.hotkeyEnabled, let shortcut = self.currentShortcut {
                        Text(shortcut.displayString)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.5))
                    } else {
                        Text("Off")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.3))
                    }

                    Image(systemName: self.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(self.isHovered || self.isExpanded ? Color.white.opacity(0.08) : Color.clear),
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { self.isHovered = $0 }

            // Expanded settings
            if self.isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    // Enable/disable toggle
                    Toggle(isOn: self.$hotkeyEnabled) {
                        Text("Enabled")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .onChange(of: self.hotkeyEnabled) { _, newValue in
                        AppSettings.globalHotkeyEnabled = newValue
                        self.hotkeyManager.refresh()
                    }

                    if self.hotkeyEnabled {
                        // Current shortcut display + record button
                        HStack(spacing: 8) {
                            if self.hotkeyManager.isRecording {
                                // Recording state
                                Text("Press keys...")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(TerminalColors.amber)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(TerminalColors.amber.opacity(0.6), lineWidth: 1),
                                    )

                                Button("Cancel") {
                                    self.hotkeyManager.stopRecording()
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.5))
                                .buttonStyle(.plain)
                            } else {
                                // Display current + record button
                                if let shortcut = self.currentShortcut {
                                    Text(shortcut.displayString)
                                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.8))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(Color.white.opacity(0.06)),
                                        )
                                }

                                Button("Record") {
                                    self.hotkeyManager.startRecording()
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(Color.white.opacity(0.9)),
                                )
                                .buttonStyle(.plain)

                                Button("Reset") {
                                    self.currentShortcut = .default
                                    AppSettings.globalHotkey = .default
                                    self.hotkeyManager.refresh()
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.5))
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 28)
                .padding(.trailing, 28)
                .padding(.vertical, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear {
            self.currentShortcut = AppSettings.globalHotkey
            self.hotkeyEnabled = AppSettings.globalHotkeyEnabled
            self.hotkeyManager.onShortcutRecorded = { shortcut in
                self.currentShortcut = shortcut
            }
        }
        .onDisappear {
            self.hotkeyManager.stopRecording()
        }
    }

    // MARK: Private

    @State private var isExpanded = false
    @State private var isHovered = false
    @State private var currentShortcut: GlobalKeyboardShortcut? = AppSettings.globalHotkey
    @State private var hotkeyEnabled: Bool = AppSettings.globalHotkeyEnabled

    private var hotkeyManager = GlobalHotkeyManager.shared

    private var textColor: Color {
        .white.opacity(self.isHovered || self.isExpanded ? 1.0 : 0.7)
    }
}
