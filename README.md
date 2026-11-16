# 幕流 MuFlow

面向 iOS 26 的个人视频与弹幕播放器。视频播放使用 MPVUI / libmpv，弹幕通过独立 Swift 时间轴绘制。

## 当前阶段

第一版开发中。源码检查、云端编译、IPA 签名、设备安装、实际视频播放与弹幕同步是独立的验收阶段；源码存在不表示已完成真机验证。

## 首期功能

- 从“文件”打开本地视频、音频和网络媒体直链。
- WebDAV：账号登录、目录浏览、返回上级及媒体在线播放；登录信息可保存在此设备钥匙串。
- 播放、暂停、进度跳转、倍速、音轨选择、字幕选择与外挂字幕导入。
- 搜索弹弹play兼容弹幕服务、选择作品和剧集、从来源链接加载弹幕。
- 影视目录搜索与来源选择；腾讯、爱奇艺、优酷、B站和芒果TV的独立弹幕解析，减少对兜底服务的依赖。
- 支持腾讯手机分享页中的 `vid` 参数，以及 B站 `b23.tv` 短链接的受限域名重定向解析。
- 主线路返回无效内容或空弹幕后尝试备用线路；站点部分分段失败时保留成功弹幕并提示缺失。
- 设置中的“检查弹幕连接”在当前手机上分别验证搜索、剧集列表、弹幕下载和影视目录，显示失败阶段。
- 导入 Bilibili XML、弹弹play JSON 和 `c/m` JSON 弹幕，导出 XML。
- 支持滚动、顶部和底部弹幕，去重、简体转换、样式与全局时间偏移。
- 默认不透明度 100%、显示区域 50%、同屏上限 30 条；使用 20 点常规字重与 0.65 点细描边，按设备原生分辨率绘制，滚动位置对齐物理像素以免文字发虚。
- 设置页提供实时文字预览；升级时只迁移未更改的旧默认样式，保留自定义参数和视频时间偏移。
- 为当前视频自动保存弹幕，重新打开同一地址时恢复；网络地址变化时视为另一视频。

网络视频输入目前要求媒体直链，不包含桌面版 yt-dlp 网页解析。弹幕源链接解析依赖配置的服务能力。高级弹幕、逐来源独立偏移、NAS 媒体库、画中画、后台播放及自动文件哈希匹配不属于本次已验证能力。

## 不需要自备 Mac 的构建流程

1. 在自己的 GitHub 账号创建公开仓库并上传源码。
2. 在 Actions 中手动运行 **Build iOS IPA**。工作流只使用标准 `macos-26` 运行器。
3. 下载 `MuFlow-unsigned` 工件，其中包含未签名的 IPA。
4. 在本地 Linux 使用自己的证书签名，再安装到已登记的 iPhone。

全部自动检查通过后，工作流会将未签名 IPA 与 SHA256 放入对应版本的 GitHub 草稿 Release，检查实际界面截图后发布。实际手机连通性仍需通过“检查弹幕连接”和真实播放核对。

公开仓库标准运行器的计算使用按 GitHub 当前规则免费；工件只保留 3 天。工作流不包含大型付费运行器、证书、账号密码或生产业务配置。

## 本地检查

```bash
python3 scripts/validate_project.py
# macOS / Xcode 环境下执行实际单元测试与编译
swift test --package-path Packages/DanmakuCore
swift test --package-path Packages/WebDAVCore
bash scripts/test_ui.sh
bash scripts/build_ios.sh
```

依赖固定在 MPVUI `0.10.0` 的提交 `cd2da733a17da6be94d451b5785c908801a4ee22`，需要带 Swift 6.3 或更新版本的 Xcode。工作流会从运行器已安装的 Xcode 中选择满足要求的版本，找不到时明确失败。

## 本地签名

需要 Python `cryptography`、OpenSSL，以及从上游源码构建的 zsign。传入证书压缩包路径；脚本在内存中读取密码材料，不将密码作为命令参数，不把证书复制进项目。

```bash
python3 scripts/sign_local.py --certificate-archive /private/path/certificate.zip --inspect
python3 scripts/sign_local.py \
  --certificate-archive /private/path/certificate.zip \
  --input /private/path/MuFlow-unsigned.ipa \
  --output dist/MuFlow-signed.ipa \
  --zsign /private/path/zsign
```

签名只申请播放器所需的最小标识权限。原始描述文件中的 HealthKit、VPN、HomeKit 等权限不会全部复制到应用签名。签名脚本检查证书、私钥、描述文件、有效期与签名后包标识；在线吊销状态及实际设备安装仍需另外验证。

## USB 安装与回查

Linux 上需要 libimobiledevice 工具和 ideviceinstaller。可从系统发行版的正式软件仓库安装，也可将对应 DEB 解包到独立工具目录；后者不修改全局系统安装。

```bash
python3 scripts/install_local.py \
  --certificate-archive /private/path/certificate.zip \
  --tools-root /private/path/device-tools --inspect-only
python3 scripts/install_local.py \
  --certificate-archive /private/path/certificate.zip \
  --tools-root /private/path/device-tools --input dist/MuFlow-signed.ipa
```

安装前只查询目标应用标识，核对当前 USB 设备是否已登记。若同标识已有其他应用，停止安装；已有 MuFlow 的更新需显式提供 `--replace-existing-muflow`。安装后独立回查版本并保存本地回执，不把“安装成功”等同于“实际播放与弹幕验证通过”。

## 隐私

视频和弹幕文件保存在手机。搜索关键词、选定剧集编号、用户主动添加的来源链接会发送给配置的弹幕服务。应用不包含遥测、登录账号、推送通知或自动客户业务操作。

WebDAV 登录信息仅用于用户配置的服务器，不发送给弹幕服务。目录请求拒绝跳转到其他服务器；播放使用单个媒体 URL 的 HTTP 认证，不设置全局认证头。保存的登录信息使用设备钥匙串，应用中可清除。首版面向标准 HTTP Basic 认证；服务器需有可由系统信任的证书，未实现自签名证书例外、OAuth、SMB 或 NFS。

弹幕搜索会同时查询配置的弹弹play服务和360影视目录。主弹弹play服务失败时尝试备用服务（可在设置留空以关闭）。影视来源链接优先使用站点解析，失败再尝试第三方服务；网站接口、限流和服务故障可能影响获取。当前不支持导入桌面浏览器 Cookie，也没有移植桌面插件的全部站点解析器。

优酷直连会向优酷接口及其匿名会话入口请求临时 Cookie，仅保存在本次弹幕加载的内存中，不导入个人登录 Cookie，不发送 WebDAV 登录信息。此会话用于读取公开弹幕，无法替代视频播放权限。

## 许可

本项目按 GPL-3.0-or-later 发布；第三方依赖见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
