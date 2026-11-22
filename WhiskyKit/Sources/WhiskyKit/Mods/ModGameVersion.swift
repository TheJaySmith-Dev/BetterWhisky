//
//  ModGameVersion.swift
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

/// Game versions: the one installed, and the one a mod release says it needs.
///
/// Among Us versions are dates (`2026.9.29`, sometimes with an `s` for Steam,
/// `2024.3.5s`). Mods say which they support in a README badge
/// (`badgen.net/static/AmongUs/2026.9.29`), a release table
/// (`| 2024.11.26 | v4.8.0 | …`) or a line in the notes ("Updated to Among Us
/// version 2024.11.26").
public enum ModGameVersion {
    static let pattern = #"(20\d{2})\.(\d{1,2})\.(\d{1,2})s?(?![\d.]|f\d)"#

    /// The version of the Unity game in `gameFolder`, read from its game data.
    public static func installed(gameFolder: URL) -> String? {
        let fileManager = FileManager.default
        guard let dataFolder = (try? fileManager.contentsOfDirectory(atPath: gameFolder.path(percentEncoded: false)))?
            .first(where: { $0.hasSuffix("_Data") }) else { return nil }
        let file = gameFolder.appending(path: dataFolder).appending(path: "globalgamemanagers")
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        let text = String(decoding: data.prefix(4_000_000), as: Unicode.ASCII.self)
        return versions(in: text).first
    }

    /// The game version a mod release needs, if its notes or README say.
    public static func required(in text: String, modVersion: String) -> String? {
        let mod = modVersion.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let lines = text.components(separatedBy: .newlines)
        // A release table: the row that names this mod version.
        let modPattern = "v?\(NSRegularExpression.escapedPattern(for: mod))\\b"
        for line in lines where line.contains("|") && line.range(of: modPattern, options: .regularExpression) != nil {
            if let version = versions(in: line).first { return version }
        }
        // A badge or a sentence about the game version.
        for line in lines {
            let lower = line.lowercased()
            guard lower.contains("amongus/") || lower.contains("among us version") || lower.contains("among us v")
            else { continue }
            if let version = versions(in: line).first { return version }
        }
        return nil
    }

    /// What to do with a mod release, given the game versions involved.
    public enum Decision: Equatable, Sendable {
        /// Install it. With `freshCopy`, re-clone the game first (the release
        /// supports the game Steam has now); without, install into the
        /// existing frozen copy, which is at the version the release needs.
        case install(freshCopy: Bool)
        /// Leave the installed mod as it is: the release needs a game version
        /// that is neither the current game nor the frozen copy.
        case keep(required: String)
        /// Can't install: the release needs a version that isn't here.
        case blocked(required: String, game: String)
    }

    public static func decide(
        required: String?, game: String?, copy: String?, hasCopy: Bool
    ) -> Decision {
        let copyIsCurrent = copy.flatMap { copy in game.map { matches(copy, $0) } } ?? false
        guard let required, let game else {
            // No stated version: assume the release follows the newest game.
            return .install(freshCopy: !hasCopy || !copyIsCurrent)
        }
        if matches(required, game) {
            return .install(freshCopy: !hasCopy || !copyIsCurrent)
        }
        if hasCopy, let copy, matches(required, copy) {
            return .install(freshCopy: false)
        }
        return hasCopy ? .keep(required: required) : .blocked(required: required, game: game)
    }

    /// Whether two versions are the same release (`2024.3.5s` == `2024.03.05`).
    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        normalize(lhs) == normalize(rhs)
    }

    static func normalize(_ version: String) -> String {
        version.trimmingCharacters(in: CharacterSet(charactersIn: "sS"))
            .split(separator: ".")
            .map { String(Int($0) ?? 0) }
            .joined(separator: ".")
    }

    static func versions(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { normalize(String(text[$0])) }
        }
    }
}
