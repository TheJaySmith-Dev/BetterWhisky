//
//  ModInstallerTests.swift
//  WhiskyKitTests
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
import Testing
@testable import WhiskyKit

@Suite struct ModInstallerTests {
    func asset(_ name: String) -> GitHubRelease.Asset {
        let json = #"{"name":"\#(name)","size":1,"browser_download_url":"https://example.com/\#(name)"}"#
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(GitHubRelease.Asset.self, from: Data(json.utf8))
    }

    func release(_ names: [String]) -> GitHubRelease {
        release(names, notes: nil)
    }

    func release(_ names: [String], notes: String?) -> GitHubRelease {
        GitHubRelease(tagName: "v1", publishedAt: Date(), prerelease: false, assets: names.map(asset), body: notes)
    }

    @Test func picksSteamZipForTOUMira() {
        let assets = [
            "MiraAPI.dll", "TouMira.v1.7.9-beta2-x64-Steam-Epic-MsStore.zip",
            "TouMira.v1.7.9-beta2-x86-ItchIo.zip", "TownOfUsMira-Android.dll", "TownOfUsMira.dll"
        ].map(asset)
        #expect(ModReadmePlanner.pickAsset(assets, preferDLL: false)?.name.contains("Steam") == true)
        let preset = ModPreset.builtIn[0]
        #expect(assets.filter { preset.matchesAsset(named: $0.name) }.count == 1)
    }

    @Test func readmeExtractToGameFolder() throws {
        let readme = "## Install\nExtract the zip into your Among Us folder. Make a copy of the game folder first."
        let plan = try #require(ModReadmePlanner.plan(readme: readme, release: release(["Mod.zip"])))
        #expect(plan.rule.mode == .extract)
        #expect(plan.rule.subpath.isEmpty)
        #expect(plan.rule.copyGame)
        #expect(plan.confident)
    }

    @Test func readmePluginDLL() throws {
        let readme = "Requires BepInEx. Put Mod.dll in BepInEx/plugins"
        let plan = try #require(ModReadmePlanner.plan(readme: readme, release: release(["Mod.dll", "Source.zip"])))
        #expect(plan.rule.mode == .copyFile)
        #expect(plan.rule.subpath == "BepInEx/plugins")
    }

    @Test func releaseNotesWinOverReadme() throws {
        let notes = "Install: put Mod.dll in BepInEx/plugins"
        let plan = try #require(ModReadmePlanner.plan(
            readme: "Old instructions", release: release(["Mod.dll", "Mod.zip"], notes: notes)
        ))
        #expect(plan.rule.subpath == "BepInEx/plugins")
        #expect(plan.reasons.contains { $0.contains("BepInEx/plugins") })
    }

    @Test func findsDependencies() {
        let text = """
        ## Requirements
        Requires [Reactor](https://github.com/NuclearPowered/Reactor) and BepInEx.
        Needs the Visual C++ runtime.
        See https://github.com/Me/ThisMod/releases for downloads.
        """
        let deps = ModDependencies.find(in: text, selfRepo: "Me/ThisMod", assetNames: ["ThisMod.dll"])
        #expect(deps.repos == ["NuclearPowered/Reactor"])
        #expect(deps.runtimeVerbs == ["vcrun2022"])
    }

    @Test func repoSlugParsing() {
        #expect(ModPreset.repoSlug(from: "https://github.com/AU-Avengers/TOU-Mira") == "AU-Avengers/TOU-Mira")
        #expect(ModPreset.repoSlug(from: "TheOtherRolesAU/TheOtherRoles.git") == "TheOtherRolesAU/TheOtherRoles")
        #expect(ModPreset.repoSlug(from: "nonsense") == nil)
    }

    @Test func installAndUninstallRestoresGameFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ModTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appending(path: "Game")
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        let exe = game.appending(path: "Game.exe")
        try Data("exe".utf8).write(to: exe)
        try Data("original".utf8).write(to: game.appending(path: "winhttp.dll"))

        // A zip with a wrapper folder holding a replacement winhttp.dll and a plugin.
        let staging = root.appending(path: "staging/Wrapper/BepInEx/plugins")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("mod".utf8).write(to: staging.appending(path: "Mod.dll"))
        try Data("loader".utf8).write(to: root.appending(path: "staging/Wrapper/winhttp.dll"))
        let zip = root.appending(path: "Mod.zip")
        try await ModInstaller.run("/usr/bin/ditto", [
            "-c", "-k", root.appending(path: "staging").path, zip.path
        ])

        let result = try await ModInstaller.installLocal(file: zip, gameExecutable: exe)
        #expect(Set(result.mod.files) == ["winhttp.dll", "BepInEx/plugins/Mod.dll"])
        #expect(try String(contentsOf: game.appending(path: "winhttp.dll"), encoding: .utf8) == "loader")
        #expect(ModInstaller.installedMods(in: game).count == 1)

        try ModInstaller.uninstall(result.mod, from: game)
        #expect(try String(contentsOf: game.appending(path: "winhttp.dll"), encoding: .utf8) == "original")
        #expect(!FileManager.default.fileExists(atPath: game.appending(path: "BepInEx/plugins/Mod.dll").path))
        #expect(ModInstaller.installedMods(in: game).isEmpty)
    }

    @Test func copyGameLeavesOriginalAlone() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ModTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appending(path: "Among Us")
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        let exe = game.appending(path: "Among Us.exe")
        try Data("exe".utf8).write(to: exe)
        let dll = root.appending(path: "Mod.dll")
        try Data("mod".utf8).write(to: dll)

        let rule = ModInstallRule(mode: .copyFile, copyGame: true)
        let result = try await ModInstaller.installLocal(file: dll, rule: rule, gameExecutable: exe)
        #expect(result.gameFolder.lastPathComponent == "Among Us - Mod")
        #expect(FileManager.default.fileExists(atPath: result.executable.path))
        #expect(!FileManager.default.fileExists(atPath: game.appending(path: "Mod.dll").path))
    }
}
