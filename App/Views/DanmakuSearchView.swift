import SwiftUI

struct DanmakuSearchView: View {
    let model: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @State private var keyword = ""
    @State private var sourceLink = ""
    @State private var results: [AnimeResult] = []
    @State private var episodes: [EpisodeResult] = []
    @State private var selectedAnime: AnimeResult?
    @State private var append = false
    @State private var searching = false
    @State private var searched = false
    @State private var error: String?
    @State private var request: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("搜索作品名称", text: $keyword).submitLabel(.search).onSubmit { search() }
                        Button("搜索") { search() }.disabled(searching || keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Toggle("追加到已有弹幕", isOn: $append)
                }
                if searching { Section { ProgressView("正在获取…") } }
                if let error { Section { Text(error).foregroundStyle(.orange) } }
                if let anime = selectedAnime {
                    Section {
                        Button("返回作品列表", systemImage: "chevron.left") { request?.cancel(); searching = false; selectedAnime = nil; episodes = [] }
                        ForEach(episodes) { episode in
                            Button(episode.episodeTitle) { model.load(episode: episode, anime: anime.animeTitle, append: append); dismiss() }
                        }
                    } header: { Text(anime.animeTitle) }
                } else {
                    Section {
                        ForEach(results) { anime in
                            Button { select(anime) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(anime.animeTitle)
                                    if let count = anime.episodeCount { Text("\(count) 集").font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                        if searched && results.isEmpty && !searching && error == nil {
                            Text("没有匹配结果，换个名称或使用来源链接。").foregroundStyle(.secondary)
                        }
                    }
                }
                Section("从来源链接加载") {
                    TextField("视频页面或 XML / JSON 链接", text: $sourceLink, axis: .vertical)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("加载此链接的弹幕") { model.load(link: sourceLink.trimmingCharacters(in: .whitespacesAndNewlines), append: append); dismiss() }
                        .disabled(sourceLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.navigationTitle("搜索弹幕").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                .onDisappear { request?.cancel() }
        }
    }

    private func search() {
        request?.cancel(); selectedAnime = nil; episodes = []; searching = true; searched = true; error = nil
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let service = model.service
        request = Task { @MainActor in
            do {
                let found = try await service.search(query)
                try Task.checkCancellation()
                results = found; searching = false
            } catch {
                if !Task.isCancelled { self.error = "搜索失败，请检查服务地址或稍后重试。输入已保留。"; searching = false }
            }
        }
    }

    private func select(_ anime: AnimeResult) {
        request?.cancel(); selectedAnime = anime; episodes = []; searching = true; error = nil
        let service = model.service
        request = Task { @MainActor in
            do {
                let found = try await service.episodes(anime)
                try Task.checkCancellation()
                episodes = found; searching = false
                if found.isEmpty { error = "这个作品暂无可用集数，请选择其他结果。" }
            } catch {
                if !Task.isCancelled { self.error = "集数加载失败，可返回作品列表后重试。"; searching = false }
            }
        }
    }
}
