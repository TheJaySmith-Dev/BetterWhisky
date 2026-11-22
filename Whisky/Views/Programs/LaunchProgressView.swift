//
//  LaunchProgressView.swift
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
import WhiskyKit

/// What a launch screen needs to know about the game that's starting.
struct LaunchRequest: Identifiable {
    let id = UUID()
    let title: String
    let modName: String?
    let artworkURL: URL?
    let monitor: ModLaunchMonitor
    let steamWasRunning: Bool
}

/// Shown while a Steam game starts. Each step is ticked off from the log that
/// step writes, so a slow start shows where it is rather than a spinner.
struct LaunchProgressView: View {
    let request: LaunchRequest
    var onClose: () -> Void

    @State private var progress = LaunchProgress(stage: .steam)
    @State private var artwork: NSImage?
    @State private var now = Date()

    private struct Step: Identifiable {
        let id: LaunchProgress.Stage
        let title: String
        var detail: String?
    }

    private var steps: [Step] {
        var steps = [
            Step(id: .steam, title: request.steamWasRunning ? "Steam is running" : "Starting Steam"),
            Step(id: .launch, title: "Steam is starting \(request.title)")
        ]
        if let modName = request.modName {
            let detail = progress.stage == .mod && progress.pluginsTotal > 0
                ? "\(progress.pluginsLoaded) of \(progress.pluginsTotal) plugins" : nil
            steps.append(Step(id: .mod, title: "Loading \(modName)", detail: detail))
        }
        steps.append(Step(id: .window, title: "Opening the game"))
        return steps
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            VStack(alignment: .leading, spacing: 12) {
                ForEach(steps) { step in
                    stepRow(step)
                }
            }
            .padding(.horizontal, 4)
            HStack {
                Text(elapsed)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(progress.stage == .done ? "Done" : "Hide", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task { await watch() }
        .task { await loadArtwork() }
    }

    /// The one bright element: the game's own art, with its name and the mod on it.
    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            if let artwork {
                Color.clear
                    .overlay { Image(nsImage: artwork).resizable().scaledToFill() }
                    .clipped()
            } else {
                Rectangle().fill(.quaternary)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                Text(request.title).font(.title3.weight(.semibold))
                if let modName = request.modName {
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text(modName)
                    }
                    .font(.callout)
                }
            }
            .foregroundStyle(.white)
            .padding(16)
        }
        .frame(height: 132)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func stepRow(_ step: Step) -> some View {
        let state: Int = progress.stage > step.id ? 1 : (progress.stage == step.id ? 0 : -1)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                switch state {
                case 1: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case 0: ProgressView().controlSize(.small)
                default: Image(systemName: "circle").foregroundStyle(.quaternary)
                }
            }
            .frame(width: 16, height: 16)
            Text(step.title)
                .foregroundStyle(state < 0 ? .tertiary : (state == 0 ? .primary : .secondary))
            Spacer()
            if let detail = step.detail {
                Text(detail)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 20)
    }

    private var elapsed: String {
        let seconds = Int(now.timeIntervalSince(request.monitor.startedAt))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func watch() async {
        while !Task.isCancelled {
            let monitor = request.monitor
            let wasRunning = request.steamWasRunning
            let latest = await Task.detached { monitor.progress(steamWasRunning: wasRunning) }.value
            withAnimation(.easeOut(duration: 0.2)) { progress = latest }
            now = Date()
            if latest.stage == .done {
                // BepInEx writes the game's interop on the first start, so that's
                // when the mod can first be pre-compiled for the next one.
                let folder = request.monitor.gameFolder
                if request.modName != nil, ModPrecompiler.isNeeded(folder) {
                    Task.detached(priority: .utility) { try? await ModPrecompiler.run(folder) }
                }
                try? await Task.sleep(for: .seconds(2))
                onClose()
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func loadArtwork() async {
        guard let url = request.artworkURL else { return }
        artwork = await IconCache.shared.sampledArtwork(for: url)?.image
    }
}
