import AVFoundation
import CryptoKit
import DanmakuCore
import Foundation
import MPVUI
import Observation

@MainActor @Observable
final class PlayerModel {
    let player = MPVPlayer(configuration: .init(additionalOptions: [
        "slang": "zh-CN,zh,chi,zho,en,eng", "alang": "zh,zh-CN,chi,zho,en,eng", "sub-codepage": "utf8"
    ]))
    var title = "选择视频，带上弹幕"
    var mediaURL: URL?
    var error: String?
    var status = "支持本地视频、网络直链和 XML / JSON 弹幕"
    var comments: [DanmakuComment] = []
    var commentRevision = UUID()
    var settings: DanmakuSettings {
        didSet { if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "danmaku.settings") } }
    }
    var server: String { didSet { UserDefaults.standard.set(server, forKey: "danmaku.server") } }
    var alternateServer: String { didSet { UserDefaults.standard.set(alternateServer, forKey: "danmaku.alternateServer") } }
    var fallback: String { didSet { UserDefaults.standard.set(fallback, forKey: "danmaku.fallback") } }
    var isLoadingComments = false
    var sourceTitle = "尚未加载弹幕"
    var commentsFailed = false
    @ObservationIgnored private var retryCommentsAction: (@MainActor () -> Void)?
    @ObservationIgnored private var mediaID = UUID()
    @ObservationIgnored private var scopedURL: URL?
    @ObservationIgnored private var playbackURL: URL?
    var usesWebDAVCredentials = false
    @ObservationIgnored private var commentsTask: Task<Void, Never>?
    private var cacheURL: URL? {
        guard let mediaURL else { return nil }
        let hash = SHA256.hash(data: Data(mediaURL.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("Danmaku", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(hash + ".xml")
    }
    var service: DanmakuService { .init(server: server, alternateServer: alternateServer, fallback: fallback) }
    var position: Double { durationSeconds(player.position) }
    var duration: Double { durationSeconds(player.duration) }
    var visibleComments: [DanmakuComment] {
        guard settings.simplifiedChinese else { return comments }
        return comments.map {
            var item = $0
            item.text = item.text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? item.text
            return item
        }
    }

    init() {
        settings = UserDefaults.standard.data(forKey: "danmaku.settings")
            .flatMap { try? JSONDecoder().decode(DanmakuSettings.self, from: $0) } ?? .init()
        if UserDefaults.standard.integer(forKey: "danmaku.appearanceVersion") < 2 {
            settings = settings.migratingLegacyAppearance()
            // Initializer assignments do not call didSet; persist before marking migrated.
            if let data = try? JSONEncoder().encode(settings) {
                UserDefaults.standard.set(data, forKey: "danmaku.settings")
                UserDefaults.standard.set(2, forKey: "danmaku.appearanceVersion")
            }
        }
        server = UserDefaults.standard.string(forKey: "danmaku.server") ?? "https://danmaku-api.152468.xyz"
        alternateServer = UserDefaults.standard.string(forKey: "danmaku.alternateServer") ?? "https://danmaku-us.152468.xyz"
        fallback = UserDefaults.standard.string(forKey: "danmaku.fallback") ?? "https://dmku.hls.one"
    }

    func open(_ url: URL, playbackURL: URL? = nil) {
        commentsTask?.cancel(); isLoadingComments = false
        retryCommentsAction = nil; commentsFailed = false
        if let previous = scopedURL { previous.stopAccessingSecurityScopedResource(); scopedURL = nil }
        if url.isFileURL, url.startAccessingSecurityScopedResource() { scopedURL = url }
        mediaID = UUID(); mediaURL = url; error = nil
        self.playbackURL = playbackURL
        usesWebDAVCredentials = playbackURL?.user != nil
        comments = []; commentRevision = UUID(); sourceTitle = "尚未加载弹幕"
        title = url.lastPathComponent.isEmpty ? "网络视频" : url.lastPathComponent
        settings.delay = 0
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { self.error = "无法启用声音，请检查音频输出后重试。"; return }
        player.load(playbackURL ?? url)
        status = "正在打开视频；可搜索弹幕或导入文件"
        if let cacheURL, let data = try? Data(contentsOf: cacheURL),
           let cached = try? DanmakuParser.parse(data), !cached.isEmpty {
            comments = cached; sourceTitle = "已恢复此视频保存的弹幕"; commentRevision = UUID()
        }
    }

    func retryPlayback() {
        if let mediaURL { open(mediaURL, playbackURL: playbackURL) }
    }

    func openNetwork(_ value: String) {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            error = "请输入 HTTP 或 HTTPS 视频直链。网页地址不一定是可播放的视频直链。"; return
        }
        open(url)
    }

    func load(episode: EpisodeResult, anime: String, append: Bool) {
        retryCommentsAction = { [weak self] in self?.load(episode: episode, anime: anime, append: append) }
        let service = service
        loadComments(title: "\(anime) · \(episode.episodeTitle)", append: append) {
            .init(comments: try await service.comments(episode: episode.episodeId))
        }
    }

    func load(link: String, append: Bool, title: String? = nil) {
        retryCommentsAction = { [weak self] in self?.load(link: link, append: append, title: title) }
        let service = service
        loadComments(title: title ?? "链接弹幕", append: append) { try await service.commentsWithStatus(link: link) }
    }

    func importComments(_ url: URL, append: Bool = false) {
        retryCommentsAction = { [weak self] in self?.importComments(url, append: append) }
        loadComments(title: "本地弹幕 · \(url.lastPathComponent)", append: append) {
            try await Task.detached {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= DanmakuParser.maximumBytes else { throw DanmakuError.tooLarge }
                return DanmakuLoadResult(comments: try DanmakuParser.parse(Data(contentsOf: url)))
            }.value
        }
    }

    private func loadComments(title: String, append: Bool,
                              operation: @escaping @Sendable () async throws -> DanmakuLoadResult) {
        guard mediaURL != nil else { error = "请先打开一个视频，再为它加载弹幕。"; return }
        commentsTask?.cancel()
        let generation = mediaID
        isLoadingComments = true; error = nil; commentsFailed = false
        commentsTask = Task { [weak self] in
            do {
                let result = try await operation()
                let incoming = result.comments
                try Task.checkCancellation()
                guard let self, self.mediaID == generation else { return }
                guard !incoming.isEmpty else { throw DanmakuError.empty }
                let source = UUID().uuidString
                let identified = incoming.map { comment in
                    var comment = comment; comment.id = source + ":" + comment.id; return comment
                }
                self.comments = Array((append ? self.comments + identified : identified).prefix(DanmakuParser.maximumComments))
                self.sourceTitle = title; self.commentRevision = UUID()
                self.status = "已加载 \(self.comments.count) 条弹幕"
                if result.failedSegments > 0 {
                    self.status += "；\(result.failedSegments) 个分段未能读取，已保留成功部分，可重新选择此集重试"
                }
                if let url = self.cacheURL {
                    do { try DanmakuParser.xml(self.comments).write(to: url, options: .atomic) }
                    catch { self.status += "；本地保存失败，可手动导出" }
                }
                self.isLoadingComments = false
                self.retryCommentsAction = nil
            } catch {
                guard !Task.isCancelled, let self, self.mediaID == generation else { return }
                self.isLoadingComments = false
                self.commentsFailed = true
                self.error = DanmakuFailure.message(error)
            }
        }
    }

    func retryComments() {
        error = nil
        retryCommentsAction?()
    }

    func clearComments() {
        commentsTask?.cancel(); isLoadingComments = false
        retryCommentsAction = nil; commentsFailed = false
        comments = []; commentRevision = UUID(); sourceTitle = "尚未加载弹幕"
        if let cacheURL { try? FileManager.default.removeItem(at: cacheURL) }
    }
}

func durationSeconds(_ value: Duration) -> Double {
    Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18
}

func playbackTime(_ value: Double) -> String {
    guard value.isFinite, value >= 0 else { return "00:00" }
    let seconds = Int(value)
    if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
}
