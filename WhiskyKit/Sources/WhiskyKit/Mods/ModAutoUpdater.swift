//
//  ModAutoUpdater.swift
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
import os.log

/// Keeps installed mods on their latest release, on their own.
///
/// Mods for Steam games live in frozen copies of the game. When a mod release
/// supports the game Steam has now, the copy is re-cloned from it and the
/// new release goes in: the mod moves forward with the game. A release for the
/// frozen version updates the mod in place. Anything else waits, so the mod
/// stays playable on the version it was made for.
public enum ModAutoUpdater {
    static let lastRunKey = "modAutoUpdateLastRun"
    static let interval: TimeInterval = 6 * 60 * 60
    private static let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "ModAutoUpdater")

    /// Checks every bottle at most once per `interval`. Returns a line per update made.
    @MainActor
    public static func runIfDue(bottles: [Bottle], defaults: UserDefaults = .standard) async -> [String] {
        let last = defaults.double(forKey: lastRunKey)
        guard Date().timeIntervalSince1970 - last > interval else { return [] }
        defaults.set(Date().timeIntervalSince1970, forKey: lastRunKey)
        var notes: [String] = []
        for bottle in bottles {
            notes += await run(bottle: bottle)
        }
        return notes
    }

    @MainActor
    static func run(bottle: Bottle) async -> [String] {
        var notes: [String] = []
        for game in SteamLibrary.enumerate(bottleURL: bottle.url) {
            for (copy, _) in ModInstaller.installedModFolders(forGame: game.installURL) {
                guard let installed = ModInstaller.installedMods(in: copy).first,
                      let preset = ModPreset.builtIn.first(where: { $0.repo == installed.repo }) else { continue }
                do {
                    if let note = try await update(installed, preset: preset, copy: copy, game: game, bottle: bottle) {
                        notes.append(note)
                    }
                } catch {
                    logger.error("Updating \(installed.name, privacy: .public) failed: \(error.localizedDescription)")
                }
            }
        }
        return notes
    }

    @MainActor
    static func update(
        _ installed: InstalledMod, preset: ModPreset, copy: URL, game: SteamGame, bottle: Bottle
    ) async throws -> String? {
        async let readme = GitHubReleases.readme(repo: preset.repo)
        let release = try await GitHubReleases.latestRelease(repo: preset.repo)
        guard release.tagName != installed.version,
              let asset = release.assets.first(where: { preset.matchesAsset(named: $0.name) }) else { return nil }

        let text = [release.body, try? await readme].compactMap { $0 }.joined(separator: "\n")
        let decision = ModGameVersion.decide(
            required: ModGameVersion.required(in: text, modVersion: release.tagName),
            game: ModGameVersion.installed(gameFolder: game.installURL),
            copy: ModInstaller.frozenVersion(copy),
            hasCopy: true
        )
        guard case .install(let freshCopy) = decision,
              let gameExe = ModInstaller.mainExecutable(in: game.installURL) else { return nil }

        let wasSelected = SteamModLauncher.selected(appId: game.appId, bottleURL: bottle.url)?
            .path.hasPrefix(copy.path) == true
        if freshCopy {
            if wasSelected { try SteamModLauncher.select(nil, appId: game.appId, bottleURL: bottle.url) }
            try FileManager.default.removeItem(at: copy.deletingLastPathComponent())
        } else {
            try ModInstaller.uninstall(installed, from: copy)
        }
        var rule = preset.install
        rule.frozenCopy = true
        let result = try await ModInstaller.install(
            asset: asset, version: release.tagName, name: preset.name, repo: preset.repo,
            rule: rule, gameExecutable: gameExe
        )
        if wasSelected {
            try SteamModLauncher.select(result.executable, appId: game.appId, bottleURL: bottle.url)
        }
        let version = ModInstaller.frozenVersion(result.gameFolder).map { " (Among Us \($0))" } ?? ""
        return "Updated \(preset.name) to \(release.tagName)\(version)."
    }
}
