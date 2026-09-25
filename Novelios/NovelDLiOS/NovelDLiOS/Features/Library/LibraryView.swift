import SwiftUI

/// The bookshelf. Cover-forward grid with a "continue" hero —
/// Kobo shelf geometry with Kindle home calmness.
struct LibraryView: View {
    @Environment(CoreClient.self) private var core
    @State private var refreshing = false
    @State private var importing = false
    @State private var importUrl = ""
    @State private var errorText: String?
    @State private var columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]

    private let progress = [\LibraryNovelItemBodyProgress]() // placeholder for type-checker

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SectionBanner(title: "Shelf", subtitle: "\(core.library.count) works")

                    if core.library.isEmpty {
                        emptyShelf
                    } else {
                        shelfGrid
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(AppPalette.canvas.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        importing = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            refreshing = true
                            defer { refreshing = false }
                            _ = try? await core.refreshLibrary()
                            await core.reloadLibrary()
                        }
                    } label: {
                        if refreshing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .refreshable { await core.reloadLibrary() }
            .alert("Add from URL", isPresented: $importing) {
                TextField("TOC URL", text: $importUrl)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Button("Fetch & Add") { Task { await importNovel() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Paste the table-of-contents URL of a supported site.")
            }
            .alert("Shelf", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )) {
                Button("OK", role: .cancel) { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
            .navigationDestination(for: LibraryNovelItem.self) { item in
                NovelDetailView(item: item)
            }
            .navigationDestination(for: ReaderRoute.self) { route in
                ReaderView(novelId: route.novelId, startAt: route.index, title: route.title)
            }
        }
        .task { await core.reloadLibrary() }
    }

    private var emptyShelf: some View {
        VStack(spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Your shelf is empty")
                .font(AppFont.serif(19))
            Text("Find works in Discover or paste a TOC URL with +.")
                .font(AppFont.ui(13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var shelfGrid: some View {
        LazyVGrid(columns: columns, spacing: 22) {
            ForEach(core.library) { item in
                NavigationLink(value: item) {
                    VStack(alignment: .leading, spacing: 8) {
                        CoverTile(title: item.title, author: item.author)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(AppFont.serif(14, weight: .medium))
                                .foregroundStyle(Color(red: 0.13, green: 0.12, blue: 0.1))
                                .lineLimit(2)
                            Text(item.author)
                                .font(AppFont.ui(11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            let total = max(item.episodeCount, 1)
                            let done = item.downloadedCount ?? 0
                            ReadingRibbon(value: Double(done) / Double(total))
                            Text("\(done)/\(total) episodes")
                                .font(AppFont.ui(10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func importNovel() async {
        let url = importUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        importUrl = ""
        guard !url.isEmpty else { return }
        do {
            let dir = CoreClient.libraryRoot()
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .path
            let toc = try await core.fetchToc(url: url, outputDir: dir)
            await core.reloadLibrary()
            _ = toc
        } catch {
            errorText = error.localizedDescription
        }
    }
}
