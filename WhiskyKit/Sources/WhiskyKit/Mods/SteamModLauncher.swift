//
//  SteamModLauncher.swift
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

/// Lets Steam start a modded copy of a game while keeping Steam's sign-in.
///
/// Some games (Among Us) only sign in when Steam itself starts them, so a mod
/// that needs an older game version can't just run its own copy. Instead the
/// game's Steam launch option is set, once, to a small script in the bottle:
/// `C:\BetterWhisky\launch-<appid>.bat %command%`. Each time Steam starts the
/// game the script reads `target-<appid>.txt`. When it names an executable
/// (a mod's frozen copy of the game) the script runs that; when it's missing
/// the script runs `%command%`, the game Steam installed. Switching versions is
/// writing or deleting that one file: no Steam restart, nothing moved.
public enum SteamModLauncher {
    static func folder(_ bottleURL: URL) -> URL {
        bottleURL.appending(path: "drive_c/BetterWhisky")
    }

    static func scriptURL(_ bottleURL: URL, appId: Int) -> URL {
        folder(bottleURL).appending(path: "launch-\(appId).bat")
    }

    static func targetURL(_ bottleURL: URL, appId: Int) -> URL {
        folder(bottleURL).appending(path: "target-\(appId).txt")
    }

    static func launchOption(appId: Int) -> String {
        #"C:\BetterWhisky\launch-\#(appId).bat %command%"#
    }

    /// Picks what Steam starts next time: `executable` (inside the bottle), or
    /// the game Steam installed when nil.
    public static func select(_ executable: URL?, appId: Int, bottleURL: URL) throws {
        try writeScript(appId: appId, bottleURL: bottleURL)
        let target = targetURL(bottleURL, appId: appId)
        guard let executable else {
            try? FileManager.default.removeItem(at: target)
            return
        }
        guard let path = ModLoaderRedirect.windowsPath(executable, bottleURL: bottleURL) else {
            throw ModLoaderError.outsideBottle(executable)
        }
        try Data(path.utf8).write(to: target, options: .atomic)
    }

    /// The executable Steam will start, when a modded copy is selected.
    public static func selected(appId: Int, bottleURL: URL) -> URL? {
        guard let data = try? Data(contentsOf: targetURL(bottleURL, appId: appId)),
              let path = String(data: data, encoding: .utf8) else { return nil }
        return ModLoaderRedirect.unixPath(path, bottleURL: bottleURL)
    }

    /// The "Reduce memory use" setting for modded starts; on unless turned off.
    public static let reduceMemoryKey = "modsReduceMemory"
    static var reduceMemory: Bool {
        UserDefaults.standard.object(forKey: reduceMemoryKey) as? Bool ?? true
    }

    /// Rewrites every launcher script in the bottle, after a setting changes.
    public static func refreshScripts(bottleURL: URL) {
        let path = folder(bottleURL).path(percentEncoded: false)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        for name in names where name.hasPrefix("launch-") && name.hasSuffix(".bat") {
            if let appId = Int(name.dropFirst("launch-".count).dropLast(".bat".count)) {
                try? writeScript(appId: appId, bottleURL: bottleURL)
            }
        }
    }

    static func writeScript(appId: Int, bottleURL: URL) throws {
        try FileManager.default.createDirectory(at: folder(bottleURL), withIntermediateDirectories: true)
        let target = #"C:\BetterWhisky\target-\#(appId).txt"#
        let script = [
            "@echo off",
            "setlocal",
            // Modded copies run their mods on .NET: keep its heap smaller. A
            // plain game doesn't run .NET, so this changes nothing for it.
            reduceMemory ? #"if exist "\#(target)" set "DOTNET_GCConserveMemory=7""# : "rem memory: default",
            #"set "TARGET=""#,
            #"if exist "\#(target)" set /p TARGET=<"\#(target)""#,
            "if defined TARGET (",
            #"  for %%F in ("%TARGET%") do cd /d "%%~dpF""#,
            #"  "%TARGET%""#,
            ") else (",
            "  %*",
            ")"
        ].joined(separator: "\r\n") + "\r\n"
        try Data(script.utf8).write(to: scriptURL(bottleURL, appId: appId), options: .atomic)
    }

    // MARK: Steam's launch option

