import SwiftUI

struct DanmakuSearchView: View {
    let model: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @State private var keyword = ""
    @State private var sourceLink = ""
    @State private var results: [AnimeResult] = []
    @State private var episodes: [EpisodeResult] = []
    @State private var selectedAnime: AnimeResult?
    @State private var films: [TVResult] = []
    @State private var selectedFilm: TVResult?
    @State private var filmEpisodes: [TVEpisode] = []
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
                } else if let film = selectedFilm {
                    Section {
                        Button("返回作品列表", systemImage: "chevron.left") {
                            request?.cancel(); searching = false; selectedFilm = nil; filmEpisodes = []
                        }
                        ForEach(filmEpisodes) { episode in
                            Button(episode.title) {
                                model.load(link: episode.url.absoluteString, append: append,
                                           title: "\(film.title) · \(episode.title) · \(film.siteName)")
                                dismiss()
                            }
                        }
                    } header: { Text("\(film.title) · \(film.siteName)") }
                } else {
                    Section("弹弹play") {
                        ForEach(results) { anime in
                            Button { select(anime) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(anime.animeTitle)
                                    if let count = anime.episodeCount { Text("\(count) 集").font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                        if searched && results.isEmpty && films.isEmpty && !searching && error == nil {
                            Text("没有匹配结果，换个名称或使用来源链接。").foregroundStyle(.secondary)
                        }
                    }
                    Section("影视 · 来源站点") {
                        ForEach(films) { film in
                            Button { select(film) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(film.title)
                                    Text("\(film.category) · \(film.year) · \(film.siteName)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section("从来源链接加载") {
                    TextField("视频页面或 XML / JSON 链接", text: $sourceLink, axis: .vertical)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("加载此链接的弹幕") { model.load(link: sourceLink.trimmingCharacters(in: .whitespacesAndNewlines), append: append); dismiss() }
                        .disabled(sourceLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section {
                    Text("搜索会同时查询弹弹play服务和影视目录。来源站点可直接获取弹幕，失败后再尝试配置的服务。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("搜索弹幕").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                .onDisappear { request?.cancel() }
        }
    }

    private func search() {
        request?.cancel(); selectedAnime = nil; episodes = []; selectedFilm = nil; filmEpisodes = []
        results = []; films = []; searching = true; searched = true; error = nil
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let service = model.service
        request = Task { @MainActor in
            await withTaskGroup(of: SearchOutcome.self) { group in
                group.addTask {
                    do { return .anime(try await service.search(query)) }
                    catch { return .failed("弹弹play搜索暂时不可用") }
                }
                group.addTask {
                    do { return .films(try await TVSearchService().search(query)) }
                    catch { return .failed("影视目录暂时不可用") }
                }
                var errors: [String] = []
                for await outcome in group {
                    guard !Task.isCancelled else { group.cancelAll(); return }
                    switch outcome {
                    case .anime(let items): results = items
                    case .films(let items): films = items
                    case .failed(let message): errors.append(message)
                    }
                }
                guard !Task.isCancelled else { return }
                searching = false
                if !errors.isEmpty { error = errors.joined(separator: "；") + "，输入已保留，可重试或使用其他来源。" }
            }
        }
    }

    private func select(_ film: TVResult) {
        request?.cancel(); selectedAnime = nil; selectedFilm = film; filmEpisodes = []; searching = true; error = nil
        request = Task { @MainActor in
            do {
                let found = try await TVSearchService().episodes(film)
                try Task.checkCancellation()
                filmEpisodes = found; searching = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "影视集数未能加载，可返回列表选择其他来源或重试。"; searching = false
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
                if !Task.isCancelled {
                    self.error = ((error as? LocalizedError)?.errorDescription ?? "集数加载失败，请检查网络。") + " 可返回作品列表后重试。"
                    searching = false
                }
            }
        }
    }
}

private enum SearchOutcome: Sendable {
    case anime([AnimeResult]), films([TVResult]), failed(String)
}
