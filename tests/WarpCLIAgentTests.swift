//
//  WarpCLIAgentTests.swift
//  ClaudeIslandTests
//
//  Tests for the Warp CLI Agent integration: settings <-> hook config
//  bridge + WarpNotificationMode wire-format mapping. The OSC 777 / key
//  synthesis paths in TerminalFocuser+Warp are exercised via integration
//  testing inside Warp; unit-level mocking of CGEvent buys little.
//

import Foundation
import Testing

@testable import Claude_Island

// MARK: - WarpNotificationMode wire format

@Suite("WarpNotificationMode hook-config encoding")
struct WarpNotificationModeWireFormatTests {
    @Test("Each mode encodes to the exact string the Python hook expects")
    func hookConfigValuesMatchPythonContract() {
        // Python's `should_emit_warp_cli_agent` checks for "island-only"
        // and `_load_hook_config` reads "warpCLIAgentMode". Any drift here
        // silently breaks the integration.
        #expect(WarpNotificationMode.both.hookConfigValue == "both")
        #expect(WarpNotificationMode.warpOnly.hookConfigValue == "warp-only")
        #expect(WarpNotificationMode.islandOnly.hookConfigValue == "island-only")
    }

    @Test("All cases have non-empty descriptions for the Picker UI")
    func descriptionsArePresent() {
        for mode in WarpNotificationMode.allCases {
            #expect(!mode.description.isEmpty, "mode \(mode.rawValue) is missing a description")
        }
    }
}

// MARK: - HookConfigWriter end-to-end

/// Snapshot/restore wrapper for state that HookConfigWriter mutates.
/// Tests run against the real user's `~/.claude/` — leaking changes would
/// silently flip a developer's actual Warp integration mode, so every test
/// must restore both the AppSettings keys AND the on-disk config file.
private struct HookConfigBackup {
    let originalEnabled: Bool
    let originalMode: WarpNotificationMode
    let originalFileData: Data?

    init() {
        self.originalEnabled = AppSettings.warpCLIAgentEnabled
        self.originalMode = AppSettings.warpCLIAgentNotificationMode
        self.originalFileData = try? Data(contentsOf: HookConfigWriter.configURL)
    }

    func restore() {
        AppSettings.warpCLIAgentEnabled = self.originalEnabled
        AppSettings.warpCLIAgentNotificationMode = self.originalMode
        if let data = self.originalFileData {
            try? data.write(to: HookConfigWriter.configURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: HookConfigWriter.configURL)
        }
    }
}

@Suite("HookConfigWriter persists AppSettings → JSON file Python reads")
struct HookConfigWriterTests {
    @Test("persist() writes a JSON file containing the current AppSettings")
    func persistWritesCurrentSettings() throws {
        let backup = HookConfigBackup()
        defer { backup.restore() }

        AppSettings.warpCLIAgentEnabled = true
        AppSettings.warpCLIAgentNotificationMode = .warpOnly

        // The setter calls persist() automatically, but call again to make
        // the test explicit about what's under test.
        HookConfigWriter.persist()

        let url = HookConfigWriter.configURL
        let data = try Data(contentsOf: url)
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "config file should be a JSON object",
        )

        #expect(json["warpCLIAgentEnabled"] as? Bool == true)
        #expect(json["warpCLIAgentMode"] as? String == "warp-only")
        #expect(json["schemaVersion"] as? Int == 1)
    }

    @Test("Mode .islandOnly produces the value Python parses as opt-out")
    func islandOnlyModeMapsToOptOutString() throws {
        let backup = HookConfigBackup()
        defer { backup.restore() }

        AppSettings.warpCLIAgentNotificationMode = .islandOnly
        HookConfigWriter.persist()

        let data = try Data(contentsOf: HookConfigWriter.configURL)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Must equal exactly "island-only" — the Python gate string-compares.
        #expect(json["warpCLIAgentMode"] as? String == "island-only")
    }

    @Test("remove() deletes the config file and is safe to call when absent")
    func removeIsIdempotent() throws {
        let backup = HookConfigBackup()
        defer { backup.restore() }

        HookConfigWriter.persist() // ensure it exists
        HookConfigWriter.remove()
        #expect(!FileManager.default.fileExists(atPath: HookConfigWriter.configURL.path))

        // Second remove must not throw — mirrors the production "uninstall
        // when nothing is installed" path.
        HookConfigWriter.remove()
        #expect(!FileManager.default.fileExists(atPath: HookConfigWriter.configURL.path))
    }
}
