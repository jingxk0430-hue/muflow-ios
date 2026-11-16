import SwiftUI
import WebDAVCore

struct WebDAVView: View {
    @Bindable var model: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @State private var connection = WebDAVConnection()
    @State private var connected: WebDAVConnection?
    @State private var remember = true
    @State private var folders: [URL] = []
    @State private var items: [WebDAVItem] = []
    @State private var loading = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if connected != nil { browser }
                else { login }
            }
            .navigationTitle("WebDAV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }.accessibilityIdentifier("closeWebDAV")
                }
                if connected != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("更换服务器") {
                            task?.cancel(); loading = false; connected = nil; folders = []; items = []; error = nil
                        }
                    }
                }
            }
            .onAppear {
                do { if let saved = try WebDAVKeychain.load() { connection = saved } }
                catch { self.error = error.localizedDescription }
            }
            .onDisappear { task?.cancel() }
        }
    }

    private var login: some View {
        Form {
            Section {
                TextField("https://服务器/dav/", text: $connection.address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("webdavAddress")
                TextField("账号（可留空）", text: $connection.username)
                    .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("webdavUsername")
                SecureField("密码或应用专用密码", text: $connection.password).textContentType(.password)
                    .accessibilityIdentifier("webdavPassword")
                Toggle("在此手机记住登录", isOn: $remember)
            } header: { Text("服务器") } footer: {
                Text("支持标准 WebDAV 文件夹。登录信息只保存在此手机的钥匙串中；建议使用 HTTPS。")
            }
            Section {
                Button {
                    do { load(try connection.rootURL(), using: connection, newConnection: true) }
                    catch { self.error = error.localizedDescription }
                } label: {
                    HStack { Text("连接服务器"); Spacer(); if loading { ProgressView() } }
                }.disabled(loading || connection.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("connectWebDAV")
                Button("清除已保存的登录", role: .destructive) {
                    do { try WebDAVKeychain.delete(); connection = .init(); error = nil }
                    catch { self.error = error.localizedDescription }
                }.disabled(loading)
            }
            if let error { Section { Text(error).foregroundStyle(.orange).font(.footnote) } }
        }
    }

    private var browser: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "externaldrive.connected.to.line.below")
                    Text(folders.last?.path ?? "/").font(.footnote).lineLimit(2)
                    Spacer()
                    if loading { ProgressView() }
                }
                if folders.count > 1 {
                    Button("返回上一级", systemImage: "arrow.up") {
                        guard let connected else { return }
                        load(folders[folders.count - 2], using: connected, goBack: true)
                    }.disabled(loading).accessibilityIdentifier("webdavParent")
                }
            }
            if let error {
                Section {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                    Button("重试") {
                        if let connected, let folder = folders.last { load(folder, using: connected, refresh: true) }
                    }.disabled(loading)
                }
            }
            Section {
                ForEach(items) { item in
                    Button {
                        guard let connected else { return }
                        if item.isDirectory { load(item.url, using: connected) }
                        else {
                            do {
                                model.open(item.url, playbackURL: try connected.playbackURL(for: item.url))
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.isDirectory ? "folder.fill" : "play.rectangle")
                                .foregroundStyle(.mint)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name).foregroundStyle(.primary).lineLimit(2)
                                if !item.isDirectory, let size = item.size {
                                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if item.isDirectory { Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                        }.padding(.vertical, 4)
                    }.disabled(loading || (!item.isDirectory && !item.isPlayable))
                        .accessibilityIdentifier("webdav-item-" + item.name)
                }
                if items.isEmpty && !loading { Text("此文件夹为空").foregroundStyle(.secondary) }
            } footer: { Text("点击视频即可在线播放，再搜索或导入弹幕。文件夹和媒体文件可打开。") }
        }
        .refreshable {
            if let connected, let folder = folders.last { load(folder, using: connected, refresh: true); await task?.value }
        }
    }

    private func load(_ folder: URL, using candidate: WebDAVConnection,
                      newConnection: Bool = false, goBack: Bool = false, refresh: Bool = false) {
        task?.cancel(); loading = true; error = nil
        task = Task {
            do {
                let incoming = try await WebDAVService(connection: candidate).list(folder)
                try Task.checkCancellation()
                if newConnection {
                    if remember { try WebDAVKeychain.save(candidate) } else { try WebDAVKeychain.delete() }
                    connected = candidate; folders = [folder]
                } else if goBack { folders.removeLast() }
                else if !refresh { folders.append(folder) }
                items = incoming; loading = false
            } catch {
                guard !Task.isCancelled else { return }
                loading = false
                self.error = (error as? WebDAVError)?.errorDescription
                    ?? (error as? WebDAVKeychain.KeychainError)?.errorDescription
                    ?? "连接未完成，请检查网络、服务器地址和证书后重试。"
            }
        }
    }
}
