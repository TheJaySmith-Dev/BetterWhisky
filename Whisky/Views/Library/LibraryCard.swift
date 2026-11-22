//
//  LibraryCard.swift
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

extension Color {
    init(_ palette: IconPalette) {
        self.init(.sRGB, red: palette.red, green: palette.green, blue: palette.blue)
    }
}

/// Where an entry is in a launch.
enum LibraryEntryState: Equatable {
    /// Not started, or started and already exited.
    case idle
    /// Whisky has been asked to start it and Wine has not put a window up yet.
    case launching
    /// It has a process of its own in ``ProcessRegistry``.
    case running
}

/// One library entry, coloured by its own icon.
///
/// Landscape rather than the portrait box art other launchers use, because they
/// download 600x900 posters and we have a 32 to 256px icon out of the
/// executable. Stretching an icon into a poster looks broken; a wide card is the
/// shape an icon and a name actually want, and it leaves the icon at its native
/// size where it stays crisp.
struct LibraryCard: View {
    let item: LibraryEntry
    /// Only shown when there is more than one bottle, since with a single bottle
    /// the prefix is plumbing and naming it on every card is noise.
    let bottleName: String?
    let lastPlayed: Date?
    let state: LibraryEntryState
    let launch: () -> Void
    /// Opens the game's mod settings; nil for entries without mods.
    var onSettings: (() -> Void)?

    @State private var icon: Image?
    @State private var artwork: Image?
    @State private var logo: Image?
    @State private var palette: IconPalette = .neutral
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    /// Both stops are opaque. A gradient that fades towards transparent
    /// composites against the window, which is near-white in light mode, and
    /// the white label on top of that corner falls to about 2:1 contrast.
    private var backdrop: Color { Color(palette.deepened()) }
    private var backdropDeep: Color { Color(palette.deepened(toLuminance: 0.07)) }

    /// Taken from the palette rather than hardcoded, so the label cannot end up
    /// the same lightness as what is behind it if the deepening target moves.
    private var foreground: Color {
        palette.deepened().prefersLightForeground ? .white : .black
    }

    /// A launcher is named by what it is. A pin takes its name from the
    /// executable, which is how the Steam client ends up on screen as "steam".
    private var title: String { item.launcher?.displayName ?? item.name }

    /// The round controls (30pt) sit `controlInset` from the edges, and the
    /// card's corners are concentric with them: 15 + 6.
    static let controlInset: CGFloat = 6
    static let cornerRadius: CGFloat = 15 + controlInset

