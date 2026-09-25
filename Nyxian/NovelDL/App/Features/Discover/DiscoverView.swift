import SwiftUI

/// Discover — webnovels.jp meta search across the preset-defined sites.
struct DiscoverView: View {
    @Environment(CoreClient.self) private var core: CoreClient
    @State private var query = ""
    @State private var results: [SearchResultItem] = []
    @State private var searching = false
    @State private var errorText: String?
    @State private var sites: [SearchSite] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SectionBanner(
                        title: "Discover",
                        subtitle: sites.isEmpty
                            ? "Search across supported sites"
                            : "Searching \(sites.map(\.label).joined(separator: " · "))"
                    )

                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Title, author, keyword…", text: $query)
                            .textInputAutocapitalization(.never)
                            .onSubmit { Task { await run() } }
                        if searching { ProgressView().scaleEffect(0.8) }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.cardRadius)
                            .fill(.white)
                            .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
                    )

                    if results.isEmpty && !searching {
                        VStack(spacing: 10) {
                            Image(systemName: "sparkle.magnifyingglass")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                            Text("Find your next read")
                                .font(AppFont.serif(18))
                            Text("Results link straight to TOC pages you can add to the shelf.")
                                .font(AppFont.ui(12))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 50)
                    }

                    ForEach(results) { hit in
                        resultRow(hit)
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(AppPalette.canvas.ignoresSafeArea())
        }
        .task {
            sites = (try? await core.searchSites()) ?? []
        }
        .alert("Discover", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("OK", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    private func resultRow(_ hit: SearchResultItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(hit.title)
                        .font(AppFont.serif(16, weight: .medium))
                        .foregroundStyle(Color(red: 0.13, green: 0.12, blue: 0.1))
                    if let author = hit.author, !author.isEmpty {
                        Text(author)
                            .font(AppFont.ui(12))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let site = hit.site {
                    Text(site)
                        .font(AppFont.ui(10, weight: .semibold))
                        .foregroundStyle(AppPalette.gold)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(AppPalette.gold.opacity(0.5), lineWidth: 1)
                        )
                }
            }
            if let summary = hit.summary, !summary.isEmpty {
                Text(summary)
                    .font(AppFont.ui(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            HStack {
                if let updated = hit.updated {
                    Text(updated)
                        .font(AppFont.ui(10))
                        .foregroundStyle(.secondary)
                }
                if let count = hit.episodeCount {
                    Text("· \(count) eps")
                        .font(AppFont.ui(10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await add(hit) }
                } label: {
                    Text("Add to Shelf")
                        .font(AppFont.ui(12, weight: .semibold))
                        .foregroundStyle(AppPalette.ember)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: Metrics.cardRadius)
                .fill(.white)
                .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        )
    }

    private func run() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searching = true
        defer { searching = false }
        do {
            results = try await core.search(text)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func add(_ hit: SearchResultItem) async {
        do {
            let slug = hit.url
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "/", with: "_")
            let dir = CoreClient.libraryRoot()
                .appendingPathComponent(slug, isDirectory: true)
                .path
            _ = try await core.fetchToc(url: hit.url, outputDir: dir)
            await core.reloadLibrary()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
