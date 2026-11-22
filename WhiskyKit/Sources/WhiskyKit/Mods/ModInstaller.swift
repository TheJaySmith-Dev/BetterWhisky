//
//  ModInstaller.swift
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

/// A mod BetterWhisky put into a game folder, recorded so it can be updated or removed.
public struct InstalledMod: Codable, Hashable, Sendable, Identifiable {
    public var id: String { repo }
    public var name: String
    public var repo: String
    public var version: String
    public var installedAt: Date
    /// Files written, relative to the game folder.
    public var files: [String]
}

public enum ModInstallError: LocalizedError {
    case unsafePath(String)
    case extractFailed(String)
    case unsupportedFile(String)

    public var errorDescription: String? {
        switch self {
        case .unsafePath(let path): return "The archive has a file outside the game folder: \(path)"
        case .extractFailed(let message): return "Couldn't unzip the mod: \(message)"
        case .unsupportedFile(let name): return "\(name) isn't a .zip or .dll file."
        }
    }
}

/// The result of an install: where the mod went and which executable to launch.
public struct ModInstallResult: Sendable {
    public var gameFolder: URL
    public var executable: URL
    public var mod: InstalledMod
}

/// Downloads, unpacks and installs mods into a game folder.
public enum ModInstaller {
    static let manifestName = ".betterwhisky-mods.json"
    static let backupFolder = ".betterwhisky-backup"
    private static let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "ModInstaller")

    // MARK: Entry points

    /// Installs a mod from a GitHub release asset.
    public static func install( // swiftlint:disable:this function_parameter_count
        asset: GitHubRelease.Asset, version: String, name: String, repo: String,
        rule: ModInstallRule, gameExecutable: URL, session: URLSession = .shared
    ) async throws -> ModInstallResult {
        let work = try makeWorkFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        let (downloaded, _) = try await session.download(from: asset.browserDownloadURL)
        let file = work.appending(path: asset.name)
        try FileManager.default.moveItem(at: downloaded, to: file)
        return try await installFile(
            file, version: version, name: name, repo: repo, rule: rule, gameExecutable: gameExecutable
        )
    }

    /// Installs a local `.zip` or `.dll` the user dropped onto the game.
    public static func installLocal(
        file: URL, rule: ModInstallRule? = nil, gameExecutable: URL
    ) async throws -> ModInstallResult {
        let ext = file.pathExtension.lowercased()
        guard ext == "zip" || ext == "dll" else { throw ModInstallError.unsupportedFile(file.lastPathComponent) }
        let rule = rule ?? ModInstallRule(
            mode: ext == "zip" ? .extract : .copyFile,
            subpath: ext == "dll" && hasBepInEx(gameExecutable.deletingLastPathComponent()) ? "BepInEx/plugins" : ""
        )
        let name = file.deletingPathExtension().lastPathComponent
        return try await installFile(
            file, version: "local", name: name, repo: "local/\(name)", rule: rule, gameExecutable: gameExecutable
        )
    }

    /// Mods recorded in a game folder.
    public static func installedMods(in gameFolder: URL) -> [InstalledMod] {
        guard let data = try? Data(contentsOf: gameFolder.appending(path: manifestName)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([InstalledMod].self, from: data)) ?? []
    }

    /// Removes a mod's files and puts back any game files it replaced.
    public static func uninstall(_ mod: InstalledMod, from gameFolder: URL) throws {
        let fileManager = FileManager.default
        let backup = gameFolder.appending(path: backupFolder).appending(path: safeName(mod.repo))
        for relative in mod.files {
            let target = try resolve(relative, in: gameFolder)
            try? fileManager.removeItem(at: target)
            let saved = backup.appending(path: relative)
            if fileManager.fileExists(atPath: saved.path(percentEncoded: false)) {
                try makeParent(of: target)
                try fileManager.moveItem(at: saved, to: target)
            }
        }
        try? fileManager.removeItem(at: backup)
        try writeManifest(installedMods(in: gameFolder).filter { $0.repo != mod.repo }, to: gameFolder)
    }

    /// Whether the folder's BepInEx plugins already hold `<name>.dll`, as when
    /// a mod's download bundles a library its README lists as a dependency.
    public static func bundles(plugin name: String, in folder: URL) -> Bool {
        let plugins = folder.appending(path: "BepInEx/plugins")
        guard let walker = FileManager.default.enumerator(at: plugins, includingPropertiesForKeys: nil) else {
            return false
        }
        let wanted = name.lowercased() + ".dll"
        return walker.contains { ($0 as? URL)?.lastPathComponent.lowercased() == wanted }
    }

    public static func hasBepInEx(_ gameFolder: URL) -> Bool {
        FileManager.default.fileExists(atPath: gameFolder.appending(path: "BepInEx").path(percentEncoded: false))
    }

    // MARK: Install steps

    // swiftlint:disable:next function_parameter_count
    static func installFile(
        _ file: URL, version: String, name: String, repo: String,
        rule: ModInstallRule, gameExecutable: URL
    ) async throws -> ModInstallResult {
        var gameFolder = gameExecutable.deletingLastPathComponent()
        if rule.frozenCopy {
            gameFolder = try frozenCopy(of: gameFolder, for: name)
        } else if rule.ownFolder {
            gameFolder = modFolder(for: name, game: gameFolder)
            try FileManager.default.createDirectory(at: gameFolder, withIntermediateDirectories: true)
        } else if rule.copyGame {
            gameFolder = try copyGameFolder(gameFolder, for: name)
        }
        let target = try resolve(rule.subpath, in: gameFolder)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        // Replacing an older copy of the same mod: take it out first.
        if let previous = installedMods(in: gameFolder).first(where: { $0.repo == repo }) {
            try uninstall(previous, from: gameFolder)
        }

        let source: URL
        let work = try makeWorkFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        switch rule.mode {
        case .extract:
            source = try await extract(
                file, into: work.appending(path: "unpacked"), stripTopFolder: rule.stripTopFolder
            )
        case .copyFile:
            source = work.appending(path: "single")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: file, to: source.appending(path: file.lastPathComponent))
        }

        let written = try merge(source, into: target, gameFolder: gameFolder, backupKey: safeName(repo))
        let mod = InstalledMod(name: name, repo: repo, version: version, installedAt: Date(), files: written)
        try writeManifest(installedMods(in: gameFolder).filter { $0.repo != repo } + [mod], to: gameFolder)
        logger.info(
            "Installed \(name, privacy: .public) (\(written.count) files) into \(gameFolder.path, privacy: .public)"
        )
        // A mod in its own folder runs through the game's own executable.
        let executable = rule.ownFolder && !rule.frozenCopy
            ? gameExecutable : gameFolder.appending(path: gameExecutable.lastPathComponent)
        return ModInstallResult(gameFolder: gameFolder, executable: executable, mod: mod)
    }

    /// Where a mod with its own folder lives: `<Game> Mods/<Mod>` next to the game.
    public static func modFolder(for modName: String, game gameFolder: URL) -> URL {
        gameFolder.deletingLastPathComponent()
            .appending(path: "\(gameFolder.lastPathComponent) Mods")
            .appending(path: safeName(modName))
    }

    /// Mods installed in their own folders for the game at `gameFolder`, by name.
    public static func installedModFolders(forGame gameFolder: URL) -> [(folder: URL, name: String)] {
        let root = gameFolder.deletingLastPathComponent().appending(path: "\(gameFolder.lastPathComponent) Mods")
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return folders.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { folder in
            let copy = folder.appending(path: "game")
            if let mod = installedMods(in: copy).first { return (copy, mod.name) }
            return installedMods(in: folder).first.map { (folder, $0.name) }
        }
    }

    /// Copies the game to a sibling folder named after the mod, unless that copy exists already.
    static func copyGameFolder(_ gameFolder: URL, for modName: String) throws -> URL {
        let copy = gameFolder.deletingLastPathComponent()
            .appending(path: "\(gameFolder.lastPathComponent) - \(safeName(modName))")
        if !FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)) {
            try FileManager.default.copyItem(at: gameFolder, to: copy)
            // Mods recorded in the original belong to the original.
            try? FileManager.default.removeItem(at: copy.appending(path: manifestName))
            try? FileManager.default.removeItem(at: copy.appending(path: backupFolder))
        }
        return copy
    }

    static func extract(_ zip: URL, into folder: URL, stripTopFolder: Bool) async throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await run("/usr/bin/ditto", [
            "-x", "-k", zip.path(percentEncoded: false), folder.path(percentEncoded: false)
        ])
        try? FileManager.default.removeItem(at: folder.appending(path: "__MACOSX"))

        guard stripTopFolder else { return folder }
        let entries = try FileManager.default
            .contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
        // Only strip a wrapper folder, never a folder the game itself uses.
        if entries.count == 1, let only = entries.first,
           (try? only.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
           !["bepinex", "plugins", "dotnet", "mods"].contains(only.lastPathComponent.lowercased()) {
            return only
        }
        return folder
    }

    /// Copies every file under `source` into `target`, backing up game files it replaces.
    /// Returns the written paths relative to the game folder.
    static func merge(_ source: URL, into target: URL, gameFolder: URL, backupKey: String) throws -> [String] {
        let fileManager = FileManager.default
        let sourceRoot = source.standardizedFileURL.resolvingSymlinksInPath().path
        let gameRoot = gameFolder.standardizedFileURL.path
        let backup = gameFolder.appending(path: backupFolder).appending(path: backupKey)
        var written: [String] = []

        guard let walker = fileManager.enumerator(
            at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else { return [] }
        for case let item as URL in walker {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw ModInstallError.unsafePath(item.lastPathComponent) }
            guard values.isRegularFile == true else { continue }
            let itemPath = item.standardizedFileURL.resolvingSymlinksInPath().path
            guard itemPath.hasPrefix(sourceRoot + "/") else { throw ModInstallError.unsafePath(itemPath) }
            let relativeToSource = String(itemPath.dropFirst(sourceRoot.count + 1))

            let destination = target.appending(path: relativeToSource).standardizedFileURL
            guard destination.path.hasPrefix(gameRoot + "/") else { throw ModInstallError.unsafePath(relativeToSource) }
            let relativeToGame = String(destination.path.dropFirst(gameRoot.count + 1))

            try makeParent(of: destination)
            if fileManager.fileExists(atPath: destination.path) {
                let saved = backup.appending(path: relativeToGame)
                try makeParent(of: saved)
                try? fileManager.removeItem(at: saved)
                try fileManager.moveItem(at: destination, to: saved)
            }
            try fileManager.copyItem(at: item, to: destination)
            written.append(relativeToGame)
        }
        return written
    }

    // MARK: Helpers

    static func makeParent(of url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    static func resolve(_ relative: String, in folder: URL) throws -> URL {
        let root = folder.standardizedFileURL
        let url = relative.isEmpty ? root : root.appending(path: relative).standardizedFileURL
        guard url.path == root.path || url.path.hasPrefix(root.path + "/") else {
            throw ModInstallError.unsafePath(relative)
        }
        return url
    }

    public static func safeName(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
        return String(text.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }

    static func writeManifest(_ mods: [InstalledMod], to gameFolder: URL) throws {
        let url = gameFolder.appending(path: manifestName)
        guard !mods.isEmpty else { try? FileManager.default.removeItem(at: url); return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(mods).write(to: url, options: .atomic)
    }

    static func makeWorkFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "BetterWhiskyMods-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func run(_ tool: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { finished in
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let data = errors.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: data, encoding: .utf8) ?? "exit \(finished.terminationStatus)"
                    continuation.resume(throwing: ModInstallError.extractFailed(message))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

// MARK: - Frozen copies

public extension ModInstaller {
    /// The mod's frozen copy of the game: `<Game> Mods/<Mod>/game`, cloned from
    /// the installed game when it doesn't exist yet. On APFS the clone shares
    /// storage with the original until Steam changes it.
    static func frozenCopy(of gameFolder: URL, for modName: String) throws -> URL {
        let copy = modFolder(for: modName, game: gameFolder).appending(path: "game")
        if !FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)) {
            try FileManager.default.createDirectory(
                at: copy.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: gameFolder, to: copy)
            for leftover in [manifestName, backupFolder, ".betterwhisky-loader"] {
                try? FileManager.default.removeItem(at: copy.appending(path: leftover))
            }
            if let version = ModGameVersion.installed(gameFolder: copy) {
                try? Data(version.utf8).write(to: copy.appending(path: ".betterwhisky-game-version"))
            }
        }
        return copy
    }

    /// The game's own executable in `folder`: a top-level .exe that isn't a
    /// crash reporter or uninstaller.
    static func mainExecutable(in folder: URL, preferring name: String? = nil) -> URL? {
        if let name {
            let url = folder.appending(path: name)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { return url }
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        return names.filter { $0.lowercased().hasSuffix(".exe") }
            .filter { name in !["crash", "unins", "redist", "setup"].contains { name.lowercased().contains($0) } }
            .sorted()
            .first
            .map { folder.appending(path: $0) }
    }

    /// The game version a frozen copy was made at.
    static func frozenVersion(_ copy: URL) -> String? {
        (try? Data(contentsOf: copy.appending(path: ".betterwhisky-game-version")))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

}
