//
//  ModLoaderRedirect.swift
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

public enum ModLoaderError: LocalizedError {
    case noLoader(URL)
    case outsideBottle(URL)

    public var errorDescription: String? {
        switch self {
        case .noLoader(let folder): return "\(folder.lastPathComponent) has no BepInEx loader to switch on."
        case .outsideBottle(let url): return "\(url.lastPathComponent) isn't inside the bottle's C: drive."
        }
    }
}

/// Points a game's mod loader at a mod installed in its own folder.
///
/// BepInEx is started by Doorstop: a `winhttp.dll` next to the game's
/// executable that reads `doorstop_config.ini` and loads the assembly it names.
/// Doorstop takes absolute Windows paths, so the game folder only needs those
/// two files while BepInEx, its plugins and the .NET runtime stay in the mod's
/// folder. That keeps the game where its store expects it: Steam launches it
/// normally and sign-in works, which it doesn't for a copy started directly.
/// Switching mods rewrites three paths; turning mods off sets `enabled = false`.
public enum ModLoaderRedirect {
    static let loaderFiles = ["winhttp.dll", ".doorstop_version"]
    static let configName = "doorstop_config.ini"
    /// Config keys holding paths, resolved against the mod folder.
    static let pathKeys = ["target_assembly", "coreclr_path", "corlib_dir"]

    /// Switches the game's loader on and points it at `modFolder`.
    public static func activate(modFolder: URL, gameFolder: URL, bottleURL: URL) throws {
        let fileManager = FileManager.default
        let modConfig = modFolder.appending(path: configName)
        guard fileManager.fileExists(atPath: modConfig.path(percentEncoded: false)),
              fileManager.fileExists(atPath: modFolder.appending(path: "winhttp.dll").path(percentEncoded: false))
        else { throw ModLoaderError.noLoader(modFolder) }
        guard let windowsModFolder = windowsPath(modFolder, bottleURL: bottleURL) else {
            throw ModLoaderError.outsideBottle(modFolder)
        }

        // A game that already had its own winhttp.dll gets it back on removal.
        for name in loaderFiles {
            let source = modFolder.appending(path: name)
            guard fileManager.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
            let target = gameFolder.appending(path: name)
            if fileManager.fileExists(atPath: target.path(percentEncoded: false)), !isOurs(gameFolder) {
                let backup = gameFolder.appending(path: ModInstaller.backupFolder).appending(path: "loader")
                try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
                try? fileManager.removeItem(at: backup.appending(path: name))
                try fileManager.moveItem(at: target, to: backup.appending(path: name))
            }
            try? fileManager.removeItem(at: target)
            try fileManager.copyItem(at: source, to: target)
        }

        let config = try String(contentsOf: modConfig, encoding: .utf8)
        let rewritten = rewrite(config, enabled: true) { key, value in
            guard pathKeys.contains(key), !value.isEmpty, !isAbsoluteWindowsPath(value) else { return value }
            return windowsModFolder + "\\" + value
        }
        try rewritten.write(to: gameFolder.appending(path: configName), atomically: true, encoding: .utf8)
        try Data(windowsModFolder.utf8).write(to: markerURL(gameFolder))
    }

    /// Switches mods off for the next launch; the loader files stay for next time.
    public static func deactivate(gameFolder: URL) throws {
        let url = gameFolder.appending(path: configName)
        guard isOurs(gameFolder), let config = try? String(contentsOf: url, encoding: .utf8) else { return }
        try rewrite(config, enabled: false) { _, value in value }.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Takes the loader out of the game folder and restores what was there before.
    public static func remove(gameFolder: URL) throws {
        guard isOurs(gameFolder) else { return }
        let fileManager = FileManager.default
        for name in loaderFiles + [configName] {
            try? fileManager.removeItem(at: gameFolder.appending(path: name))
            let saved = gameFolder.appending(path: ModInstaller.backupFolder)
                .appending(path: "loader").appending(path: name)
            if fileManager.fileExists(atPath: saved.path(percentEncoded: false)) {
                try fileManager.moveItem(at: saved, to: gameFolder.appending(path: name))
            }
        }
        try? fileManager.removeItem(at: markerURL(gameFolder))
    }

    /// Whether the game's loader was set up for `modFolder`, switched on or off.
    public static func pointsAt(_ modFolder: URL, gameFolder: URL, bottleURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: markerURL(gameFolder)),
              let recorded = String(data: data, encoding: .utf8),
              let wanted = windowsPath(modFolder, bottleURL: bottleURL) else { return false }
        return recorded.lowercased() == wanted.lowercased()
    }

    /// The mod folder the loader points at, when mods are switched on.
    public static func activeModFolder(gameFolder: URL, bottleURL: URL) -> URL? {
        guard let data = try? Data(contentsOf: markerURL(gameFolder)),
              let windows = String(data: data, encoding: .utf8),
              let config = try? String(contentsOf: gameFolder.appending(path: configName), encoding: .utf8),
              value(of: "enabled", in: config)?.lowercased() == "true"
        else { return nil }
        return unixPath(windows, bottleURL: bottleURL)
    }

    // MARK: Helpers

    static func markerURL(_ gameFolder: URL) -> URL {
        gameFolder.appending(path: ".betterwhisky-loader")
    }

    static func isOurs(_ gameFolder: URL) -> Bool {
        FileManager.default.fileExists(atPath: markerURL(gameFolder).path(percentEncoded: false))
    }

    /// Rewrites `key = value` lines; `enabled` is set in the `[General]` section.
    static func rewrite(_ config: String, enabled: Bool, transform: (String, String) -> String) -> String {
        config.components(separatedBy: "\n").map { line in
            guard let equals = line.firstIndex(of: "="), !line.hasPrefix("#"), !line.hasPrefix(";") else { return line }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if key == "enabled" { return "enabled = \(enabled)" }
            return "\(key) = \(transform(key, value))"
        }
        .joined(separator: "\n")
    }

    static func value(of key: String, in config: String) -> String? {
        for line in config.components(separatedBy: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            if line[..<equals].trimmingCharacters(in: .whitespaces) == key {
                return line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    static func isAbsoluteWindowsPath(_ value: String) -> Bool {
        value.count > 2 && value.dropFirst().hasPrefix(":\\")
    }

    /// `…/Bottle/drive_c/Program Files/Game` → `C:\Program Files\Game`.
    public static func windowsPath(_ url: URL, bottleURL: URL) -> String? {
        let driveC = bottleURL.appending(path: "drive_c").standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(driveC + "/") else { return nil }
        return "C:\\" + path.dropFirst(driveC.count + 1).replacingOccurrences(of: "/", with: "\\")
    }

    static func unixPath(_ windows: String, bottleURL: URL) -> URL? {
        guard windows.uppercased().hasPrefix("C:\\") else { return nil }
        let relative = windows.dropFirst(3).replacingOccurrences(of: "\\", with: "/")
        return bottleURL.appending(path: "drive_c").appending(path: relative)
    }
}
