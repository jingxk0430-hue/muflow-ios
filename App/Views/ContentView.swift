import DanmakuCore
import MPVUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: PlayerModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var importingFile = false
    @State private var importKind = FileImportKind.video
    @State private var showingURL = false
    @State private var showingSearch = false
    @State private var showingSettings = false
    @State private var showingWebDAV = false
    @State private var exporting = false
    @State private var fullscreen = false
    @State private var controlsVisible = true
    @State private var networkURL = ""
    @State private var networkError: String?
    @State private var seekPosition: Double?

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let landscape = geometry.size.width > geometry.size.height
                VStack(spacing: 0) {
                    videoSurface
                        .frame(maxWidth: .infinity)
                        .frame(height: fullscreen || landscape ? geometry.size.height : geometry.size.width * 9 / 16)
                    if !fullscreen && !landscape { libraryControls.padding(20) }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color(red: 0.04, green: 0.05, blue: 0.08))
            }
            .navigationTitle(fullscreen ? "" : "幕流")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(fullscreen ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("设置", systemImage: "slider.horizontal.3") { showingSettings = true }
                }
            }
            .sheet(isPresented: $showingURL) { urlSheet }
            .sheet(isPresented: $showingSearch) { DanmakuSearchView(model: model) }
            .sheet(isPresented: $showingSettings) { SettingsView(model: model) }
            .sheet(isPresented: $showingWebDAV) { WebDAVView(model: model) }
            // One presentation host for every import. Stacking fileImporter modifiers
            // on the same view can leave the earlier import buttons without a dialog.
            .fileImporter(isPresented: $importingFile, allowedContentTypes: importKind.contentTypes,
                          onCompletion: handleImport)
            .fileExporter(isPresented: $exporting, document: DanmakuDocument(data: DanmakuParser.xml(model.comments)),
                          contentType: .xml, defaultFilename: "弹幕.xml") { result in
                if case .failure = result { model.error = "弹幕导出未完成，请重试。" }
            }
            .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                if model.commentsFailed { Button("重试弹幕") { model.retryComments() } }
                Button("知道了", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
            .onChange(of: scenePhase) { _, phase in
                // Pause in the background; resume only when the user chooses to play.
                if phase != .active { model.player.pause() }
            }
        }
        .tint(.mint)
    }

    private var videoSurface: some View {
        ZStack {
            Color.black
            if model.mediaURL != nil {
                MPVVideoPlayer(player: model.player)
                DanmakuOverlay(model: model)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 44)).foregroundStyle(.mint)
                    Text("把喜欢的视频，带到这里").font(.headline)
                    Text("打开视频后，可搜索或导入弹幕").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if model.player.state == .loading || model.player.state == .buffering { ProgressView().tint(.white) }
            if controlsVisible, model.mediaURL != nil {
                VStack(spacing: 0) {
                    HStack {
                        Text(model.title).font(.subheadline).lineLimit(1)
                        Spacer()
                        Button { model.settings.enabled.toggle() } label: {
                            Image(systemName: model.settings.enabled ? "text.bubble.fill" : "text.bubble")
                        }.accessibilityLabel("弹幕开关")
                        Button { showingSearch = true } label: { Image(systemName: "magnifyingglass") }
                            .padding(.leading, 12).accessibilityLabel("搜索弹幕")
                    }.padding().background(.black.opacity(0.45))
                    Spacer()
                    HStack(spacing: 32) {
                        Button { model.player.seek(by: .seconds(-10)) } label: { Image(systemName: "gobackward.10") }
                        Button { model.player.togglePlayback() } label: {
                            Image(systemName: model.player.isPaused ? "play.fill" : "pause.fill").font(.system(size: 30))
                        }.accessibilityLabel(model.player.isPaused ? "播放" : "暂停")
                        Button { model.player.seek(by: .seconds(10)) } label: { Image(systemName: "goforward.10") }
                    }.font(.title2).padding(14).background(.black.opacity(0.35), in: Capsule())
                    Spacer()
                    playbackControls.padding(12).background(.black.opacity(0.5))
                }.foregroundStyle(.white)
            }
            if let error = model.player.lastError {
                VStack(spacing: 12) {
                    Text("视频未能播放").font(.headline)
                    Text(model.usesWebDAVCredentials ? "请检查服务器连接与媒体读取权限，再尝试重试。" : error.message)
                        .font(.caption).lineLimit(3)
                    Button("重试") { model.retryPlayback() }
                }.padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { controlsVisible.toggle() }
    }

    private var playbackControls: some View {
        VStack(spacing: 6) {
            Slider(value: Binding(get: { min(max(0, seekPosition ?? model.position), max(1, model.duration)) }, set: { seekPosition = $0 }),
                   in: 0...max(1, model.duration), onEditingChanged: { editing in
                if !editing, let position = seekPosition {
                    model.player.seek(to: .seconds(position)); seekPosition = nil
                }
            }).disabled(!model.player.isSeekable)
            HStack {
                Text(playbackTime(seekPosition ?? model.position) + " / " + playbackTime(model.duration))
                    .font(.caption.monospacedDigit())
                Spacer()
                Menu {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 2, 3], id: \.self) { rate in
                        Button("\(rate.formatted())×") { model.player.setPlaybackRate(rate) }
                    }
                } label: { Text("\(model.player.playbackRate.formatted())×").font(.caption.bold()) }
                tracksMenu.padding(.horizontal, 10)
                Button { fullscreen.toggle() } label: {
                    Image(systemName: fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }.accessibilityLabel("切换全屏")
            }
        }
    }

    private var tracksMenu: some View {
        Menu {
            Section("音轨") {
                ForEach(model.player.audioTracks, id: \.mpvID) { track in
                    Button(trackLabel(track)) { model.player.selectTrack(track.id) }
                }
            }
            Section("字幕") {
                Button("关闭字幕") { model.player.disableTrack(.subtitle) }
                ForEach(model.player.subtitleTracks, id: \.mpvID) { track in
                    Button(trackLabel(track)) { model.player.selectTrack(track.id) }
                }
                Button("导入字幕文件") { beginImport(.subtitle) }
            }
        } label: { Image(systemName: "captions.bubble") }
    }

    private var libraryControls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.title).font(.title3.bold()).lineLimit(2)
                    Text(model.status).font(.footnote).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button { beginImport(.video) } label: { Label("本地视频", systemImage: "folder") }
                        .accessibilityIdentifier("openLocalVideo")
                    Button { showingURL = true } label: { Label("网络链接", systemImage: "link") }
                        .accessibilityIdentifier("openNetworkVideo")
                }.buttonStyle(.borderedProminent).controlSize(.large)
                Button { showingWebDAV = true } label: {
                    Label("WebDAV 文件服务器", systemImage: "externaldrive.connected.to.line.below")
                }.buttonStyle(.bordered).controlSize(.large).accessibilityIdentifier("openWebDAV")
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("弹幕", systemImage: "text.bubble.fill").font(.headline)
                        Spacer()
                        if model.isLoadingComments { ProgressView() }
                        Toggle("显示弹幕", isOn: $model.settings.enabled).labelsHidden()
                    }
                    Text(model.sourceTitle).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    HStack {
                        Button("搜索弹幕", systemImage: "magnifyingglass") { showingSearch = true }
                        Spacer()
                        Button("导入文件", systemImage: "square.and.arrow.down") { beginImport(.danmaku) }
                            .accessibilityIdentifier("importDanmaku")
                    }
                    if !model.comments.isEmpty {
                        HStack {
                            Text("共 \(model.comments.count) 条").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("导出 XML") { exporting = true }.font(.footnote)
                        }
                    }
                    Button("弹幕样式与时间调整", systemImage: "slider.horizontal.3") { showingSettings = true }
                }.padding(18).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
                Text("网络播放请使用视频直链。弹幕可通过作品搜索、来源链接或本地文件加载。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var urlSheet: some View {
        NavigationStack {
            Form {
                Section("视频直链") {
                    TextField("https://…", text: $networkURL, axis: .vertical)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("打开视频") {
                        guard let url = URL(string: networkURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                            networkError = "请输入 HTTP 或 HTTPS 视频直链。"; return
                        }
                        showingURL = false
                        model.open(url)
                    }.disabled(networkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let networkError { Text(networkError).font(.footnote).foregroundStyle(.orange) }
                }
            }.navigationTitle("网络视频").toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showingURL = false }.accessibilityIdentifier("closeNetworkVideo")
                }
            }
        }.presentationDetents([.medium, .large])
    }

    private func trackLabel(_ track: MPVMediaTrack) -> String {
        (track.isSelected ? "✓ " : "") + (track.title ?? track.language ?? "轨道 \(track.mpvID)")
    }

    private func beginImport(_ kind: FileImportKind) {
        importKind = kind
        importingFile = true
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            switch importKind {
            case .video: model.open(url)
            case .danmaku: model.importComments(url)
            case .subtitle:
                do {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let target = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
                    try FileManager.default.copyItem(at: url, to: target)
                    model.player.loadExternalSubtitle(target)
                } catch { model.error = "字幕文件无法导入，请重试。" }
            }
        case .failure(let error):
            // Closing the picker is a normal action, not an import failure.
            guard (error as NSError).code != NSUserCancelledError else { return }
            model.error = "未能读取所选文件，请重新选择。"
        }
    }
}

private enum FileImportKind {
    case video, danmaku, subtitle

    var contentTypes: [UTType] {
        switch self {
        case .video: [.movie, .video, .audio, .data]
        case .danmaku: [.xml, .json, .data]
        case .subtitle: [.text, .data]
        }
    }
}

struct DanmakuDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.xml] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
