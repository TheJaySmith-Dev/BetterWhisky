//
//  ModPrecompiler.swift
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

import CryptoKit
import Foundation
import os.log

/// Pre-compiles a BepInEx mod's .NET code on the Mac, so the game loads
/// machine code instead of compiling it at every start.
///
/// BepInEx for IL2CPP games runs its loader, the game's interop assemblies and
/// every plugin on .NET, which compiles each method the first time it runs.
/// Under Wine and Rosetta that compiling is the slowest part of a modded start
/// (about two and a half minutes for Town of Us). Microsoft's crossgen2 turns
/// the assemblies into ReadyToRun images for Windows x64 ahead of time, which
/// roughly halves it. Originals are kept, files crossgen2 can't handle stay as
/// they are, and the work reruns whenever the mod's files change.
public enum ModPrecompiler {
    static let version = "6.0.36"
    static var packageURL: URL? {
        URL(string: "https://api.nuget.org/v3-flatcontainer/microsoft.netcore.app.crossgen2.osx-arm64/"
            + "\(version)/microsoft.netcore.app.crossgen2.osx-arm64.\(version).nupkg")
    }
    static let markerName = ".betterwhisky-precompiled"
    static let originalsName = ".betterwhisky-il-originals"
    private static let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "ModPrecompiler")

    static var toolFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: Bundle.whiskyBundleIdentifier)
            .appending(path: "Tools/crossgen2-\(version)")
    }

    static var tool: URL { toolFolder.appending(path: "pkg/tools/crossgen2") }

    /// The folders whose assemblies get compiled, inside a game folder.
    static func sources(_ gameFolder: URL) -> [URL] {
        ["BepInEx/core", "BepInEx/interop", "BepInEx/plugins"].map { gameFolder.appending(path: $0) }
    }

    /// Whether `gameFolder` has a .NET 6 BepInEx whose current files haven't been compiled.
    public static func isNeeded(_ gameFolder: URL) -> Bool {
        let fileManager = FileManager.default
        let runtime = gameFolder.appending(path: "dotnet/coreclr.dll").path(percentEncoded: false)
        let interop = gameFolder.appending(path: "BepInEx/interop").path(percentEncoded: false)
        guard fileManager.fileExists(atPath: runtime), fileManager.fileExists(atPath: interop)
        else { return false }
        let marker = try? String(contentsOf: gameFolder.appending(path: "BepInEx/\(markerName)"), encoding: .utf8)
        return marker != fingerprint(gameFolder)
    }

    /// Compiles what changed. Returns how many assemblies were compiled.
    @discardableResult
    public static func run(_ gameFolder: URL) async throws -> Int {
        try await ensureTool()
        let fileManager = FileManager.default
        let bepinex = gameFolder.appending(path: "BepInEx")
        let originals = bepinex.appending(path: originalsName)
        let work = fileManager.temporaryDirectory.appending(path: "BetterWhiskyR2R-\(UUID().uuidString)")
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }

        let references = ([gameFolder.appending(path: "dotnet")] + sources(gameFolder)).flatMap { folder in
            ["-r", folder.appending(path: "*.dll").path(percentEncoded: false)]
        }
        var compiled = 0
        for input in assemblies(in: gameFolder) {
            let relative = String(input.path.dropFirst(gameFolder.path.count + 1))
            // Compile from the original, never from an earlier output.
            let saved = originals.appending(path: relative)
            let source = fileManager.fileExists(atPath: saved.path(percentEncoded: false)) ? saved : input
            let output = work.appending(path: relative)
            try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let arguments = [
                source.path(percentEncoded: false), "-o", output.path(percentEncoded: false),
                "--targetos", "windows", "--targetarch", "x64", "-O"
            ] + references
            guard (try? await ModInstaller.run(tool.path(percentEncoded: false), arguments)) != nil else { continue }
            if source == input {
                try ModInstaller.makeParent(of: saved)
                try? fileManager.removeItem(at: saved)
                try fileManager.copyItem(at: input, to: saved)
            }
            try? fileManager.removeItem(at: input)
            try fileManager.copyItem(at: output, to: input)
            compiled += 1
        }
        try fingerprint(gameFolder).write(to: bepinex.appending(path: markerName), atomically: true, encoding: .utf8)
        logger.info("Pre-compiled \(compiled) assemblies in \(gameFolder.lastPathComponent, privacy: .public)")
        return compiled
    }

    /// Pre-compiles every modded copy of a Steam game in `bottles` that needs it.
    @MainActor
    public static func runWhereNeeded(bottles: [Bottle]) async {
        let folders = bottles.flatMap { bottle in
            SteamLibrary.enumerate(bottleURL: bottle.url).flatMap { game in
                ModInstaller.installedModFolders(forGame: game.installURL).map(\.folder)
            }
        }
        for folder in folders where isNeeded(folder) {
            do {
                try await run(folder)
            } catch {
                logger.error("Pre-compiling \(folder.path, privacy: .public) failed: \(error.localizedDescription)")
            }
        }
    }

    /// Puts the original assemblies back.
    public static func undo(_ gameFolder: URL) throws {
        let fileManager = FileManager.default
        let originals = gameFolder.appending(path: "BepInEx/\(originalsName)")
        guard let walker = fileManager.enumerator(at: originals, includingPropertiesForKeys: nil) else { return }
        for case let saved as URL in walker where saved.pathExtension == "dll" {
            let relative = String(saved.path.dropFirst(originals.path.count + 1))
            let target = gameFolder.appending(path: relative)
            try? fileManager.removeItem(at: target)
            try fileManager.copyItem(at: saved, to: target)
        }
        try? fileManager.removeItem(at: originals)
        try? fileManager.removeItem(at: gameFolder.appending(path: "BepInEx/\(markerName)"))
    }

    // MARK: Helpers

    static func assemblies(in gameFolder: URL) -> [URL] {
        sources(gameFolder).flatMap { folder -> [URL] in
            let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
            return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension.lowercased() == "dll" }
        }
        .sorted { $0.path < $1.path }
    }

    /// Names and sizes of the originals, so new or updated files trigger a recompile.
    static func fingerprint(_ gameFolder: URL) -> String {
        let originals = gameFolder.appending(path: "BepInEx/\(originalsName)")
        let lines = assemblies(in: gameFolder).map { url -> String in
            let relative = String(url.path.dropFirst(gameFolder.path.count + 1))
            let saved = originals.appending(path: relative)
            let file = FileManager.default.fileExists(atPath: saved.path(percentEncoded: false)) ? saved : url
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return "\(relative):\(size)"
        }
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Downloads Microsoft's crossgen2 for Apple silicon from nuget.org the first time.
    static func ensureTool() async throws {
        let fileManager = FileManager.default
        guard !fileManager.isExecutableFile(atPath: tool.path(percentEncoded: false)) else { return }
        try fileManager.createDirectory(at: toolFolder, withIntermediateDirectories: true)
        guard let packageURL else { return }
        let (downloaded, _) = try await URLSession.shared.download(from: packageURL)
        let archive = toolFolder.appending(path: "crossgen2.nupkg")
        try? fileManager.removeItem(at: archive)
        try fileManager.moveItem(at: downloaded, to: archive)
        try await ModInstaller.run("/usr/bin/unzip", [
            "-qo", archive.path(percentEncoded: false),
            "-d", toolFolder.appending(path: "pkg").path(percentEncoded: false)
        ])
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path(percentEncoded: false))
    }
}
