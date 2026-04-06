//
//  RewindWatcher.swift
//  ClaudeIsland
//
//  Always-on file size monitor that detects JSONL truncation from /rewind.
//  Unlike JSONLInterruptWatcher (bound to processing phase), this runs for
//  the entire session lifetime since /rewind happens during waitingForInput.
//

import Foundation
import os.log

// MARK: - RewindWatcher

/// Monitors a session's JSONL file for truncation (file size decrease) caused by /rewind.
/// Only tracks file size via stat — never reads file content.
actor RewindWatcher {
    // MARK: Lifecycle

    init(sessionID: String, cwd: String, onTruncation: @escaping @Sendable (String, String) -> Void) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.onTruncation = onTruncation
        let projectDir = cwd.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        self.directoryPath = NSHomeDirectory() + "/.claude/projects/" + projectDir
        self.filePath = self.directoryPath + "/" + sessionID + ".jsonl"
    }

    deinit {
        if let source {
            source.cancel()
        }
        if let directorySource {
            directorySource.cancel()
        }
    }

    // MARK: Internal

    /// Start watching the JSONL file for truncation
    func start() {
        self.startWatching()
    }

    /// Stop watching
    func stop() {
        self.stopInternal()
    }

    // MARK: Private

    nonisolated private static let logger = Logger(subsystem: "com.engels74.ClaudeIsland", category: "Rewind")

    private let sessionID: String
    private let cwd: String
    private let filePath: String
    private let directoryPath: String
    private let onTruncation: @Sendable (String, String) -> Void

    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var directoryHandle: FileHandle?
    private var lastKnownSize: UInt64 = 0
    private var debounceTask: Task<Void, Never>?

    private func startWatching() {
        self.stopInternal()

        if FileManager.default.fileExists(atPath: self.filePath) {
            self.startFileWatcher()
        } else {
            self.startDirectoryWatcher()
        }
    }

    private func startFileWatcher() {
        guard let handle = FileHandle(forReadingAtPath: self.filePath) else {
            Self.logger.warning("Failed to open file: \(self.filePath, privacy: .public)")
            return
        }

        self.fileHandle = handle
        // Record initial size
        self.lastKnownSize = (try? handle.seekToEnd()) ?? 0

        let fd = handle.fileDescriptor
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .attrib],
            queue: .global(qos: .utility),
        )

        newSource.setEventHandler { [weak self] in
            guard let self else { return }
            Task(name: "rewind-check") { await self.checkForTruncation() }
        }

        newSource.setCancelHandler { [weak self] in
            guard let self else { return }
            Task(name: "rewind-cleanup-handle") { await self.cleanupFileHandle() }
        }

        self.source = newSource
        newSource.resume()

        Self.logger.debug("Started watching file: \(self.sessionID.prefix(8), privacy: .public)...")
    }

    private func startDirectoryWatcher() {
        guard FileManager.default.fileExists(atPath: self.directoryPath) else {
            Self.logger.warning("Directory doesn't exist: \(self.directoryPath, privacy: .public)")
            return
        }

        guard let handle = FileHandle(forReadingAtPath: self.directoryPath) else {
            Self.logger.warning("Failed to open directory: \(self.directoryPath, privacy: .public)")
            return
        }

        self.directoryHandle = handle
        let fd = handle.fileDescriptor

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write],
            queue: .global(qos: .utility),
        )

        newSource.setEventHandler { [weak self] in
            guard let self else { return }
            Task(name: "rewind-check-appearance") { await self.checkForFileAppearance() }
        }

        newSource.setCancelHandler { [weak self] in
            guard let self else { return }
            Task(name: "rewind-cleanup-dir") { await self.cleanupDirectoryHandle() }
        }

        self.directorySource = newSource
        newSource.resume()

        Self.logger.debug("Started watching directory for file: \(self.sessionID.prefix(8), privacy: .public)...")
    }

    private func checkForFileAppearance() {
        guard FileManager.default.fileExists(atPath: self.filePath) else { return }

        Self.logger.debug("File appeared, switching to file watcher: \(self.sessionID.prefix(8), privacy: .public)")

        if let existingDirSource = directorySource {
            existingDirSource.cancel()
            self.directorySource = nil
        }

        self.startFileWatcher()
    }

    /// Check file size on every DispatchSource event. If truncation is detected,
    /// fire the callback immediately (no debounce) since /rewind is a discrete user action.
    /// Normal growth just updates lastKnownSize for future comparison.
    private func checkForTruncation() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: self.filePath),
              let currentSize = attrs[.size] as? UInt64
        else {
            return
        }

        if currentSize < self.lastKnownSize {
            Self.logger.info(
                "Truncation detected for \(self.sessionID.prefix(8), privacy: .public): \(self.lastKnownSize) → \(currentSize)",
            )
            self.lastKnownSize = currentSize
            // Debounce the notification to coalesce rapid consecutive rewinds,
            // but the size comparison above always uses the latest lastKnownSize
            self.debounceTask?.cancel()
            self.debounceTask = Task(name: "rewind-debounce") {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                let sid = self.sessionID
                let cwd = self.cwd
                let callback = self.onTruncation
                callback(sid, cwd)
            }
        } else {
            self.lastKnownSize = currentSize
        }
    }

    private func cleanupFileHandle() {
        try? self.fileHandle?.close()
        self.fileHandle = nil
    }

    private func cleanupDirectoryHandle() {
        try? self.directoryHandle?.close()
        self.directoryHandle = nil
    }

    private func stopInternal() {
        self.debounceTask?.cancel()
        self.debounceTask = nil

        if let existingSource = source {
            existingSource.cancel()
            self.source = nil
        }
        if let existingDirSource = directorySource {
            existingDirSource.cancel()
            self.directorySource = nil
        }
        Self.logger.debug("Stopped watching: \(self.sessionID.prefix(8), privacy: .public)...")
    }
}
