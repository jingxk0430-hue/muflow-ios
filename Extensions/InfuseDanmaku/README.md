# InfuseDanmaku 实验扩展

独立的 iOS 弹幕叠加层源码。当前是未完成真机验证的实验版本；源码编译、包内注入检查与真实 Infuse 运行验收分别记录，不能互相替代。

扩展 0.1.3 的入口位于播放器右下角原生齿轮菜单的“弹幕”子菜单，无独立悬浮按钮。支持导入 UTF-8 的 Bilibili 风格 XML（`<d p="秒数,模式,字号,颜色,...">文字</d>`），以及粘贴腾讯、爱奇艺、优酷、Bilibili 单集网页链接获取弹幕。视频继续由 Infuse 播放，不解析网页中的视频流。支持滚动/顶部/底部弹幕、字号、透明度、区域、时间偏移、开关和取消网络请求。暂不支持按作品名称搜索。

来源解析复用仓库 `App/Services` 中的原生站点实现，通过独立 Swift/Objective-C 桥接供叠加层使用，不另复制这些服务，也不把 URL 转交给第三方弹幕代理。Bilibili 支持 BV/AV/番剧单集和受限短链跳转，腾讯保留手机分享链接中的单集 vid，优酷使用临时匿名会话，爱奇艺处理分段压缩 XML。各网站实际可用性受来源接口影响；本地协议测试不等于手机网络实测。

XML 文件不上传，弹幕内容仅保留在播放器会话内。文件大小上限 8 MB、数量上限 30000 条，同时显示最多 36 条。

0.1.2 针对“视频流畅、弹幕滚动顿挫”调整渲染：滚动位置由 Core Animation 线性动画推进，CADisplayLink 按目标 60Hz 负责调度和校准，不再每帧改 UIView.frame。以宿主媒体时间为基准平滑粗粒度时间戳；仅在暂停状态与倍速 getter 均可验证时启用插值，接口缺失时退回精确宿主时间。暂停、拖动、倍速变化和超过 120ms 的时钟停滞会停止或重建动画，不能无限自行推进。后台恢复后重新校准。实际刷新率仍受系统省电和温控策略影响。

0.1.3 修正动画校准的时间基准：用动画锚点推算到目标显示时刻，避免将下一帧位置与较旧的 presentationLayer 位置比较，尤其避免倍速时每 200ms 误重启动画。真正的时间偏差、暂停、倍速与跳转仍会重新定位。

文字改用 CoreText 在串行后台队列预绘制为屏幕原生分辨率的透明位图，使用细黑描边；去掉每条文字的动态模糊阴影和额外 shouldRasterize 图层。调度器预热未来 1.5 秒的已排布弹幕；缓存上限 128 张/12MB，待处理任务上限 72。字号、屏幕 scale 或弹幕列表变化会使旧任务失效，普通旋转复用图像。停止、关弹幕和重建会取消旧预热任务；极长文字或位图分配失败回退原生 UILabel。位图生成完成后只向仍属于当前会话/版本的可见图层交付。

复用最多 36 个文字视图和可见结果缓冲，getter ABI 按运行时类验证后使用直接消息调用；暂停画面不重复调度，关闭/无弹幕时不读取宿主时钟。滚动弹幕使用相同速度和尾部间隔避免追尾，顶部/底部有独立占位。本次没有移植 Cilicili 二进制或新增 Metal 渲染后端，普通弹幕移动继续由系统合成器推进；尚未测量 iPhone 上的帧时间。

