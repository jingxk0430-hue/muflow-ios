import SwiftUI

struct DanmakuConnectionView: View {
    let model: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @State private var results: [String: String] = [:]
    @State private var running = false
    @State private var task: Task<Void, Never>?
    private let routes = ["主弹幕服务", "备用弹幕服务", "影视目录"]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("在这台手机上检查搜索、剧集列表和弹幕下载。使用公开测试作品，不发送你的视频地址或 WebDAV 登录信息。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(running ? "正在检查…" : "开始检查") { check() }
                        .disabled(running).accessibilityIdentifier("checkDanmakuConnection")
                }
                ForEach(routes, id: \.self) { route in
                    Section(route) {
                        Text(results[route] ?? "尚未检查").font(.footnote).textSelection(.enabled)
                    }
                }
                Section {
                    Text("幕流 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")（\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")）")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("如果全部显示无法联网，请检查系统设置 → 幕流 → 无线数据；如果仅一个服务失败，可在播放设置中更换对应地址。")
                        .font(.footnote)
                }
            }
            .navigationTitle("弹幕连接检查").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .onDisappear { task?.cancel() }
        }
    }

    private func check() {
        task?.cancel(); running = true
        results = Dictionary(uniqueKeysWithValues: routes.map { ($0, "正在检查…") })
        let bases = [model.server, model.alternateServer]
        task = Task { @MainActor in
            await withTaskGroup(of: (String, String).self) { group in
                for (index, base) in bases.enumerated() {
                    let label = routes[index]
                    group.addTask {
                        guard !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            return (label, "未配置地址")
                        }
                        let service = DanmakuService(server: base, alternateServer: "", fallback: "")
                        var stage = "搜索"
                        do {
                            let matches = try await service.search("葬送的芙莉莲")
                            guard let anime = matches.first else { return (label, "搜索连接成功，但测试作品没有结果") }
                            stage = "剧集列表"
                            let episodes = try await service.episodes(anime)
                            guard let episode = episodes.first else { return (label, "搜索正常，但测试作品没有可用集数") }
                            stage = "弹幕下载"
                            let comments = try await service.comments(episode: episode.episodeId)
                            return (label, "搜索、剧集列表和弹幕下载成功，共 \(comments.count) 条测试弹幕。")
                        } catch { return (label, "\(stage)失败：\(DanmakuFailure.message(error))") }
                    }
                }
                group.addTask {
                    do {
                        let matches = try await TVSearchService().search("狂飙")
                        return ("影视目录", "连接成功，返回 \(matches.count) 个来源结果。")
                    } catch { return ("影视目录", DanmakuFailure.message(error)) }
                }
                for await (label, message) in group {
                    guard !Task.isCancelled else { group.cancelAll(); return }
                    results[label] = message
                }
            }
            if !Task.isCancelled { running = false }
        }
    }
}
