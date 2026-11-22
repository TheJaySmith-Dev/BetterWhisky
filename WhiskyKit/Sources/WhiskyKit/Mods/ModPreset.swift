//
//  ModPreset.swift
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

/// How a mod's files get into the game.
public struct ModInstallRule: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Hashable, Sendable {
        /// Unzip the archive and merge its contents into the target folder.
        case extract
        /// Copy a single file (usually a `.dll`) into the target folder.
        case copyFile
    }

    public var mode: Mode
    /// Folder inside the game folder the files go to. Empty means the game root.
    public var subpath: String
    /// Drop a single wrapper folder at the top of the archive, if there is one.
    public var stripTopFolder: Bool
    /// Install into a copy of the game folder rather than the original, so
    /// mods that each ship their own loader don't overwrite each other.
    public var copyGame: Bool

    public init(mode: Mode, subpath: String = "", stripTopFolder: Bool = true, copyGame: Bool = false) {
        self.mode = mode
        self.subpath = subpath
        self.stripTopFolder = stripTopFolder
        self.copyGame = copyGame
    }
}

/// A recipe for installing a mod from a GitHub repository's latest release.
public struct ModPreset: Codable, Hashable, Sendable, Identifiable {
    public var id: String { repo }
    public var name: String
    /// `owner/name` on GitHub.
    public var repo: String
    /// Executable filenames this mod is for (case-insensitive). Empty matches any game.
    public var gameExecutables: [String]
    /// Regular expression the release asset's filename must match.
    public var assetPattern: String
    public var install: ModInstallRule
    /// Other presets (by repo) that must be installed first.
    public var requires: [String]
    public var notes: String?

    public init(
        name: String, repo: String, gameExecutables: [String], assetPattern: String,
        install: ModInstallRule, requires: [String] = [], notes: String? = nil
    ) {
        self.name = name
        self.repo = repo
        self.gameExecutables = gameExecutables
        self.assetPattern = assetPattern
        self.install = install
        self.requires = requires
        self.notes = notes
    }

    public func matches(executable url: URL) -> Bool {
        guard !gameExecutables.isEmpty else { return true }
        let name = url.lastPathComponent.lowercased()
        return gameExecutables.contains { $0.lowercased() == name }
    }

    public func matchesAsset(named fileName: String) -> Bool {
        fileName.range(of: assetPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Parses `owner/name` out of a repo string or a github.com URL.
    public static func repoSlug(from input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "www.", "github.com/"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        if text.hasSuffix(".git") { text = String(text.dropLast(4)) }
        let parts = text.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard parts[0...1].allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
            return nil
        }
        return "\(parts[0])/\(parts[1])"
    }
}

public extension ModPreset {
    /// Presets shipped with the app.
    static let builtIn: [ModPreset] = [
        ModPreset(
            name: "Town of Us: Mira",
            repo: "AU-Avengers/TOU-Mira",
            gameExecutables: ["Among Us.exe"],
            assetPattern: #"-x64-Steam-Epic-MsStore\.zip$"#,
            install: ModInstallRule(mode: .extract, copyGame: true),
            notes: "Ships with BepInEx. The first launch can take a few minutes."
        ),
        ModPreset(
            name: "The Other Roles",
            repo: "TheOtherRolesAU/TheOtherRoles",
            gameExecutables: ["Among Us.exe"],
            assetPattern: #"^TheOtherRoles\.zip$"#,
            install: ModInstallRule(mode: .extract, copyGame: true),
            notes: "Ships with BepInEx. Needs the Among Us version it was built for."
        )
    ]

    static func presets(for executable: URL) -> [ModPreset] {
        builtIn.filter { $0.matches(executable: executable) }
    }
}
