# Third-party notices

## MPVUI

- Source: https://github.com/LePips/MPVUI
- Pinned commit: cd2da733a17da6be94d451b5785c908801a4ee22 (0.10.0)
- Swift wrapper: MIT; preserve the upstream LICENSE supplied with the dependency.
- Bundled `Libmpv-GPL.xcframework`: includes mpv, FFmpeg and other native dependencies with their own licenses; the selected build is GPL. Source and build information are in the pinned upstream repository and release artifacts.

## uosc_danmaku

- Source: https://github.com/Tony15246/uosc_danmaku
- License: MIT, Copyright (c) 2024 吴南李.
- Source-site protocol logic in `NativeDanmakuService.swift`, `YoukuDanmakuService.swift` and `TVSearchService.swift` is adapted from the desktop `sites` parsers and `apis/extra.lua`. Copyright (c) 2024 吴南李 and contributors. Desktop scripts and credential-bearing configuration are not bundled.
- Full license and copyright notice: [uosc_danmaku-MIT.txt](App/Resources/Licenses/uosc_danmaku-MIT.txt), also shipped in the app resources.

## zsign (optional local tooling)

- Source: https://github.com/zhlynn/zsign
- Reference build commit: 9299685bab7ef99827e06e5dfda93af747386590
- License: MIT. Not linked into or shipped inside the iOS app.

MuFlow original source is GPL-3.0-or-later. When distributing binaries, preserve applicable notices and provide corresponding source/build information for this application and the selected GPL native dependencies.
