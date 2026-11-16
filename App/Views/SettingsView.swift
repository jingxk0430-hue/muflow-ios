import SwiftUI
import DanmakuCore

struct SettingsView: View {
    @Bindable var model: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingConnectionCheck = false
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        NavigationStack {
            Form {
                Section("弹幕样式") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("样式预览").font(.caption).foregroundStyle(.secondary)
                        Image(uiImage: DanmakuTextRenderer.image("弹幕清晰，画面也好看 Aa 123",
                                                               fontSize: model.settings.fontSize,
                                                               outline: model.settings.outline, scale: displayScale))
                            .opacity(model.settings.opacity)
                    }
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                    .padding(12)
                    .background(LinearGradient(colors: [.black, .gray.opacity(0.65)], startPoint: .leading, endPoint: .trailing),
                                in: RoundedRectangle(cornerRadius: 10))
                    .clipped()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("弹幕样式预览")
                    .accessibilityIdentifier("danmakuStylePreview")
                    Toggle("显示弹幕", isOn: $model.settings.enabled)
                    settingSlider("不透明度", value: $model.settings.opacity, range: 0.1...1, text: "\(Int(model.settings.opacity * 100))%")
                    settingSlider("显示区域", value: $model.settings.displayArea, range: 0.1...1, text: "\(Int(model.settings.displayArea * 100))%")
                    settingSlider("字号", value: $model.settings.fontSize, range: 14...40, text: "\(Int(model.settings.fontSize))")
                    settingSlider("滚动时长", value: $model.settings.scrollDuration, range: 4...25, text: "\(Int(model.settings.scrollDuration)) 秒")
                    settingSlider("固定弹幕时长", value: $model.settings.fixedDuration, range: 2...10, text: "\(Int(model.settings.fixedDuration)) 秒")
                    settingSlider("描边", value: $model.settings.outline, range: 0...3, text: model.settings.outline.formatted(.number.precision(.fractionLength(1))))
                    Stepper("同屏上限：\(model.settings.maximumOnScreen) 条", value: $model.settings.maximumOnScreen, in: 5...100)
                }
                Section("同步与文字") {
                    LabeledContent("时间偏移", value: "\(model.settings.delay.formatted(.number.precision(.fractionLength(1)))) 秒")
                    HStack {
                        Button("提前 0.5 秒") { model.settings.delay -= 0.5 }
                        Spacer()
                        Button("归零") { model.settings.delay = 0 }
                        Spacer()
                        Button("延后 0.5 秒") { model.settings.delay += 0.5 }
                    }.font(.footnote)
                    Toggle("繁体转简体", isOn: $model.settings.simplifiedChinese)
                    settingSlider("重复合并窗口", value: $model.settings.mergeTolerance, range: 0...5,
                                  text: "\(model.settings.mergeTolerance.formatted(.number.precision(.fractionLength(1)))) 秒")
                }
                Section("弹幕服务") {
                    Button("检查弹幕连接", systemImage: "network") { showingConnectionCheck = true }
                    TextField("主服务地址", text: $model.server).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("备用弹弹play服务", text: $model.alternateServer).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("备用解析地址", text: $model.fallback).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("主服务失败后会尝试备用弹弹play服务。搜索关键词、剧集编号或主动添加的来源链接会发送给这些服务；备用地址可留空。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("恢复默认弹幕样式") {
                        let delay = model.settings.delay
                        let enabled = model.settings.enabled
                        model.settings = DanmakuSettings()
                        model.settings.delay = delay
                        model.settings.enabled = enabled
                    }
                    Button("清空此视频的弹幕", role: .destructive) { model.clearComments() }
                }
            }.navigationTitle("播放设置").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .sheet(isPresented: $showingConnectionCheck) { DanmakuConnectionView(model: model) }
        }
    }

    private func settingSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, text: String) -> some View {
        VStack(alignment: .leading) {
            LabeledContent(title, value: text)
            Slider(value: value, in: range)
        }
    }
}
