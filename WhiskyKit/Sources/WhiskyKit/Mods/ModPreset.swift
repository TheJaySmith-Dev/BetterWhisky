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
    /// Install into a folder of the mod's own, next to the game, and point the
    /// game's loader at it (``ModLoaderRedirect``). The game itself stays put,
    /// so its store can launch it.
    public var ownFolder: Bool
    /// Install into a copy of the game, frozen at the version the mod was
    /// installed for, inside `<Game> Mods/<Mod>/game`. Steam keeps updating
    /// the real game; the copy stays playable with the mod until the mod
    /// catches up. Steam starts it through ``SteamModLauncher``.
    public var frozenCopy: Bool

    public init(
        mode: Mode, subpath: String = "", stripTopFolder: Bool = true,
        copyGame: Bool = false, ownFolder: Bool = false, frozenCopy: Bool = false
    ) {
        self.mode = mode
        self.subpath = subpath
        self.stripTopFolder = stripTopFolder
        self.copyGame = copyGame
        self.ownFolder = ownFolder
        self.frozenCopy = frozenCopy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(Mode.self, forKey: .mode)
        subpath = try container.decodeIfPresent(String.self, forKey: .subpath) ?? ""
        stripTopFolder = try container.decodeIfPresent(Bool.self, forKey: .stripTopFolder) ?? true
        copyGame = try container.decodeIfPresent(Bool.self, forKey: .copyGame) ?? false
        ownFolder = try container.decodeIfPresent(Bool.self, forKey: .ownFolder) ?? false
        frozenCopy = try container.decodeIfPresent(Bool.self, forKey: .frozenCopy) ?? false
    }
}

/// How a modded game is started.
public enum ModLaunchMethod: String, Codable, Hashable, Sendable {
    /// Run the game's executable.
    case direct
    /// Ask the store's client to launch the game, so its sign-in works.
    /// Among Us, for one, only signs in when Steam starts it.
    case steam
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
    /// The game's Steam App ID, for ``ModLaunchMethod/steam``.
    public var steamAppId: Int?
    public var launch: ModLaunchMethod

    public init(
        name: String, repo: String, gameExecutables: [String], assetPattern: String,
        install: ModInstallRule, requires: [String] = [], notes: String? = nil,
        steamAppId: Int? = nil, launch: ModLaunchMethod = .direct
    ) {
        self.name = name
        self.repo = repo
        self.gameExecutables = gameExecutables
        self.assetPattern = assetPattern
        self.install = install
        self.requires = requires
        self.notes = notes
        self.steamAppId = steamAppId
        self.launch = launch
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
            install: ModInstallRule(mode: .extract, frozenCopy: true),
            notes: "Ships with BepInEx. The first launch can take a few minutes.",
            steamAppId: 945360, launch: .steam
        ),
        ModPreset(
            name: "The Other Roles",
            repo: "TheOtherRolesAU/TheOtherRoles",
            gameExecutables: ["Among Us.exe"],
            assetPattern: #"^TheOtherRoles\.zip$"#,
            install: ModInstallRule(mode: .extract, frozenCopy: true),
            notes: "Ships with BepInEx. Needs the Among Us version it was built for.",
            steamAppId: 945360, launch: .steam
        )
    ]

    static func presets(for executable: URL) -> [ModPreset] {
        builtIn.filter { $0.matches(executable: executable) }
    }
}
