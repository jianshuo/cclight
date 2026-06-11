# CCLight

> Your MacBook notch tells you when Claude Code is thinking. No windows, no notifications — just light.

CCLight 把 Claude Code 的运行状态画到 MacBook 的刘海上。一道细线带着柔和的晕光环绕刘海：跑着是橙的，等你回复是绿的，闲着是白的。多个 session 同时跑？U 形分段，每段一个 session，互不打架。

<p align="center">
  <a href="https://github.com/jianshuo/cclight/releases/latest/download/CCLight.dmg">
    <img alt="Download CCLight.dmg" src="https://img.shields.io/badge/Download-CCLight.dmg-ffb000?style=for-the-badge&logo=apple&logoColor=white" />
  </a>
  &nbsp;
  <a href="https://github.com/jianshuo/cclight/releases/latest">
    <img alt="Latest release" src="https://img.shields.io/github/v/release/jianshuo/cclight?style=for-the-badge&color=5fcf7a" />
  </a>
</p>

Mac, macOS 14+, Apple Silicon. Signed by Developer ID, notarized by Apple — Gatekeeper opens it without a right-click. Open the DMG, drag CCLight to Applications, launch once, accept the hooks dialog. Done.

<p align="center">
  <video src="marketing/cclight-promo.mp4" controls width="360" muted>
    <a href="marketing/cclight-promo.mp4">▶ marketing/cclight-promo.mp4</a>
  </video>
</p>

<sub><i>If the embed doesn't load (some markdown viewers strip `&lt;video&gt;` tags), the file is at
<a href="marketing/cclight-promo.mp4"><code>marketing/cclight-promo.mp4</code></a>
— 1080×1920, 39 s, Chinese narration + per-state chimes.</i></sub>

---

## 状态颜色

| 颜色 | 状态 | 含义 |
|---|---|---|
| 🟠 橙 `#FFB000` | **Working** | Claude 在跑 |
| 🟢 绿 `#5FCF7A` | **Waiting** | 等你输入 |
| ⚪ 白 `#FFFFFF`（淡） | **Idle** | 完成 / 闲着 |

`Waiting` 持续 5 分钟无活动 → 自动降级到 `Idle`。
任一 session 超过 10 分钟没更新 → 视为已死，自动从列表移除。

---

## 截图

### 灵动岛点亮，Claude 在干活

![Working — amber](marketing/screenshots/out-2560/v1-2560.png)

### 四个 session 同时跑，每段独立

![Four sessions, one glance](marketing/screenshots/out-2560/v2-2560.png)

### 绿色：轮到你回复

![Waiting — green](marketing/screenshots/out-2560/v3-2560.png)

### 在余光里活着

![Peripheral vision](marketing/screenshots/out-2560/v4-2560.png)

### 需要时打开菜单，不需要就当它不存在

![Drill in](marketing/screenshots/out-2560/v5-2560.png)

### 完全本地：没有网络，没有遥测

![Local-only](marketing/screenshots/out-2560/v6-2560.png)

---

## 多 session

刘海下方的 U 形线分成 1–4 段，每段对应一个 session，**按打开顺序从左到右排列**。session 多于 4 个时只显示最近活跃的 4 个。每段独立着色，每段有自己的晕光。

合并后的总状态显示在菜单栏小圆点上：任一 working → 橙；否则任一 waiting → 绿；全 idle → 白。

---

## 安装

