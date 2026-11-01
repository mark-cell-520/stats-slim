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
| 物理内存占用（活动监视器「内存」列） | 140.8 M | 约 75 M |
| RSS | 214.7 MB | 约 143 MB |
| CPU | 4.9 % | 约 1 % |
| 对外 ICMP 探测 | 3600 次/小时 | 120 次/小时 |
| 磁盘活动读数的 IOKit 遍历 | 3600 次/小时 | 720 次/小时 |
| fork 子进程（蓝牙外设电量） | 480 次/小时 | 120 次/小时 |
| LevelDB 常驻内存 | memtable 上限 4 MB + 8 MB 块缓存 | 1 MB + 2 MB |

测量方式：`ps -o rss=` 取 RSS，`heap <pid>` 取物理内存占用，`top -l 6 -s 2` 取稳定后的
CPU。各次数的来源见下面每一项的文件位置说明。

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

### 4. 磁盘活动读数不再钉在 1 秒（IOKit 遍历 3600 → 720 次/小时）

`Modules/Disk/readers.swift` 的 `ActivityReader.setup()` 原来写死 `setInterval(1)`，
于是设置界面里的「Update interval」对它完全不起作用——`Reader.initStoreValues` 见
`interval` 非空就直接返回，用户选的 5 秒永远被覆盖。而这一 tick 的代价很高：每个卷都要
`mountedVolumeURLs` + `DADiskCreateFromVolumePath` + `DADiskCopyIOMedia`，再沿 IOKit
注册表往上找存储驱动读统计字节数。速率是「字节差 / 时间差」，间隔长一点读数同样准。
改成本项目前共用的那个间隔键，并在 `Modules/Disk/main.swift` 的 `setInterval` 回调里
把活动读数一起接上（菜单栏带图表控件时仍会被压回 1 秒，与上游一致）。

### 5. 网络读数不再每个 tick 复制整套系统代理配置

`Modules/Net/readers.swift`：`if self.vpnConnection && self.VPNMode` 的两个条件顺序
对调。`vpnConnection` 要调 `CFNetworkCopySystemProxySettings()` 把整套代理配置复制出来
再扫一遍 scope 名，而 `VPNMode` 只是内存字典里的一次查找。VPN 修正默认关闭，对调之后
这一 tick 直接短路，1800 次每小时的系统代理复制全省掉。

### 6. 蓝牙外设电量的子进程 fork 减到四分之一（480 → 120 次/小时）

`Modules/Bluetooth/readers.swift`：`profilerTTL` 30 → 60 秒、`pmsetTTL` 10 → 30 秒。
这两个缓存 TTL 就是 `system_profiler` 与 `pmset` 各被 fork 一次的频率，读出来的只是
外设电量，晚一分钟对这类读数没有影响。

### 7. DB 写盘前不再白编码一次，节流 30 秒 → 60 秒

`Kit/plugins/DB.swift`：`insert()` 原来每次调用都先 `JSONEncoder().encode(value)`，
再判断这一轮要不要真写盘（内部有节流）。被节流掉的那些次，编码结果是直接扔掉的。
把编码挪到节流判断之后，同时把节流从 30 秒放到 60 秒——这份「最后一次读数」只在下次
启动时用来让菜单栏不至于空一瞬，晚一分钟没有区别，而 LevelDB 的写入量减半。

### 8. 内嵌 LevelDB 的缓冲区收回收（常驻约省 2.5 M）

`Kit/lldb/lldb.m`：`leveldb::Options` 原来只设 `create_if_missing`，其余全默认。
默认 `write_buffer_size` 是 4 MB（未落盘的 memtable 整个住在内存里，LevelDB 的注释还
写明最多可能同时持有两个），不设 `block_cache` 时内部会自建 8 MB 的 LRU。Stats 全部
数据才几百 KB 到几 MB，这两个默认值纯占地方。改成 1 MB / 2 MB 后落表从约 70 分钟一次
变成约 20 分钟一次，每次落表加 compaction 实测 10–20 ms、产出只有几十 KB，代价可以忽略。

### 9. app 进程不再链接 WidgetKit / SwiftUI / Charts

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

## 还有什么没动

启动时每个模块仍会预建五棵视图树（`Settings` / `Popup` / `Portal` / `Notifications` /
`Preview`，见各模块 `main.swift` 的 `init`），实测合计约 10–14 M。其中 `Settings` 的
行是在 `load(widgets:)` 里建的、`init` 本身很便宜，真正贵的是 `Popup` 与 `Preview`
子类在 `init` 里直接铺行，以及 `PortalWrapper.init` 调的 `load()`。这一批要改成懒加载
得同时动 10 个模块的约 400 处引用（每个访问点都要区分「已建好」和「顺手建出来」），
收益是当前占用的 15 % 左右，但界面回归风险明显高于上面各项，所以这一轮没做。

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
