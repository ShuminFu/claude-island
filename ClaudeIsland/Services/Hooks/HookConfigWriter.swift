//
//  HookConfigWriter.swift
//  ClaudeIsland
//
//  Bridges AppSettings → ~/.claude/.claude-island-hook-config.json so the
//  Python hook can read user-controlled flags (currently: Warp CLI Agent
//  notification mode + master enable). The file is rewritten whenever a
//  relevant AppSettings property changes.
//

import Foundation
import os

// MARK: - HookConfigWriter

enum HookConfigWriter {
    // MARK: Internal

    /// Path the Python hook polls. Lives next to settings.json so users who
    /// `cat` ~/.claude/ to debug can see it. The leading dot is intentional —
    /// it's machine state, not user-editable config.
    static let configURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude")
        .appendingPathComponent(".claude-island-hook-config.json")

    /// Snapshot current AppSettings → JSON file. Idempotent. Safe to call
    /// from any actor (UserDefaults reads + atomic-write).
    static func persist() {
        let payload: [String: Any] = [
            "warpCLIAgentEnabled": AppSettings.warpCLIAgentEnabled,
            "warpCLIAgentMode": AppSettings.warpCLIAgentNotificationMode.hookConfigValue,
            // Schema version — bump when adding incompatible fields so the
            // Python side can branch on it. Currently unused but cheap.
            "schemaVersion": 1,
        ]

        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys],
        )
        else {
            Self.logger.error("Failed to serialize hook config payload")
            return
        }

        let dir = self.configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        do {
            try FileManager.default.atomicWrite(data, to: self.configURL)
            Self.logger.debug("Hook config written: \(self.configURL.path, privacy: .public)")
        } catch {
            Self.logger.error("Failed to write hook config: \(error.localizedDescription)")
        }
    }

    /// Remove the config file (called on hook uninstall to leave $HOME clean).
    static func remove() {
        try? FileManager.default.removeItem(at: self.configURL)
    }

    // MARK: Private

    nonisolated private static let logger = Logger(
        subsystem: "com.engels74.ClaudeIsland",
        category: "HookConfigWriter",
    )
}