**正常用法 —** 点上方那颗橙色按钮（或 [Releases 页](https://github.com/jianshuo/cclight/releases/latest)），下载 `CCLight.dmg`，打开后把 CCLight 拖进 Applications，启动一次，在弹出的对话框里选 Install Hooks 就装好了。

第一次启动会弹一个对话框问要不要把 hooks 写进 `~/.claude/settings.json`。选「Install」之后就生效了。
也可以用 Homebrew 安装：

```sh
brew install --cask jianshuo/tap/cclight
```

也可以之后从菜单里 Install / Uninstall，或者命令行：

```bash
/Applications/CCLight.app/Contents/MacOS/cclightcli install-hooks
```

### 从源码构建 / 自己发布

```bash
git clone https://github.com/jianshuo/cclight.git
cd cclight
bash scripts/archive-and-export.sh --dmg              # 本地产物 → build/export/CCLight.dmg
bash scripts/archive-and-export.sh --release v1.0.0   # 同时发一个 GitHub Release
```

需要本地 keychain 里有 **Developer ID Application** 证书；公证用 `ASC_API_KEY_ID` / `ASC_API_ISSUER_ID` / `ASC_API_KEY_CONTENT` 环境变量。`--release` 还需要 `gh` 已登录。

> Mac App Store 路线最终因为嵌入 CLI 的沙盒约束未走通 — 改走 Developer ID + 公证发布。
> 详见 [`scripts/archive-and-export.sh`](scripts/archive-and-export.sh)。

---

## 接入 Claude Code（hooks 做了什么）

CCLight 在 `~/.claude/settings.json` 里注册了五条 hook：

| Hook              | 调用                    |
|-------------------|------------------------|
| `SessionStart`    | `cclightcli set waiting` |
| `UserPromptSubmit`| `cclightcli set working` |
| `Stop`            | `cclightcli set waiting` |
| `Notification`    | `cclightcli set waiting` |
| `SessionEnd`      | `cclightcli clear`       |

每个 session 自己的状态写进 `~/Library/Group Containers/group.com.wangjianshuo.lightio/Library/Application Support/state.json`；CCLight 用 FSEvents 监听这个文件，状态一变灯就跟着变。

---

## 技术栈

- macOS app：SwiftUI + AppKit（`NSStatusItem`, 透明 borderless `NSWindow`, `CAShapeLayer` 多层 glow halo）
- 状态：`FSEventStream` 监听 JSON state file
- CLI：Swift Package Manager（`CCLightCore` 共享逻辑库 + `cclightcli` 可执行）
- 通信：App Group container（`group.com.wangjianshuo.lightio`），App 沙盒 + 非沙盒 CLI 共享同一份 `state.json`
- 分发：Developer ID Application 签名 + Apple 公证 + stapler 钉印

刘海几何：自动检测 `NSScreen.safeAreaInsets` + `auxiliaryTopLeftArea/RightArea`。
U 形 path：右侧↓ → 右下圆角弧 → 底部← → 左下圆角弧 → 左侧↑，5 层 `CAShapeLayer` 叠加（line + glow1 r=6 + glow2 r=14 + glow3 r=28 + glow4 r=50 + glow5 r=80）。

---

## Repo 结构

```
cclight/                 — macOS app target (Swift / AppKit)
  AppDelegate.swift       — wires StateStore + overlay + menu bar + first-run
  StateStore.swift        — FSEvents watcher, 5-min idle timer
  NotchOverlayView.swift  — CAShapeLayer-based glow rendering
  NotchOverlayWindow.swift— borderless transparent click-through window
  MenuBarController.swift — NSStatusItem dot + session menu
  FirstRun.swift          — symlink, hooks dialog, launch-at-login
  cclight.entitlements    — sandbox + app-group + user-selected files

cclight-cli/             — Swift Package
  Sources/CCLightCore/   — shared library (paths, state JSON, hook installer)
  Sources/cclight/main.swift — embedded CLI (set / clear / status / install-hooks)

cclight.xcodeproj/       — Xcode workspace

scripts/
  archive-and-export.sh   — Developer ID archive + notarize + staple (+ optional DMG)
  ExportOptions.plist     — xcodebuild export config (developer-id)

marketing/
  cclight-promo.mp4           — vertical promo (1080×1920, 26 s)
  cclight-promo-landscape.mp4 — landscape promo (1920×1080, 26 s)
  screenshots/                — App Store screenshot variants (v1–v6 HTML + PNG)
  appstore-metadata.md        — (legacy; from the App Store attempt)

docs/
  privacy.md              — privacy policy
  superpowers/            — design notes from v1
```

---

## Related tools

| Tool | What it does |
|------|-------------|
| **cclight** ← you are here | MacBook notch glow tells you when Claude Code is thinking |
| [**ccline**](https://github.com/jianshuo/ccline) | Type a thought at your zsh prompt — get an AI answer and run the command |
| [**ccglass**](https://github.com/jianshuo/ccglass) | See exactly what your coding agent sends to the model |

---

## License

Personal project, all rights reserved.

由 [王建硕](https://wangjianshuo.com) 在 2026 年 5 月制作。
