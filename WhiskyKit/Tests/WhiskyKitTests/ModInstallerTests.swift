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

    @Test func loaderRedirectPointsGameAtModFolder() throws {
        let bottle = FileManager.default.temporaryDirectory.appending(path: "ModTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: bottle) }
        let common = bottle.appending(path: "drive_c/Program Files (x86)/Steam/steamapps/common")
        let game = common.appending(path: "Among Us")
        let mod = ModInstaller.modFolder(for: "Town of Us: Mira", game: game)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mod, withIntermediateDirectories: true)
        try Data("theirs".utf8).write(to: game.appending(path: "winhttp.dll"))
        try Data("doorstop".utf8).write(to: mod.appending(path: "winhttp.dll"))
        try """
        [General]
        enabled = true
        target_assembly = BepInEx\\core\\BepInEx.Unity.IL2CPP.dll
        [Il2Cpp]
        coreclr_path = dotnet\\coreclr.dll
        corlib_dir = dotnet
        """.write(to: mod.appending(path: "doorstop_config.ini"), atomically: true, encoding: .utf8)

        try ModLoaderRedirect.activate(modFolder: mod, gameFolder: game, bottleURL: bottle)
        let config = try String(contentsOf: game.appending(path: "doorstop_config.ini"), encoding: .utf8)
        let base = #"C:\Program Files (x86)\Steam\steamapps\common\Among Us Mods\Town of Us- Mira"#
        #expect(config.contains("target_assembly = " + base + #"\BepInEx\core\BepInEx.Unity.IL2CPP.dll"#))
        #expect(config.contains("corlib_dir = " + base + #"\dotnet"#))
        #expect(ModLoaderRedirect.activeModFolder(gameFolder: game, bottleURL: bottle)?.lastPathComponent
            == mod.lastPathComponent)

        try ModLoaderRedirect.deactivate(gameFolder: game)
        #expect(ModLoaderRedirect.activeModFolder(gameFolder: game, bottleURL: bottle) == nil)
        // Still recognised as this mod's loader when switched off, so Remove cleans it up.
        #expect(ModLoaderRedirect.pointsAt(mod, gameFolder: game, bottleURL: bottle))

        try ModLoaderRedirect.remove(gameFolder: game)
        #expect(try String(contentsOf: game.appending(path: "winhttp.dll"), encoding: .utf8) == "theirs")
        #expect(!FileManager.default.fileExists(atPath: game.appending(path: "doorstop_config.ini").path))
    }

    @Test func readsRequiredGameVersions() {
        let tou = #"<img alt="Latest AU Version" src="https://badgen.net/static/AmongUs/2026.9.29/yellow">"#
        #expect(ModGameVersion.required(in: tou, modVersion: "1.7.9-beta2") == "2026.9.29")
        let tor = """
        | Among Us - Version| Mod Version | Link |
        | 2024.11.26| v4.8.0| [Download](https://example.com/v4.8.0/TheOtherRoles.zip)
        | 2024.3.5s| v4.5.3| [Download](https://example.com/v4.5.3/TheOtherRoles.zip)
        """
        #expect(ModGameVersion.required(in: tor, modVersion: "v4.8.0") == "2024.11.26")
        #expect(ModGameVersion.required(in: tor, modVersion: "v4.5.3") == "2024.3.5")
        #expect(ModGameVersion.matches("2024.3.5s", "2024.03.05"))
        #expect(!ModGameVersion.matches("2024.11.26", "2026.9.29"))
        // Unity's own version must not be taken for the game's.
        #expect(ModGameVersion.versions(in: "2022.3.44f1 2026.9.29") == ["2026.9.29"])
    }

    @Test func setsSteamLaunchOption() {
        let config = "\"apps\"\n{\n\t\"945360\"\n\t{\n\t\t\"LastPlayed\"\t\t\"1\"\n"
            + "\t\t\"LaunchOptions\"\t\t\"old\"\n\t}\n}\n"
        let option = #"C:\\BetterWhisky\\launch-945360.bat %command%"#
        let updated = SteamModLauncher.setOption(option, appId: 945360, in: config)
        #expect(updated.contains("LaunchOptions") && updated.contains("launch-945360.bat %command%"))
        #expect(!updated.contains("old"))
        #expect(updated.contains("LastPlayed"))
    }

    @Test func decidesWhatToDoWithAModRelease() {
        typealias Version = ModGameVersion
        // First install, mod matches the game: clone it.
        #expect(Version.decide(required: "2026.9.29", game: "2026.9.29", copy: nil, hasCopy: false)
            == .install(freshCopy: true))
        // First install, mod is behind the game: nothing to clone from.
        #expect(Version.decide(required: "2024.11.26", game: "2026.9.29", copy: nil, hasCopy: false)
            == .blocked(required: "2024.11.26", game: "2026.9.29"))
        // Game updated, mod hasn't: keep the frozen copy.
        #expect(Version.decide(required: "2026.9.29", game: "2026.12.1", copy: "2026.9.29", hasCopy: true)
            == .install(freshCopy: false))
        // Mod caught up with the new game: re-clone the new game.
        #expect(Version.decide(required: "2026.12.1", game: "2026.12.1", copy: "2026.9.29", hasCopy: true)
            == .install(freshCopy: true))
        // A release for some other version: leave things alone.
        #expect(Version.decide(required: "2025.1.1", game: "2026.12.1", copy: "2026.9.29", hasCopy: true)
            == .keep(required: "2025.1.1"))
    }
}
