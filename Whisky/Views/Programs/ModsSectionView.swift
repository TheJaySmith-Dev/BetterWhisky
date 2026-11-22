//
//  ModsSectionView.swift
//  Whisky
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

import SwiftUI
import UniformTypeIdentifiers
import WhiskyKit

/// The Mods section on a program's page: presets, mods from any GitHub repo,
/// and a drop target for local `.zip` and `.dll` files.
struct ModsSectionView: View { // swiftlint:disable:this type_body_length
    @ObservedObject var program: Program
    @Binding var isExpanded: Bool

    @State private var installed: [InstalledMod] = []
    @State private var latestVersions: [String: GitHubRelease] = [:]
    @State private var busy: String?
    @State private var repoInput = ""
    @State private var pendingPlan: PendingPlan?
    @State private var message: String?
    @State private var dropTargeted = false

    struct PendingPlan: Identifiable {
        let id = UUID()
        let repo: String
        let release: GitHubRelease
        let plan: ModInstallPlan
    }

    private var gameFolder: URL { program.url.deletingLastPathComponent() }
    private var presets: [ModPreset] { ModPreset.presets(for: program.url) }

    var body: some View {
        Section(String(localized: "Mods"), isExpanded: $isExpanded) {
            ForEach(presets) { preset in
                presetRow(preset)
            }

            ForEach(installed.filter { mod in !presets.contains { $0.repo == mod.repo } }) { mod in
                HStack {
                    VStack(alignment: .leading) {
                        Text(mod.name)
                        Text(mod.version).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { remove(mod) }
                }
            }

            HStack {
                TextField("GitHub repo", text: $repoInput, prompt: Text(verbatim: "owner/repo or GitHub link"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(planFromGitHub)
                Button("Read Install Steps", action: planFromGitHub)
                    .disabled(ModPreset.repoSlug(from: repoInput) == nil || busy != nil)
            }

            dropZone

            if let busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(busy).foregroundStyle(.secondary)
                }
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .task(id: program.url) { await refresh() }
        .sheet(item: $pendingPlan) { pending in
            planSheet(pending)
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func presetRow(_ preset: ModPreset) -> some View {
        let release = latestVersions[preset.repo]
        let current = installedPreset(preset)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                Group {
                    if let current {
                        Text("Installed \(current.mod.version)")
                    } else if let release {
                        Text("Latest \(release.tagName)")
                    } else {
                        Text(verbatim: preset.repo)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let release, release.isStale {
                    Text("Last release is over six months old and may not work with the current game version.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if let current {
                if let release, release.tagName != current.mod.version {
                    Button("Update") { installPreset(preset) }.disabled(busy != nil)
                }
                Button("Remove", role: .destructive) { remove(current.mod, in: current.folder) }
            } else {
                Button("Install Mod") { installPreset(preset) }.disabled(busy != nil)
            }
        }
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
            .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
            .frame(height: 64)
            .overlay {
                Label("Drop a mod .zip or .dll here", systemImage: "square.and.arrow.down")
                    .foregroundStyle(.secondary)
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in installDropped(url) }
                    }
                }
                return !providers.isEmpty
            }
    }

    private func planSheet(_ pending: PendingPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install \(pending.repo)?").font(.headline)
            Text("Release \(pending.release.tagName), file \(pending.plan.asset.name)")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(describe(pending.plan.rule)).bold()
                ForEach(pending.plan.reasons, id: \.self) { reason in
                    Text(verbatim: "“\(reason)”").font(.callout).foregroundStyle(.secondary)
                }
            }
            if !pending.plan.confident {
                Text("The README didn't say clearly how to install this, so this is a guess.")
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { pendingPlan = nil }
                Button("Install") {
                    pendingPlan = nil
                    install(
                        asset: pending.plan.asset, release: pending.release,
                        name: pending.repo.components(separatedBy: "/").last ?? pending.repo,
                        repo: pending.repo, rule: pending.plan.rule
                    )
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func describe(_ rule: ModInstallRule) -> String {
        let place = rule.subpath.isEmpty ? "the game folder" : rule.subpath
        let action = rule.mode == .extract ? "Unzip into \(place)" : "Copy the file into \(place)"
        return rule.copyGame ? "\(action) of a new copy of the game" : action
    }

    // MARK: Actions

    /// A preset may live in a copy of the game folder rather than this one.
    private func installedPreset(_ preset: ModPreset) -> (mod: InstalledMod, folder: URL)? {
        var folders = [gameFolder]
        if preset.install.copyGame, let copy = try? copyFolder(for: preset.name) { folders.insert(copy, at: 0) }
        for folder in folders {
            if let mod = ModInstaller.installedMods(in: folder).first(where: { $0.repo == preset.repo }) {
                return (mod, folder)
            }
        }
        return nil
    }

    private func copyFolder(for modName: String) throws -> URL {
        gameFolder.deletingLastPathComponent()
            .appending(path: "\(gameFolder.lastPathComponent) - \(ModInstaller.safeName(modName))")
    }

    private func refresh() async {
        installed = ModInstaller.installedMods(in: gameFolder)
        for preset in presets where latestVersions[preset.repo] == nil {
            latestVersions[preset.repo] = try? await GitHubReleases.latestRelease(repo: preset.repo)
        }
    }

    private func installPreset(_ preset: ModPreset) {
        Task {
            busy = "Checking \(preset.name)…"
            defer { busy = nil }
            do {
                let release = try await GitHubReleases.latestRelease(repo: preset.repo)
                latestVersions[preset.repo] = release
                guard let asset = release.assets.first(where: { preset.matchesAsset(named: $0.name) }) else {
                    message = "\(preset.name) \(release.tagName) has no file matching this preset."
                    return
                }
                install(asset: asset, release: release, name: preset.name, repo: preset.repo, rule: preset.install)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func planFromGitHub() {
        guard let repo = ModPreset.repoSlug(from: repoInput) else { return }
        Task {
            busy = "Reading \(repo) on GitHub…"
            defer { busy = nil }
            do {
                async let readme = GitHubReleases.readme(repo: repo)
                let release = try await GitHubReleases.latestRelease(repo: repo)
                guard let plan = ModReadmePlanner.plan(readme: try await readme, release: release) else {
                    message = "\(repo) \(release.tagName) has no .zip or .dll to install."
                    return
                }
                pendingPlan = PendingPlan(repo: repo, release: release, plan: plan)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func install(
        asset: GitHubRelease.Asset, release: GitHubRelease, name: String, repo: String, rule: ModInstallRule
    ) {
        Task {
            busy = "Installing \(name) \(release.tagName)…"
            defer { busy = nil }
            do {
                let result = try await ModInstaller.install(
                    asset: asset, version: release.tagName, name: name, repo: repo,
                    rule: rule, gameExecutable: program.url
                )
                finished(result)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func installDropped(_ file: URL) {
        Task {
            busy = "Installing \(file.lastPathComponent)…"
            defer { busy = nil }
            do {
                finished(try await ModInstaller.installLocal(file: file, gameExecutable: program.url))
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func finished(_ result: ModInstallResult) {
        if result.gameFolder != gameFolder {
            // The mod went into a copy of the game: pin the copy so it has its own launch button.
            let bottle = program.bottle
            if !bottle.settings.pins.contains(where: { $0.url == result.executable }) {
                bottle.settings.pins.append(PinnedProgram(
                    name: "\(program.name.replacingOccurrences(of: ".exe", with: "")) (\(result.mod.name))",
                    url: result.executable
                ))
            }
            message = "Installed \(result.mod.name) into “\(result.gameFolder.lastPathComponent)”. "
                + "It's pinned in the bottle. The first launch can take a few minutes."
        } else {
            message = "Installed \(result.mod.name) (\(result.mod.files.count) files)."
        }
        Task { await refresh() }
    }

    private func remove(_ mod: InstalledMod, in folder: URL? = nil) {
        do {
            try ModInstaller.uninstall(mod, from: folder ?? gameFolder)
            message = "Removed \(mod.name)."
        } catch {
            message = error.localizedDescription
        }
        Task { await refresh() }
    }
}
