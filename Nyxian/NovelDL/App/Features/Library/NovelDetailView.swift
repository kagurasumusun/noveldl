import SwiftUI

struct ReaderRoute: Hashable {
    let novelId: String
    let index: String
    let title: String
}

/// Novel detail — Kindle "book detail" layout: cover + facts,
/// Kobo chapter list with download state ticks.
struct NovelDetailView: View {
    let item: LibraryNovelItem

    @Environment(CoreClient.self) private var core: CoreClient
    @State private var detail: LibraryNovelDetail?
    @State private var busy = false
    @State private var errorText: String?
    @State private var episodesLimit = 0
    @State private var fromIndex = ""
    @State private var showOptions = false

    private struct ChapterGroup: Identifiable {
        let id: String
        let chapters: [ChapterMeta]
    }

    private var groupedChapters: [ChapterGroup] {
        let chapters = detail?.chapters ?? []
        var order: [String] = []
        var buckets: [String: [ChapterMeta]] = [:]
        for ch in chapters {
            let key = ch.chapter ?? ""
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(ch)
        }
        return order.map { ChapterGroup(id: $0, chapters: buckets[$0] ?? []) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                actions
                Divider().overlay(Color.black.opacity(0.08))
                chapterList
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, 10)
            .padding(.bottom, 40)
        }
        .background(AppPalette.canvas.ignoresSafeArea())
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Download", isPresented: $showOptions) {
            TextField("Episodes (0 = all)", text: Binding(
                get: { String(episodesLimit) },
                set: { episodesLimit = Int($0) ?? 0 }
            ))
            .keyboardType(.numberPad)
            TextField("From index", text: $fromIndex)
            Button("Bulk Download") { Task { await runDownload(mode: "bulk") } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Bulk downloads the selected episodes in one pass.")
        }
        .alert("Detail", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("OK", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        .task { await reload() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            CoverTile(title: item.title, author: item.author, width: 92)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(AppFont.serif(21, weight: .semibold))
                Text(item.author)
                    .font(AppFont.ui(14))
                    .foregroundStyle(.secondary)
                Text(item.domain)
                    .font(AppFont.ui(11, weight: .medium))
                    .foregroundStyle(AppPalette.gold)
                if let detail {
                    Text("\(detail.downloadedCount) of \(detail.novel.episodeCount) downloaded")
                        .font(AppFont.ui(12))
                        .foregroundStyle(.secondary)
                    ReadingRibbon(
                        value: Double(detail.downloadedCount) / Double(max(detail.novel.episodeCount, 1))
                    )
                    .frame(width: 140)
                }
            }
            Spacer()
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if let first = detail?.chapters.first(where: { $0.bodyDownloaded == true })
                ?? detail?.chapters.first {
                NavigationLink(
                    value: ReaderRoute(novelId: item.novelId, index: first.index, title: item.title)
                ) {
                    HStack(spacing: 6) {
                        Image(systemName: "book")
                        Text(detail?.chapters.contains(where: { $0.bodyDownloaded == true }) == true
                             ? "Continue Reading" : "Preview")
                    }
                    .font(AppFont.ui(15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(AppPalette.ember, in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
                }
            }
            HStack(spacing: 10) {
                QuietButton(title: busy ? "Working…" : "Download", systemImage: "arrow.down.circle") {
                    showOptions = true
                }
                .disabled(busy)
                QuietButton(title: "Export", systemImage: "square.and.arrow.up") {
                    Task { await exportZip() }
                }
            }
        }
    }

    private var chapterList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(groupedChapters) { group in
                if !group.id.isEmpty {
                    Text(group.id)
                        .font(AppFont.ui(12, weight: .semibold))
                        .foregroundStyle(AppPalette.gold)
                        .padding(.top, 18)
                        .padding(.bottom, 6)
                }
                ForEach(group.chapters, id: \.index) { ch in
                    NavigationLink(
                        value: ReaderRoute(novelId: item.novelId, index: ch.index, title: item.title)
                    ) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(ch.index)
                                .font(AppFont.ui(11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                            Text(ch.subtitle)
                                .font(AppFont.serif(15))
                                .foregroundStyle(Color(red: 0.13, green: 0.12, blue: 0.1))
                            Spacer()
                            if ch.bodyDownloaded == true {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(AppPalette.gold)
                            }
                            if let mark = ch.subupdate, !mark.isEmpty {
                                Text(mark == "revised" ? "改" : mark)
                                    .font(AppFont.ui(10, weight: .bold))
                                    .foregroundStyle(AppPalette.ember)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 3)
                                            .strokeBorder(AppPalette.ember.opacity(0.5), lineWidth: 1)
                                    )
                            }
                        }
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(Color.black.opacity(0.06))
                }
            }
        }
    }

    private func reload() async {
        do {
            detail = try await core.novelDetail(item.novelId)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func runDownload(mode: String) async {
        busy = true
        defer { busy = false }
        do {
            let options = CoreClient.DownloadOptions(
                url: item.tocUrl,
                outputDir: item.outputDir,
                episodes: episodesLimit,
                fromIndex: fromIndex,
                mode: mode
            )
            _ = try await core.download(options)
            await reload()
            await core.reloadLibrary()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func exportZip() async {
        do {
            let result = try await core.exportZip(novelId: item.novelId)
            errorText = "Exported \(result.files) files to \(result.zipPath)"
        } catch {
            errorText = error.localizedDescription
        }
    }
}