设计参考（借鉴架构，不直接引入这些库）：[BarrageRenderer 的刷新时钟与视图复用](https://github.com/unash/BarrageRenderer)、[DanmakuKit 的 position.x 动画及异步绘制](https://github.com/qyz777/DanmakuKit)、[DanmakuFlameMaster 的时钟同步及预缓存](https://github.com/bilibili/DanmakuFlameMaster)。第三方项目的自述性能不能作为本插件的性能结论；目前还没有 iPhone 上的帧时间记录。

## 构建和验证

Linux/macOS 可验证纯 C++ 时间轴：

```sh
c++ -std=c++17 -Wall -Wextra -Werror Tests/timeline_test.cpp -o /tmp/ifd-timeline-test
/tmp/ifd-timeline-test
c++ -std=c++17 -Wall -Wextra -Werror Tests/media_clock_test.cpp -o /tmp/ifd-media-clock-test
/tmp/ifd-media-clock-test
```

macOS CI 另验证 Foundation getter 的 double/float/bool/object ABI、缓存及失败路径，并用实际 CALayer/CABasicAnimation 对象检查线性移动、暂停、倍速、跳转和“显示快照落后一帧”的回归。CoreText 位图检查 1x/2x/3x 尺寸、中英文字形覆盖、彩色填充、描边、透明背景及分配边界，并输出 PNG 供视觉核对。这些不替代屏幕上实际滚动的帧率测试。

iOS 动态库需 macOS/Xcode，在本仓库扩展目录运行 `bash scripts/build-ios.sh`。`bash scripts/test-online.sh` 在 macOS 上使用本地固定响应检查网址、分享参数、来源数据格式、压缩和匿名请求。GitHub Actions 工作流只构建扩展和上传产物，不下载 Infuse、不处理签名材料、不发布或安装 IPA。构建结果以对应提交的 Actions 记录为准。

动态库还需与可重新打包的 Infuse IPA 整合和签名才能上真机。USB 连接和应用版本查询本身不提供该二进制；本目录不包含 Infuse 程序。此扩展也不依赖 InfusePlus，不修改付费状态。

## 兼容性依据与边界

仅依据作者公开发布的 InfusePlus v2.6 `iphoneos-arm.deb` 中 arm64 动态库进行静态分析，不含 Infuse 原始源码。宿主候选类为 `FCVideoViewController`、`_TtC6infuse21FCVideoViewController`。两条候选播放器路径：`controller.player`、`controller.modelContainer.player`。所有动态读取在调用前验证参数数量和返回类型，失败后跳过渲染。

公开插件动态库 SHA-256：`f7cb017251b1be71d0afb6cc797d28ae86fe46d604e7421350423b7e6b2b0ee1`。

REA 证据保留在本机研究目录的 `infuseplus-v2.6-evidence.json` 中，不随仓库分发：

- `PlayerHelper::player`：`ev_65dbe9d5b38b65dd5631fbdb6eddf4e246c3093f5592733706c72ded8c45be90`，上述两条对象获取路径。
- `PlayerHelper::currentTime`：`ev_0300d57728285164aae2224231229039206628c8e59cbc626fc0a441c1fee067`，播放器 `currentTime` 返回 double。
- `PlayerHelper::paused`：`ev_4c287e7b2dc7eccbd633c267079c4496a589a978863643a7dbb196de53273cf5`，读取播放器 `isPaused`。
- `PlayerHelper::playbackRate`：`ev_ea853357bb9863a47bde6231e8f4896a944e4ac9c0f88fbfc71eaa646ed989af`，播放器 `playbackRate` 返回 float。
- `PlayerHelper::panelView`：`ev_7c43bc7f12186e66fb094d393c467415cb3b8310c9c8ec077e6ff41a38953728`，控制面板候选访问。当前扩展使用宿主根视图，尚待核对遮挡关系。
- 原生设置按钮依据本地化 `pcVOSettings` 辅助功能标签识别，限定在当前播放器的视图树内。证据 `ev_c7f0a20c83d71c111583b60cbcb44a8e45d7340fb669debd7cdc1e7bd8105719`。原插件的菜单接入为设置菜单的 setter 包装，证据 `ev_4680970cbf57e76076f1e8c2ac9494a53adf65d235ad7545e3c6765a5bf4ef49`。新扩展分别包装 UIButton 菜单读写并增加唯一标识的延迟子菜单，保留原菜单内容。

反编译结果是 Ghidra 推导的伪代码，不是原始源码；间接调用关系可能不完整。源码中的生命周期接入方式属于新设计，不是已从 Infuse 8.5.1 验证的结果。播放器实际接口、全屏/小窗、横竖屏、文件选择器、系统画中画、HDR、宿主字幕层级、资源释放、切集时对象复用均待真机验收。当前叠加层不支持系统画中画；不读取视频文件名自动匹配弹幕，切集后应清除再导入对应 XML。
