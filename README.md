# stats-slim

macOS 菜单栏系统监控，[exelban/stats](https://github.com/exelban/stats) 的资源精简分支。

上游 Stats 是个好用的菜单栏监控器，但它启动时为每个模块都预建一整套设置界面和一个弹窗
窗口——这些界面绝大多数用户整个会话都不会打开一次。本分支把这类「启动时用不到的东西」
改成首次使用时才创建，并处理了几处常驻进程里纯属浪费的轮询与对外探测。

全部改动只涉及资源占用，不改变任何功能与界面。每一处都写在代码注释里，标注了文件位置与
实测数字，可以单独回退。

## 实测效果

在 Apple M6 Mac mini / macOS 27.0.1 / Stats 3.0.23 上，同一份用户配置、同一时段测量：

| 指标 | 上游 3.0.23 | 本分支 |
| --- | --- | --- |
| 物理内存占用（活动监视器「内存」列） | 140.8 M | 72.8 M |
| RSS | 214.7 MB | 137.9 MB |
| CPU | 4.9 % | 0.9 % |
| 对外 ICMP 探测 | 3600 次/小时 | 120 次/小时 |

测量方式：`ps -o rss=` 取 RSS，`heap <pid>` 取物理内存占用，`top -l 4 -s 2` 取稳定后的
CPU。ICMP 次数由读取器间隔推算。

## 改了什么

### 1. 设置窗口与弹窗改成懒加载（内存 140.8 M → 72.8 M，占大头）

`Kit/module/module.swift`：`Module.init` 原来在启动时为 10 个模块各建一个 `Window`
（整套设置界面：分段控件、标签页、控件选择器、各设置容器）和一个 `PopupWindow`
（一个 NSWindow 加整套弹窗视图）。现在两者都改成 `private var _window` / `_popup`
加计算属性，第一次被访问时才创建。

访问点全部在主线程（菜单栏点击、设置界面、启动流程），所以没有加锁。`enable()` /
`disable()` 里原来那两处 `window?.setState()` 走的是 `_window`，不会为了设一个开关
状态就把界面建出来——顺带一说，`Window.setState` 依赖的 `enableControl` 在上游里
从未被赋值，那两行本来就是空操作（模块开关在设置窗口的工具栏上，见
`Stats/Views/Settings.swift` 的 `toggleButton`）。

这是本分支唯一的大改动，也是唯一一处行为差异：设置窗口第一次打开时会比之前稍慢一次
（建界面），之后无差别。

### 2. 读取器默认轮询间隔 1 秒 → 2 秒（CPU 4.9 % → 约 1 %）

`Kit/module/reader.swift`：`defaultInterval` 默认值 1 → 2。菜单栏这类常驻程序的 CPU
占用主要就来自读取器的唤醒频率，1 秒和 2 秒在观感上没有区别，但整机轮询次数减半。
每个模块仍可在设置里改回 1（Store 键 `<模块名>_updateInterval`）。

### 3. ICMP 连通性探测默认 30 秒一次（对外请求 3600 → 120 次/小时）

`Modules/Net/readers.swift`：`ConnectivityReader` 原来默认每秒向 1.1.1.1 打一个
ICMP 回显。这两个数字（延迟/抖动）只用于弹窗，菜单栏的上传下载读数完全不依赖它。
默认改成 30 秒，需要秒级延迟读数就把 `Network_updateICMPInterval` 改回 1。

### 4. DB 写盘前不再白编码一次

`Kit/plugins/DB.swift`：`insert()` 原来每次调用都先 `JSONEncoder().encode(value)`，
再判断这一轮要不要真写盘（内部有 30 秒节流）。被节流掉的那些次，编码结果是直接扔掉的。
把编码挪到节流判断之后。

### 5. app 进程不再链接 WidgetKit / SwiftUI / Charts

`Kit/helpers.swift` 的 `import WidgetKit` 与 `SystemWidgetUpdates` 里两处
`WidgetCenter` 调用包进 `#if WIDGET_KIT`，而这个标志有意不在工程里定义；五个模块的
`widget.swift` 改名（`CPUWidget.swift` / `RAMWidget.swift` / `GPUWidget.swift` /
`DiskWidget.swift` / `NetworkWidget.swift`）并从模块目标的 Sources 移到
WidgetsExtension 目标。桌面组件本身没有被删掉，它整套住在 WidgetsExtension 里，由
系统单独拉起。

要说明清楚的是：这一项的收益比预期小。macOS 会把 SwiftUI 载入任何 AppKit 应用
（用一个只含 `NSApplication.run()` 的空 AppKit 程序即可复现），所以断开链接只省下
约 5–10 M。留着它的真正理由是让 app 与 11 个模块框架的依赖关系变干净，以及让上面
第 1 项的懒加载不会连带触发 WidgetKit 那套东西。

## 安装

### 下载即用

到 [Releases](https://github.com/mark-cell-520/stats-slim/releases) 下载最新的
`Stats.zip`，解压后把 `Stats.app` 拖进「应用程序」。

这个发布产物没有 Apple 开发者证书签名，首次打开时 Gatekeeper 会拦。两种解法：

```bash
# 方法一：移除隔离属性后正常打开
xattr -cr /Applications/Stats.app

# 方法二：在访达里按住 Control 点图标，选「打开」，在弹窗里再点一次「打开」
```

未签名带来的后果：macOS 不会为它做公证，Gatekeeper 的首次检查需要上面这一步；
除此之外功能、自动更新、SMC 助手（读温度与风扇需要）都与签名版本一致。

### 从源码构建

需要 Xcode 15 及以上、macOS 13 SDK。

```bash
git clone https://github.com/mark-cell-520/stats-slim.git
cd stats-slim
xcodebuild -project Stats.xcodeproj -scheme Stats -configuration Release \
  -derivedDataPath build build
```

产物在 `build/Build/Products/Release/Stats.app`。Debug 配置也能直接跑。

想验证资源占用的改动，构建后这样测：

```bash
open build/Build/Products/Release/Stats.app
sleep 10
PID=$(pgrep -f "Stats.app/Contents/MacOS/Stats")
ps -o rss= -p $PID          # RSS
heap $PID | grep "Physical footprint:"   # 活动监视器那个「内存」数字
top -l 4 -s 2 -pid $PID -stats cpu | tail -1   # 稳定后的 CPU
```

### Homebrew

上游的 `brew install stats` 装的是官方版本，不是这个分支。

## 与上游的关系

本分支从 [exelban/stats](https://github.com/exelban/stats) v3.0.23 分叉，MIT 许可，
版权仍归 Serhiy Mytrovtsiy（见 `LICENSE`）。`Stats.xcodeproj`、`Kit/`、`Modules/`、
`Stats/`、`Tests/` 等目录保持上游结构，方便 `git merge` 上游更新。

已知的分叉带来的差异：

· 上游的 `.github/workflows/release.yaml` 需要开发者证书与公证密钥，本仓库的
  `release.yaml` 改成了「构建 + 打 zip + 传 Release」，不签名不公证。
· `.github/FUNDING.yml` 已删除，它指向上游作者的赞助渠道；想支持上游请去
  [exelban/stats](https://github.com/exelban/stats)。
· bundle id 仍是 `eu.exelban.Stats`，与上游版共用一份配置
（`~/Library/Preferences/eu.exelban.Stats.plist`）。两个版本不要同时装。

## 许可

MIT，见 `LICENSE`。上游项目地址：<https://github.com/exelban/stats>。
