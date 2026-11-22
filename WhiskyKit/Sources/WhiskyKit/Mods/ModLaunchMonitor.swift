//
//  ModLaunchMonitor.swift
//  WhiskyKit
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import Foundation

/// How far a Steam game launch has got, read from the logs each stage leaves.
public struct LaunchProgress: Equatable, Sendable {
    public enum Stage: Int, CaseIterable, Sendable, Comparable {
        case steam, launch, mod, window, done
        public static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var stage: Stage
    /// Mods loaded so far and in total, while BepInEx is loading them.
    public var pluginsLoaded = 0
    public var pluginsTotal = 0

    public init(stage: Stage, pluginsLoaded: Int = 0, pluginsTotal: Int = 0) {
        self.stage = stage
        self.pluginsLoaded = pluginsLoaded
        self.pluginsTotal = pluginsTotal
    }
}

/// Watches a Steam game start: Steam signing in, Steam starting the game,
/// BepInEx loading the mod, and the game reaching its menu.
///
/// Every stage is read from a file the stage writes, so the screen shows what
/// actually happened rather than a guess: Steam's `connection_log.txt` and
/// `console_log.txt`, BepInEx's `LogOutput.log`, and the game's `Player.log`.
public struct ModLaunchMonitor: Sendable {
    public let bottleURL: URL
    public let appId: Int
    /// The game folder that's starting: the mod's frozen copy, or the game itself.
    public let gameFolder: URL
    public let modded: Bool
    public let startedAt: Date

    public init(bottleURL: URL, appId: Int, gameFolder: URL, modded: Bool, startedAt: Date = Date()) {
        self.bottleURL = bottleURL
        self.appId = appId
        self.gameFolder = gameFolder
        self.modded = modded
        self.startedAt = startedAt
    }

    public func progress(steamWasRunning: Bool) -> LaunchProgress {
        guard let steam = SteamLibrary.detectInstall(bottleURL: bottleURL) else { return LaunchProgress(stage: .steam) }
        let logs = steam.appending(path: "logs")

        let signedIn = steamWasRunning || lines(logs.appending(path: "connection_log.txt"))
            .contains { $0.contains("[Logged On") && isAfterStart($0) }
        guard signedIn else { return LaunchProgress(stage: .steam) }

        let launched = lines(logs.appending(path: "console_log.txt"))
            .contains { $0.contains("Game process added : AppID \(appId)") && isAfterStart($0) }
        guard launched else { return LaunchProgress(stage: .launch) }

        if modded {
            let log = gameFolder.appending(path: "BepInEx/LogOutput.log")
            let total = pluginCount()
            guard isFresh(log) else { return LaunchProgress(stage: .mod, pluginsLoaded: 0, pluginsTotal: total) }
            let text = lines(log)
            let loaded = text.filter { $0.contains("] Loading [") }.count
            guard text.contains(where: { $0.contains("Chainloader startup complete") }) else {
                return LaunchProgress(stage: .mod, pluginsLoaded: loaded, pluginsTotal: max(total, loaded))
            }
        }

        // The game reaches its menu once it has finished signing in.
        if let player = playerLog(), isFresh(player),
           lines(player).contains(where: { $0.contains("login status") || $0.contains("SignInFail") }) {
            return LaunchProgress(stage: .done)
        }
        return LaunchProgress(stage: .window)
    }

    // MARK: Helpers

    func pluginCount() -> Int {
        let plugins = gameFolder.appending(path: "BepInEx/plugins")
        guard let walker = FileManager.default.enumerator(at: plugins, includingPropertiesForKeys: nil) else {
            return 0
        }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension.lowercased() == "dll" }.count
    }

    func playerLog() -> URL? {
        let users = bottleURL.appending(path: "drive_c/users")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: users.path(percentEncoded: false))) ?? []
        return names.lazy
            .map { users.appending(path: "\($0)/AppData/LocalLow/Innersloth/Among Us/Player.log") }
            .first { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    func isFresh(_ url: URL) -> Bool {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return (date ?? .distantPast) >= startedAt.addingTimeInterval(-2)
    }

    /// The last part of a log, as lines. Steam's logs grow for months.
    func lines(_ url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 200_000 ? size - 200_000 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return (String(bytes: data, encoding: .utf8) ?? "").components(separatedBy: "\n")
    }

    /// Steam stamps its lines `[2026-11-22 15:31:17]` in UTC.
    func isAfterStart(_ line: String) -> Bool {
        guard line.hasPrefix("["), line.count > 21 else { return false }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = String(line.dropFirst().prefix(19))
        guard let date = formatter.date(from: stamp) else { return false }
        return date >= startedAt.addingTimeInterval(-2)
    }
}
