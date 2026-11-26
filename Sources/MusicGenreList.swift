import SwiftUI

struct MusicGenreList: View {
    @ObservedObject var library: LibraryModel
    let open: (MusicEntry) -> Void

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(library.entries) { genre in
                Button { open(genre) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "tag").foregroundStyle(.secondary).frame(width: 22)
                        Text(genre.title).font(.headline)
                        Spacer(minLength: 12)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 12)
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .combine)
                }
                #if os(tvOS)
                .buttonStyle(.bordered)
                #else
                .buttonStyle(.plain)
                #endif
                Divider()
            }
            if library.more && !library.busy && library.message == nil {
                Color.clear.frame(height: 1).accessibilityHidden(true)
                    .id(library.entries.count)
                    .onAppear { library.loadMore() }
            }
        }
    }
}
