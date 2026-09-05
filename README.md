# ScreenPin

macOS 原地抠图贴屏工具：框选屏幕任意区域 → 图像原地置顶悬浮 → 需要再存桌面。
按下快捷键先把屏幕定格成快照再框选（下拉菜单等瞬态界面也能截）；悬浮图可拖动、标注、调透明度、点击穿透，不遮挡不拦截后续操作。
界面语言跟随系统：中文系统显示中文，其余语言一律英文。

纯 Swift / AppKit / ScreenCaptureKit，零第三方依赖，菜单栏常驻（无 Dock 图标）。

## 构建

```bash
./build.sh            # release 编译 + 组装 ScreenPin.app + 自签名证书签名
./build.sh --install  # 同上，并同步安装到 /Applications（推荐）
open /Applications/ScreenPin.app
```

构建优先使用本机已配置并解锁的 `ScreenPin Local Dev` 证书；缺失时回退为 ad-hoc 签名。
证书、私钥和本地证书配置脚本不纳入仓库。使用稳定开发证书可保持重编译后的屏幕录制授权；
本地开发签名不等于 Developer ID 签名或 Apple 公证。

## 首次使用：授权「屏幕录制」

第一次抠图会触发系统授权（系统设置 → 隐私与安全性 → 屏幕录制 → 勾选 ScreenPin）。
授权后如仍不生效，重启一次 App 即可。

## 使用

| 操作 | 方式 |
| --- | --- |
| 开始抠图 | 全局快捷键 `⌃⌥X`，或菜单栏 ✂ 图标 → 截图；先定格全屏快照再框选（下拉菜单也能截） |
| 框选 | 鼠标拖拽；`ESC` 或单击（选区 < 4px）取消 |
| 贴图移动 | 按住任意位置拖动 |
| 标注 | 贴图上按 `B` 画笔、`A` 箭头、`T` 文字（单击落点出输入框，超宽自动换行）；`C` 循环换色（模式描边颜色即当前色）；`Enter` 确认并逐层退出（保留标注）：输入中＝提交文字、标注模式＝退出标注恢复拖动、普通贴图＝确认完成并关闭；`ESC` 取消并丢弃：输入中＝取消本次输入、标注模式＝退出标注并丢弃本次画的标记、普通贴图＝丢弃贴图；也可点左上角「✕ 退出标注」按钮保留标注退出；`⌘Z` 撤销上一笔；每完成一笔剪贴板自动更新为最新标注图，直接 `⌘V` 即可；保存与复制时标注会合成进图像 |
| 保存到桌面 | 右键 → 保存到桌面，或 `⌘S`（静默保存 `~/Desktop/ScreenPin_时间戳.png`，边框闪一下表示成功）；`⇧⌘S` 保存桌面并把**文件路径文本**写入剪贴板（方便直接发给 agent） |
| 复制到剪贴板 | 右键 → 复制，或 `⌘C` |
| 调透明度 | 右键 → 透明度（100/75/50/25%） |
| 点击穿透 | 右键 → 点击穿透（开启后鼠标事件穿透到下方窗口；从菜单栏「关闭所有贴图」可清除） |
| 丢弃贴图 | `ESC`（丢弃）/ `⌘W` / 右键 → 关闭；或 `Enter` 确认完成并关闭（图已在剪贴板） |

## 改快捷键

`Sources/ScreenPin/HotkeyManager.swift` 中的 `keyCode` / `modifiers` 两个常量，改完重新 `./build.sh`。

## 调试日志

运行日志写入 `~/Library/Logs/ScreenPin.log`（截图坐标、目标显示器、成功/失败原因），
超过 512KB 自动滚动为 `ScreenPin.old.log`（只保留一代）。不需要时直接删除这两个文件即可。
诊断探针：`/Applications/ScreenPin.app/Contents/MacOS/ScreenPin --check-permission`。

## 结构

```
Sources/ScreenPin/
├── ScreenPinApp.swift          # @main + 菜单栏
├── HotkeyManager.swift         # Carbon 全局快捷键
├── SnipOverlayController.swift # 全屏快照选区覆盖层
├── CaptureService.swift        # ScreenCaptureKit 整屏快照 + 权限预检
├── PinWindowController.swift   # 置顶悬浮图窗（含画笔/箭头/文字标注）
├── SaveService.swift           # 存桌面 / 剪贴板
└── Localization.swift          # L() 文案本地化入口（key 即英文）
```
