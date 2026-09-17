import Kingfisher
import SwiftUI

/// Where a tapped album / artist / playlist goes. Pushed onto the Music tab's `NavigationStack`.
enum MusicRoute: Hashable {
    case browse(String)
}

/// Lets menus and context menus push a browse page. `NavigationLink` does not reliably fire from
/// inside `Menu` / `.contextMenu`, so those call `open(_:)` and `MusicScreen` appends to its path.
@available(iOS 17.0, *)
@Observable
@MainActor
final class MusicNavigator {
    private(set) var pending: (id: UUID, route: MusicRoute)?

    func open(_ browseID: String) {
        pending = (UUID(), .browse(browseID))
    }
}

/// Renders one `MusicShelf` in the layout YouTube Music uses for it: a horizontally scrolling
/// row of square tiles, a vertical list of song rows, or a two-column grid.
@available(iOS 17.0, *)
struct MusicShelfView: View {
    let shelf: MusicShelf
    /// Tracks that should be queued alongside a tapped song. Defaults to the shelf's own items.
    var queueContext: [MusicItem]? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch shelf.layout {
            case .carousel:
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(shelf.items) { item in
                            MusicTile(item: item, context: queueContext ?? shelf.items)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollClipDisabled()
            case .list:
                LazyVStack(spacing: 0) {
                    ForEach(shelf.items) { item in
                        MusicRow(item: item, context: queueContext ?? shelf.items)
                    }
                }
            case .grid:
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 18) {
                    ForEach(shelf.items) { item in
                        MusicTile(item: item, context: queueContext ?? shelf.items, fillsWidth: true)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        if !shelf.title.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    if let subtitle = shelf.subtitle, !subtitle.isEmpty {
                        Text(subtitle.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(shelf.title)
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                }
                Spacer()
                if let more = shelf.moreBrowseID {
                    NavigationLink(value: MusicRoute.browse(more)) {
                        Text("More")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .overlay(Capsule().stroke(.secondary.opacity(0.5), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

/// Square-art tile used in carousels and grids. Artists get a circular crop like YT Music.
@available(iOS 17.0, *)
struct MusicTile: View {
    let item: MusicItem
    let context: [MusicItem]
    var fillsWidth = false
    @Environment(PlayerStateManager.self) private var player

    private var side: CGFloat { 150 }

    var body: some View {
        Group {
            if item.isPlayable {
                Button { player.playMusic(item, in: context) } label: { label }
                    .buttonStyle(.plain)
                    .contextMenu { MusicItemMenu(item: item, context: context) }
            } else {
                NavigationLink(value: MusicRoute.browse(item.id)) { label }
                    .buttonStyle(.plain)
            }
        }
        .frame(width: fillsWidth ? nil : side)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 8) {
            MusicArtwork(url: item.thumbnailURL, kind: item.kind, size: fillsWidth ? nil : side)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}

/// One song / album / artist row.
@available(iOS 17.0, *)
struct MusicRow: View {
    let item: MusicItem
    let context: [MusicItem]
    var index: Int? = nil
    @Environment(PlayerStateManager.self) private var player

    private var isCurrent: Bool { player.currentVideo?.id == item.id }

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if item.isPlayable {
                    Button { player.playMusic(item, in: context) } label: { content }
                        .buttonStyle(.plain)
                } else {
                    NavigationLink(value: MusicRoute.browse(item.id)) { content }
                        .buttonStyle(.plain)
                }
            }
            .contextMenu { MusicItemMenu(item: item, context: context) }
            if item.isPlayable {
                Menu {
                    MusicItemMenu(item: item, context: context)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .padding(.trailing, 4)
            }
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            if let index {
                Text("\(index)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .trailing)
            }
            ZStack {
                MusicArtwork(url: item.thumbnailURL, kind: item.kind, size: 52)
                if isCurrent, item.isPlayable {
                    RoundedRectangle(cornerRadius: item.kind == .artist ? 26 : 6, style: .continuous)
                        .fill(.black.opacity(0.45))
                        .frame(width: 52, height: 52)
                    NowPlayingIndicator(videoID: item.id)
                        .frame(width: 20, height: 20)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    .lineLimit(1)
                if !item.subtitle.isEmpty || item.duration != nil {
                    Text(rowSubtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if !item.isPlayable {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, item.isPlayable ? 4 : 16)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var rowSubtitle: String {
        var parts: [String] = []
        if !item.subtitle.isEmpty { parts.append(item.subtitle) }
        if let duration = item.duration { parts.append(Self.format(duration)) }
        return parts.joined(separator: " • ")
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// Album art with the right crop for the item kind and a glyph placeholder.
@available(iOS 17.0, *)
struct MusicArtwork: View {
    let url: URL?
    let kind: MusicItem.Kind
    /// Fixed side in points, or `nil` to fill the available width as a square.
    let size: CGFloat?

    var body: some View {
        let shape: AnyShape = kind == .artist
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: size.map { $0 < 80 ? 6 : 10 } ?? 10, style: .continuous))
        Group {
            if let size {
                image(side: size)
                    .frame(width: size, height: size)
            } else {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { GeometryReader { proxy in image(side: proxy.size.width) } }
            }
        }
        .clipShape(shape)
        .overlay(shape.stroke(.primary.opacity(0.06), lineWidth: 0.5))
    }

    private func image(side: CGFloat) -> some View {
        KFImage(url)
            .thumbnail(size: CGSize(width: side, height: side)) {
                ZStack {
                    Color.gray.opacity(0.18)
                    Image(systemName: glyph)
                        .font(.system(size: max(14, side * 0.28)))
                        .foregroundStyle(.secondary)
                }
            }
            .resizable()
            .scaledToFill()
            .frame(width: side, height: side)
            .clipped()
    }

    private var glyph: String {
        switch kind {
        case .song: return "music.note"
        case .video: return "play.rectangle"
        case .album: return "square.stack"
        case .artist: return "person"
        case .playlist: return "music.note.list"
        }
    }
}

/// Shared actions for a song row / tile.
@available(iOS 17.0, *)
struct MusicItemMenu: View {
    let item: MusicItem
    let context: [MusicItem]
    @Environment(PlayerStateManager.self) private var player
    @Environment(MusicNavigator.self) private var navigator

    var body: some View {
        if item.isPlayable {
            Button { player.playMusic(item, in: context) } label: { Label("Play", systemImage: "play.fill") }
            Button { player.enqueueNext(item.asVideo) } label: { Label("Play next", systemImage: "text.insert") }
            Button { player.playMusic(item, in: [item]) } label: { Label("Start radio", systemImage: "dot.radiowaves.left.and.right") }
            Divider()
            if DownloadManager.shared.localFile(for: item.id) != nil {
                Button {} label: { Label("Downloaded", systemImage: "checkmark.circle") }
                    .disabled(true)
            } else {
                Button { PlayerStateManager.downloadForOffline(item) } label: { Label("Download", systemImage: "arrow.down.circle") }
            }
            if let artist = item.artistBrowseID {
                Button { navigator.open(artist) } label: { Label("Go to artist", systemImage: "person") }
            }
            if let playlist = item.playlistID, !playlist.hasPrefix("RD") {
                Button {
                    navigator.open(playlist.hasPrefix("VL") ? playlist : "VL" + playlist)
                } label: {
                    Label("Go to album", systemImage: "square.stack")
                }
            }
            ShareLink(item: URL(string: "https://music.youtube.com/watch?v=\(item.id)")!) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }
}
