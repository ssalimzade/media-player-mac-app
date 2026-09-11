import SwiftUI

/// A poster tile used in catalogue / search grids.
struct PosterCard: View {
    let item: CatalogueItem
    @EnvironmentObject var state: AppState
    @State private var hovering = false
    @State private var prefetch: Task<Void, Never>?

    /// Resume progress (0…1) for this title, if any — drawn as a bar along the poster bottom.
    private var progress: Double? { state.progress.fraction(forPage: item.url) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                PosterImage(urlString: item.image)
                    .aspectRatio(Theme.posterAspect, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.posterRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.posterRadius)
                        .strokeBorder(.white.opacity(0.06)))
                    .overlay(hoverOverlay)
                    .overlay(alignment: .bottom) { progressBar }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.posterRadius))

                if state.watched.isWatched(url: item.url) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, .green)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                if let r = item.rating {
                    Text(String(format: "%.1f", r))
                        .font(.caption2).bold()
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.65), in: Capsule())
                        .foregroundStyle(.yellow)
                        .padding(6)
                }
            }
            .scaleEffect(hovering ? 1.03 : 1)
            .shadow(color: .black.opacity(hovering ? 0.35 : 0),
                    radius: hovering ? 12 : 0, y: hovering ? 6 : 0)
            .animation(.easeOut(duration: 0.16), value: hovering)
            .onHover { inside in
                hovering = inside
                // Resting on a poster loads its title in the background, so the click opens it
                // at once. The short dwell ignores posters the pointer merely crosses.
                prefetch?.cancel()
                prefetch = inside ? Task {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if !Task.isCancelled { state.prefetchTitle(item.url) }
                } : nil
            }

            Text(item.title)
                .font(.callout).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let info = item.info {
                Text(info).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    /// Darkening scrim + centered play glyph shown on hover to signal "click to open".
    @ViewBuilder private var hoverOverlay: some View {
        if hovering {
            ZStack {
                LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.45)],
                               startPoint: .top, endPoint: .bottom)
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white, .white.opacity(0.28))
                    .shadow(radius: 6)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder private var progressBar: some View {
        if let progress {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.black.opacity(0.55))
                    Rectangle().fill(Theme.accent)
                        .frame(width: max(3, geo.size.width * progress))
                }
            }
            .frame(height: 3)
        }
    }
}

/// Async poster image with a graceful placeholder, backed by a memory cache for smooth scroll.
struct PosterImage: View {
    let urlString: String?

    var body: some View {
        CachedAsyncImage(url: urlString.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFill()
        } placeholder: { failed in
            placeholder(systemImage: failed ? "photo" : nil)
        }
        .background(Color(nsColor: .quaternarySystemFill))
    }

    @ViewBuilder private func placeholder(systemImage: String?) -> some View {
        ZStack {
            Color(nsColor: .quaternarySystemFill)
            if let systemImage {
                Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.tertiary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}

/// Reusable responsive grid of poster tiles that pushes DetailView on tap.
struct PosterGrid: View {
    let items: [CatalogueItem]
    @EnvironmentObject var state: AppState
    private let columns = [GridItem(.adaptive(minimum: Theme.tileMin, maximum: Theme.tileMax),
                                    spacing: 18)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 22) {
            ForEach(items) { item in
                NavigationLink(value: item) {
                    PosterCard(item: item)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    let saved = state.bookmarks.isBookmarked(item)
                    Button { state.bookmarks.toggle(item) } label: {
                        Label(saved ? "Remove from Watch Later" : "Add to Watch Later",
                              systemImage: saved ? "star.slash" : "star")
                    }
                    let watched = state.watched.isWatched(url: item.url)
                    Button {
                        if watched { state.watched.unmark(url: item.url) }
                        else { state.watched.mark(item: item) }
                    } label: {
                        Label(watched ? "Unmark watched" : "Mark as watched",
                              systemImage: watched ? "checkmark.circle" : "checkmark.circle.fill")
                    }
                }
            }
        }
        .padding(20)
    }
}

/// Standard centered status view for loading/error/empty, with an optional primary action.
struct CenteredMessage<Action: View>: View {
    let systemImage: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            let actionView = action()
            actionView.padding(.top, 6)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

extension CenteredMessage where Action == EmptyView {
    init(systemImage: String, title: String, subtitle: String? = nil) {
        self.init(systemImage: systemImage, title: title, subtitle: subtitle) { EmptyView() }
    }
}