    /// Every signed-in Steam account's `localconfig.vdf` in the bottle.
    static func localConfigs(bottleURL: URL) -> [URL] {
        guard let steam = SteamLibrary.detectInstall(bottleURL: bottleURL) else { return [] }
        let userdata = steam.appending(path: "userdata")
        let users = (try? FileManager.default.contentsOfDirectory(at: userdata, includingPropertiesForKeys: nil)) ?? []
        return users.map { $0.appending(path: "config/localconfig.vdf") }
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    /// Whether the game's launch option already points at the script, for every account.
    public static func isLaunchOptionSet(appId: Int, bottleURL: URL) -> Bool {
        let configs = localConfigs(bottleURL: bottleURL)
        return !configs.isEmpty && configs.allSatisfy { url in
            (try? String(contentsOf: url, encoding: .utf8)).map {
                $0.contains("launch-\(appId).bat")
            } ?? false
        }
    }

    /// Writes the launch option into each account's config. Steam must not be
    /// running: it keeps the config in memory and writes it back on exit.
    public static func setLaunchOption(appId: Int, bottleURL: URL) throws {
        let value = launchOption(appId: appId).replacingOccurrences(of: #"\"#, with: #"\\"#)
        for url in localConfigs(bottleURL: bottleURL) {
            let text = try String(contentsOf: url, encoding: .utf8)
            let backup = url.appendingPathExtension("betterwhisky-backup")
            if !FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)) {
                try text.write(to: backup, atomically: true, encoding: .utf8)
            }
            try setOption(value, appId: appId, in: text).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Puts `"LaunchOptions" "<value>"` into the app's block of a localconfig.vdf.
    static func setOption(_ value: String, appId: Int, in text: String) -> String {
        let line = "\t\t\t\t\t\t\"LaunchOptions\"\t\t\"\(value)\""
        guard let key = text.range(of: "\"\(appId)\""),
              let open = text.range(of: "{", range: key.upperBound..<text.endIndex),
              let close = text.range(of: "}", range: open.upperBound..<text.endIndex)
        else { return text }
        var block = String(text[open.upperBound..<close.lowerBound])
        block = block.components(separatedBy: "\n")
            .filter { !$0.contains("\"LaunchOptions\"") }
            .joined(separator: "\n")
        block = "\n" + line + (block.hasPrefix("\n") ? block : "\n" + block)
        return String(text[..<open.upperBound]) + block + String(text[close.lowerBound...])
    }

    /// Makes sure Steam will run the script for `appId`. The first time, that
    /// means closing Steam for a moment, because it keeps its config in memory.
    @MainActor
    public static func prepare(appId: Int, bottle: Bottle) async throws {
        try writeScript(appId: appId, bottleURL: bottle.url)
        guard !isLaunchOptionSet(appId: appId, bottleURL: bottle.url) else { return }
        if await isSteamRunning(), let steam = SteamLibrary.detectInstall(bottleURL: bottle.url) {
            _ = try? await Wine.runProgram(at: steam.appending(path: "steam.exe"), args: ["-shutdown"], bottle: bottle)
            for _ in 0..<60 where await isSteamRunning() {
                try await Task.sleep(for: .seconds(1))
            }
        }
        try setLaunchOption(appId: appId, bottleURL: bottle.url)
    }

    /// BepInEx starts from its own winhttp.dll, which Wine skips for its
    /// built-in one unless told otherwise. Steam launches take a game's DLL
    /// settings from the game Steam installed, keyed by executable name, so the
    /// setting goes there: it then covers the modded copy too, and the plain
    /// game, which has no winhttp.dll of its own, keeps Wine's.
    @MainActor
    public static func ensureLoaderOverride(gameExecutable: URL, bottle: Bottle) {
        let program = bottle.programs.first { $0.url == gameExecutable } ?? Program(url: gameExecutable, bottle: bottle)
        var overrides = program.settings.overrides ?? ProgramOverrides()
        var dlls = overrides.dllOverrides ?? []
        guard !dlls.contains(where: { $0.dllName.lowercased() == "winhttp" && $0.mode == .nativeThenBuiltin }) else {
            return
        }
        dlls.removeAll { $0.dllName.lowercased() == "winhttp" }
        dlls.append(DLLOverrideEntry(dllName: "winhttp", mode: .nativeThenBuiltin))
        overrides.dllOverrides = dlls
        program.settings.overrides = overrides
    }

    /// Starts Steam quietly in each bottle that has it, so it's signed in by the
    /// time a game is launched. A cold start under Wine takes a minute or two,
    /// most of the wait before a game appears; a running client hands the game
    /// over in seconds. Does nothing where Steam is already running.
    @MainActor
    public static func warmUp(bottles: [Bottle]) async {
        guard !(await isSteamRunning()) else { return }
        for bottle in bottles {
            guard let steam = SteamLibrary.detectInstall(bottleURL: bottle.url),
                  !SteamLibrary.enumerate(bottleURL: bottle.url).isEmpty else { continue }
            SteamLauncher.startClient(steamExe: steam.appending(path: "steam.exe"), bottle: bottle)
            return
        }
    }

    /// Whether the bottle's Steam client is running.
    public static func isSteamRunning() async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "command"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let lines = (String(bytes: data, encoding: .utf8) ?? "").lowercased().components(separatedBy: "\n")
        return lines.contains { $0.hasPrefix("c:") && $0.contains(#"\steam\steam.exe"#) }
    }
}
