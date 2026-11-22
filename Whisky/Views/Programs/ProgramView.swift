//
//  ProgramView.swift
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

struct ProgramView: View {
    @ObservedObject var program: Program
    /// Opens the bottle's configuration page, where its audio settings live.
    var onOpenBottleConfig: (() -> Void)?
    @State private var programLoading: Bool = false
    @State private var cachedIconImage: Image?
    @State private var toast: ToastData?
    @State private var showTroubleshootingWizard: Bool = false
    @State private var hasActiveSession: Bool = false
    @AppStorage("configSectionExapnded") private var configSectionExpanded: Bool = true
    @AppStorage("envArgsSectionExpanded") private var envArgsSectionExpanded: Bool = true
    @AppStorage("modsSectionExpanded") private var modsSectionExpanded: Bool = true
    @AppStorage("overridesSectionExpanded") private var overridesSectionExpanded: Bool = false
    @AppStorage("consoleRunsSectionExpanded") private var consoleRunsSectionExpanded: Bool = false
    @State private var selectedRunId: UUID?
    @State private var modsChanged = 0

    private let sessionStore = TroubleshootingSessionStore()

    var body: some View {
        Form {
            if hasActiveSession {
                TroubleshootingEntryBanner(bannerType: .resumeSession) {
                    showTroubleshootingWizard = true
                }
            }
            Section {
                GameHeaderView(program: program, modsChanged: modsChanged) { launchProgram() }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            ModsSectionView(program: program, isExpanded: $modsSectionExpanded, modsChanged: $modsChanged)
            Section("program.config", isExpanded: $configSectionExpanded) {
                Picker("locale.title", selection: $program.settings.locale) {
                    ForEach(Locales.allCases, id: \.self) { locale in
                        Text(locale.pretty()).id(locale)
                    }
                }
                VStack {
                    HStack {
                        Text("program.args")
                        Spacer()
                    }
                    TextField("program.args", text: $program.settings.arguments)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .labelsHidden()
                }
            }
            EnvironmentArgView(program: program, isExpanded: $envArgsSectionExpanded)
            ProgramOverrideSettingsView(
                bottle: program.bottle,
                program: program,
                isExpanded: $overridesSectionExpanded,
                onOpenBottleConfig: onOpenBottleConfig
            )
            Section("console.title", isExpanded: $consoleRunsSectionExpanded) {
                ConsoleRunHistoryView(
                    program: program,
                    bottle: program.bottle,
                    selectedRunId: $selectedRunId
                )
                if let runId = selectedRunId,
                   let entry = findRunEntry(id: runId) {
                    ConsoleLogView(runEntry: entry, bottle: program.bottle)
                }
            }
        }
        .sheet(isPresented: $showTroubleshootingWizard) {
            TroubleshootingWizardView(
                bottle: program.bottle,
                program: program,
                entryContext: .program(programURL: program.url, bottleURL: program.bottle.url)
            )
        }
        .bottomBar {
            HStack {
                Spacer()
                Button(String(localized: "troubleshooting.entry.troubleshoot")) {
                    showTroubleshootingWizard = true
                }
                Button("button.showInFinder") {
                    NSWorkspace.shared.activateFileViewerSelecting([program.url])
                }
                Button("button.createShortcut") {
                    let panel = NSSavePanel()
                    let applicationDir = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask)[0]
                    let name = program.name.replacingOccurrences(of: ".exe", with: "")
                    panel.directoryURL = applicationDir
                    panel.canCreateDirectories = true
                    panel.allowedContentTypes = [UTType.applicationBundle]
                    panel.allowsOtherFileTypes = false
                    panel.isExtensionHidden = true
                    panel.nameFieldStringValue = name + ".app"
                    panel.begin { result in
                        if result == .OK {
                            if let url = panel.url {
                                let name = url.deletingPathExtension().lastPathComponent
                                Task(priority: .userInitiated) {
                                    await ProgramShortcut.createShortcut(program, app: url, name: name)
                                }
                            }
                        }
                    }
                }
                Button("button.run") {
                    launchProgram()
                }
                .disabled(programLoading)
                if programLoading {
                    Spacer()
                        .frame(width: 10)
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding()
        }
        .toast($toast)
        .toolbar {
            if let image = cachedIconImage {
                ToolbarItem(id: "ProgramViewIcon", placement: .navigation) {
                    image
                        .resizable()
                        .frame(width: 25, height: 25)
                        .padding(.trailing, 5)
                }
            } else {
                ToolbarItem(id: "ProgramViewIcon", placement: .navigation) {
                    Image(systemName: "app.dashed")
                        .resizable()
                        .frame(width: 25, height: 25)
                        .padding(.trailing, 5)
                }
            }
        }
        .navigationTitle(program.name)
        .formStyle(.grouped)
        .animation(.whiskyDefault, value: configSectionExpanded)
        .animation(.whiskyDefault, value: envArgsSectionExpanded)
        .animation(.whiskyDefault, value: overridesSectionExpanded)
        .animation(.whiskyDefault, value: consoleRunsSectionExpanded)
        .task {
            let icon = await IconCache.shared.iconOrFallback(for: program.url, peFile: program.peFile)
            self.cachedIconImage = Image(nsImage: icon)
        }
        .onAppear {
            hasActiveSession = sessionStore.hasActiveSession(for: program.bottle.url)
        }
    }

    private func findRunEntry(id: UUID) -> RunLogEntry? {
        let history = RunLogStore.load(for: program.name, in: program.bottle.url)
        return history.entries.first(where: { $0.id == id })
    }

    private func launchProgram() {
        programLoading = true
        Telemetry.capture(.firstProgramLaunchAttempted)
        // Capture modifier flags synchronously before entering async context
        let useTerminal = NSEvent.modifierFlags.contains(.shift)
        Task {
            let result = await program.launchWithUserMode(useTerminal: useTerminal) { contentType, sizeBytes in
                withAnimation {
                    toast = .clipboardCleared(contentType: contentType, sizeBytes: sizeBytes)
                }
            }
            withAnimation {
                toast = result.toastData
            }
            programLoading = false
        }
    }
}

/// The top of a game's page: its Steam artwork, its name, which mod is on,
/// and Play. A Steam game plays through Steam, which is what its sign-in needs.
struct GameHeaderView: View {
    @ObservedObject var program: Program
    /// Bumped by the Mods section whenever a mod is installed, switched or removed.
    var modsChanged: Int
    var onPlayDirect: () -> Void

    @State private var artwork: NSImage?
    @State private var steamAppId: Int?
    @State private var activeMod: String?
    @State private var launching = false

    private var title: String {
        program.name.replacingOccurrences(of: ".exe", with: "", options: [.caseInsensitive, .anchored, .backwards])
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let artwork {
                Color.clear
                    .overlay { Image(nsImage: artwork).resizable().scaledToFill() }
                    .clipped()
            } else {
                Rectangle().fill(.quaternary)
            }
            // Keeps the title readable on art we don't control.
            LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)

            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                    modLine
                }
                Spacer(minLength: 16)
                Button(action: play) {
                    Label("Play", systemImage: "play.fill")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(launching)
                .help(steamAppId == nil ? "Run \(program.name)" : "Start through Steam")
            }
            .padding(20)
            .foregroundStyle(.white)
        }
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task(id: "\(program.url.path)#\(modsChanged)") { await load() }
    }

    /// The signature detail: a dot and the mod's name whenever one is on.
    @ViewBuilder private var modLine: some View {
        if let activeMod {
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text(activeMod)
            }
            .font(.callout)
        } else {
            Text(steamAppId == nil ? "No mods" : "Steam · No mods")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func load() async {
        let bottleURL = program.bottle.url
        let gamePath = program.url.standardizedFileURL.path
        let game = SteamLibrary.enumerate(bottleURL: bottleURL).first {
            gamePath.hasPrefix($0.installURL.standardizedFileURL.path + "/")
        }
        steamAppId = game?.appId
        if let game, let root = SteamLibrary.detectInstall(bottleURL: bottleURL),
           let url = SteamLibrarySource.artworkURL(appID: game.appId, steamRoot: root),
           let sampled = await IconCache.shared.sampledArtwork(for: url) {
            artwork = sampled.image
        }
        let gameFolder = program.url.deletingLastPathComponent()
        let selected = game.flatMap { SteamModLauncher.selected(appId: $0.appId, bottleURL: bottleURL) }
        activeMod = (selected?.deletingLastPathComponent()
            ?? ModLoaderRedirect.activeModFolder(gameFolder: gameFolder, bottleURL: bottleURL))
            .flatMap { ModInstaller.installedMods(in: $0).first?.name }
    }

    private func play() {
        guard let appId = steamAppId else { onPlayDirect(); return }
        launching = true
        Task {
            if SteamModLauncher.selected(appId: appId, bottleURL: program.bottle.url) != nil {
                try? await SteamModLauncher.prepare(appId: appId, bottle: program.bottle)
            }
            do {
                try SteamLauncher.launch(appId: appId, bottle: program.bottle)
            } catch {
                onPlayDirect()
            }
            try? await Task.sleep(for: .seconds(3))
            launching = false
        }
    }
}
