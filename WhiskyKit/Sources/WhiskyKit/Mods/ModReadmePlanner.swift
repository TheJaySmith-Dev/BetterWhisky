//
//  ModReadmePlanner.swift
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

/// What the planner worked out for a repo that has no preset.
public struct ModInstallPlan: Sendable, Hashable {
    public var asset: GitHubRelease.Asset
    public var rule: ModInstallRule
    /// The README lines the plan is based on, shown to the user before installing.
    public var reasons: [String]
    /// Whether the README said clearly how to install, rather than the planner guessing.
    public var confident: Bool
}

/// Turns a mod's README and release files into install steps.
///
/// It looks for the usual phrasing ("extract into your game folder",
/// "put the .dll in BepInEx/plugins", "make a copy of the game") and falls
/// back to the shape of the release files. The result is always shown to the
/// user before anything is written.
public enum ModReadmePlanner {
    public static func plan(readme: String?, release: GitHubRelease) -> ModInstallPlan? {
        let text = readme ?? ""
        let sentences = text
            .components(separatedBy: CharacterSet(charactersIn: "\n.!"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        func evidence(_ keys: [String]) -> String? {
            sentences.first { line in keys.allSatisfy { line.lowercased().contains($0) } }
        }

        var reasons: [String] = []
        var confident = false

        let pluginLine = evidence(["bepinex", "plugins"])
        let extractLine = evidence(["extract"]) ?? evidence(["unzip"])
        let copyLine = evidence(["copy", "folder"]) ?? evidence(["duplicate", "folder"])
        let wantsCopy = copyLine.map { line in
            let line = line.lowercased()
            return line.contains("game") || line.contains("among us") || line.contains("install")
        } ?? false

        guard let asset = pickAsset(release.assets, preferDLL: pluginLine != nil && extractLine == nil) else {
            return nil
        }
        let isZip = asset.name.lowercased().hasSuffix(".zip")

        var rule: ModInstallRule
        if !isZip {
            rule = ModInstallRule(mode: .copyFile, subpath: pluginLine != nil ? "BepInEx/plugins" : "")
            if let pluginLine { reasons.append(pluginLine); confident = true }
        } else {
            // "Extract into your game folder" wins; a zip that only talks about
            // plugins is a plugin bundle.
            let subpath = (pluginLine != nil && extractLine == nil) ? "BepInEx/plugins" : ""
            rule = ModInstallRule(mode: .extract, subpath: subpath)
            if let extractLine { reasons.append(extractLine); confident = true }
            if subpath.isEmpty == false, let pluginLine { reasons.append(pluginLine) }
        }
        if wantsCopy, let copyLine {
            rule.copyGame = true
            reasons.append(copyLine)
        }
        if reasons.isEmpty {
            reasons.append("No install steps found in the README; guessing from the release file \(asset.name).")
        }
        return ModInstallPlan(asset: asset, rule: rule, reasons: reasons, confident: confident)
    }

    /// The release file most likely meant for a Windows game on Steam.
    static func pickAsset(_ assets: [GitHubRelease.Asset], preferDLL: Bool) -> GitHubRelease.Asset? {
        func score(_ asset: GitHubRelease.Asset) -> Int {
            let name = asset.name.lowercased()
            var score = 0
            if name.hasSuffix(".zip") { score += preferDLL ? 5 : 20 }
            if name.hasSuffix(".dll") { score += preferDLL ? 20 : 5 }
            if name.contains("steam") { score += 10 }
            if name.contains("x64") || name.contains("win") { score += 4 }
            for bad in ["android", "ios", "linux", "mac", "itch", "msstore", "source", "debug", "x86"]
            where name.contains(bad) {
                score -= name.contains("steam") && bad == "msstore" ? 0 : 15
            }
            return score
        }
        return assets
            .filter { [".zip", ".dll"].contains(where: $0.name.lowercased().hasSuffix) }
            .max { score($0) < score($1) }
    }
}