    var body: some View {
        Button(action: launch) {
            card
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) {
            // Settings in the top-left, Play in the top-right: the same round
            // control, shown together on hover.
            if let onSettings, isActive {
                Button(action: onSettings) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 13))
                        .frame(width: 30, height: 30)
                        .cardGlass(.circle, interactive: true)
                }
                .buttonStyle(.plain)
                .help("Mod settings")
                .padding(Self.controlInset)
                .transition(.opacity.combined(with: .scale))
            }
        }
        .focusable()
        .focused($isFocused)
        // The system ring is a rectangle around the button's frame, so on a
        // rounded card it draws a second, squarer outline outside the one below
        // that follows the card's own shape.
        .focusEffectDisabled()
        .onKeyPress(.return) {
            launch()
            return .handled
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) { isHovering = hovering }
        }
        .task(id: item.id) {
            await loadLogo()
            await loadIcon()
        }
        .accessibilityLabel(title)
        .accessibilityValue(Text(subtitle))
        .accessibilityHint(Text("library.card.hint"))
    }

    /// Hover is a mouse-only signal, so anything shown only on hover does not
    /// exist for somebody on the keyboard.
    private var isActive: Bool { isHovering || isFocused }

    private var card: some View {
        Group {
            if let logoView {
                logoCard(logoView)
            } else {
                artCard
            }
        }
        .frame(height: 132)
        .overlay(alignment: .topTrailing) {
            statusView.padding(Self.controlInset)
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(.primary.opacity(isActive ? 0.2 : 0.08), lineWidth: 1)
        }
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
    }

    /// A game with a logo: the logo alone, centred on a quiet surface.
    private func logoCard(_ logo: AnyView) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(.quaternary.opacity(isActive ? 1 : 0.7))
            logo
                .padding(.horizontal, 44)
                .padding(.vertical, 28)
        }
    }

    private var artCard: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [backdrop, backdropDeep],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let artwork {
                // Steam cached this art inside the bottle, so a Steam game shows
                // its own banner with nothing fetched. Sized by an empty layer
                // rather than by the image: scaledToFill on its own reports the
                // image's size upward and the card grows to fit it.
                Color.clear
                    .overlay {
                        artwork
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
                    .overlay {
                        // The scrim is what keeps the name readable over art we
                        // do not control.
                        LinearGradient(
                            colors: [.black.opacity(0.05), .black.opacity(0.75)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                    }
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    // The icon tile is the identity when there is no artwork.
                    // With artwork it would sit on top of the thing it stands in
                    // for, so it goes.
                    if artwork == nil {
                        iconView
                    }
                    Spacer()
                }
                Spacer(minLength: 8)
                if let modName = item.mod?.modName {
                    // The signature: a dot and the mod's name on every modded game.
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text(modName)
                    }
                    .font(.caption.weight(.medium))
                    .padding(.bottom, 2)
                }
                Text(item.mod?.modName != nil ? baseTitle : title)
                    .font(.headline)
                    .lineLimit(1)
                    // Tail, not middle: a game's name is recognisable from its
                    // start, and "The Elder Scro...Special Edition" reads worse
                    // than losing the edition suffix.
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(foreground.opacity(0.7))
                    .lineLimit(1)
            }
            .padding(14)
        }
        // Artwork brings its own scrim, so a card showing art is always dark
        // under the label whatever the sampled palette says.
        .foregroundStyle(artwork == nil ? foreground : .white)
    }

    /// The top-right corner: what it is doing, or the offer to start it.
    @ViewBuilder
    private var statusView: some View {
        switch state {
        case .launching:
            ProgressView()
                .controlSize(.small)
                .frame(width: 30, height: 30)
                .cardGlass(.circle)
                .help("library.card.launching")
        case .running:
            Label("library.card.running", systemImage: "circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption2)
                .imageScale(.small)
                .foregroundStyle(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .cardGlass(.capsule)
        case .idle:
            if isActive {
                Image(systemName: "play.fill")
                    .font(.system(size: 13))
                    .frame(width: 30, height: 30)
                    .cardGlass(.circle, interactive: true)
                    .transition(.opacity.combined(with: .scale))
            }
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon {
            icon
                .resizable()
                .frame(width: 44, height: 44)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.12))
                .frame(width: 44, height: 44)
        }
    }

    /// The game's or mod's own logo: from Steam's cache, the mod's repository,
    /// or, for Steam itself, the one that ships with the app.
    private var logoView: AnyView? {
        if item.launcher == .steam {
            return AnyView(Image("SteamLogo").resizable().renderingMode(.template).scaledToFit()
                .foregroundStyle(.primary))
        }
        guard let logo else { return nil }
        return AnyView(logo.resizable().scaledToFit())
    }

    /// A modded card shows the game's name, with the mod on the line above.
    private var baseTitle: String {
        guard let modName = item.mod?.modName else { return title }
        return title.replacingOccurrences(of: " · \(modName)", with: "")
    }

    /// Source first when it is not a pin, because "Steam" tells you why an entry
    /// is here at all, and a pin needs no explanation.
    private var subtitle: String {
        var parts: [String] = []
        if item.isLauncher {
            parts.append(String(localized: "library.card.launcher"))
        }
        if item.source == .steam {
            parts.append(String(localized: "library.source.steam"))
        }
        if let lastPlayed {
            parts.append(lastPlayed.formatted(.relative(presentation: .named)))
        } else {
            parts.append(String(localized: "library.card.neverRun"))
        }
        if let bottleName {
            parts.append(bottleName)
        }
        return parts.joined(separator: " · ")
    }

    /// Decoding and palette sampling both happen inside ``IconCache``, which is
    /// where the reasoning about repeating them lives.
    private func loadLogo() async {
        guard let url = item.logoURL,
              let image = await Task.detached(operation: { NSImage(contentsOf: url) }).value else { return }
        logo = Image(nsImage: image)
    }

    private func loadIcon() async {
        if let artworkURL = item.artworkURL,
           let sampled = await IconCache.shared.sampledArtwork(for: artworkURL) {
            artwork = Image(nsImage: sampled.image)
            // Still sampled: the border and the hover glow pick up the art's own
            // colour, so a card reads as one object rather than art in a frame.
            palette = sampled.palette
            return
        }
        guard let iconURL = item.iconURL else {
            palette = .neutral
            return
        }
        let sampled = await IconCache.shared.sampledIcon(for: iconURL)
        palette = sampled.palette
        icon = Image(nsImage: sampled.image)
    }
}

private extension View {
    /// Liquid Glass where the system has it, a plain material where it does not.
    /// The affordance matters more than the material, so the older path is a
    /// real control rather than nothing.
    @ViewBuilder
    func cardGlass(_ shape: some Shape, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.thinMaterial, in: shape)
        }
    }
}
