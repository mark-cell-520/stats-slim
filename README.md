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
| 物理内存占用（活动监视器「内存」列） | 140.8 M | 48.4 M |
| RSS | 214.7 MB | 108.6 MB |
| CPU | 4.9 % | 约 1 % |
| 线程数 | 19 | 12 |
| 对外 ICMP 探测 | 3600 次/小时 | 120 次/小时 |
| 磁盘活动读数的 IOKit 遍历 | 3600 次/小时 | 720 次/小时 |
| fork 子进程（蓝牙外设电量） | 480 次/小时 | 120 次/小时 |
| 启动时预建的视图树 | 10 模块 × 7 棵 | 10 模块 × 3 棵 |
| LevelDB 常驻内存 | memtable 上限 4 MB + 8 MB 块缓存 | 1 MB + 2 MB |

测量方式：`ps -o rss=` 取 RSS，`heap <pid>` 取物理内存占用，`top -l 6 -s 2` 与
`ps -o time=` 取稳定后的 CPU。各次数的来源见下面每一项的文件位置说明。

## 改了什么

### 1. 启动时预建的窗口与视图树改成懒加载（内存 140.8 M → 48.4 M，占大头）

上游 `Kit/module/module.swift` 的 `Module.init` 会收到每个模块传进来的七棵视图树，
并且全部在启动时建完。本分支把其中四棵改成第一次用到时才建：

· `Window`（整套设置界面：分段控件、标签页、控件选择器、各设置容器）与 `PopupWindow`
  （一个 NSWindow 加整套弹窗视图）——改成 `private var _window` / `_popup` 加计算属性。
· 模块自己的 `Popup` 与 `Preview` 子树——`Module.init` 改为只收工厂闭包
  （`popup: { Popup(.CPU) }`），第一次访问 `popupViewRef` / `previewViewRef` 时才建。

四棵加起来实测 92.4 M 物理内存（140.8 M → 48.4 M）。剩下三棵刻意不动：

· `Settings` 的行是在 `load(widgets:)` 里铺的，`init` 本身几乎不花钱；
· `Notifications` 的 `init` 只建几个通知 id；
· `Portal` 不能懒化——`Stats/Views/CombinedView.swift` 要用 `m.portal != nil`
  判断模块能不能进合并视图，懒了会全都判成不能进。

配套的三处细节，都是懒化必须处理的：

· 读取器回调改走 `livePopupView` / `livePreviewView`（不触发创建）。弹窗没打开时，
  没必要为了更新一个看不见的界面而把整套视图建出来。
· `popupKeyboardShortcut` 改为直接读 Store。`Stats/helpers.swift` 的 `handleKeyEvent`
  会在每次按键时遍历所有模块比对这个值，从视图上取会把所有模块的弹窗一次性全建出来。
· `Module.popupViewDidLoad()` / `previewViewDidLoad()` 钩子。Sensors 原来在 `init` 里
  调一次 `popupView.setup(...)` 把传感器列表送进弹窗，那会把懒建出来的视图立刻建回去；
  现在改由钩子在视图第一次建好时补上。弹窗打开时还会主动读一次，免得头两秒显示空白。

懒加载引入了一次运行期写入（原来 `popupView` 是 init 时一次性赋值的 `let`），
而模块的读取器回调在后台线程读它，所以 `_popupView` / `_previewView` 的读写都过了
一把 `NSLock`。锁只在创建时走一次，之后每次回调都是一次无竞争的 lock/unlock。

这是本分支唯一的大改动，也是唯一一处行为差异：设置窗口与弹窗第一次打开时会比之前稍慢
一次（建界面），之后无差别。

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
于是设置界面里的「Update interval」对它完全不起作用（`Reader.initStoreValues` 见
`interval` 非空就直接返回）。而这一 tick 的代价很高：每个卷都要 `mountedVolumeURLs` +
`DADiskCreateFromVolumePath` + `DADiskCopyIOMedia`，再沿 IOKit 注册表往上找存储驱动
读统计字节数。速率是「字节差 / 时间差」，间隔长一点读数同样准。改成本项目前共用的那个
间隔键，并在 `Modules/Disk/main.swift` 的 `setInterval` 回调里把活动读数一起接上
（菜单栏带图表控件时仍会被压回 1 秒，与上游一致）。

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

### 8. 内嵌 LevelDB 的缓冲区回收（常驻约省 2.5 M）

`Kit/lldb/lldb.m`：`leveldb::Options` 原来只设 `create_if_missing`，其余全默认。
默认 `write_buffer_size` 是 4 MB（未落盘的 memtable 整个住在内存里，LevelDB 的注释还
写明最多可能同时持有两个），不设 `block_cache` 时内部会自建 8 MB 的 LRU。Stats 全部
数据才几百 KB 到几 MB，这两个默认值纯占地方。改成 1 MB / 2 MB 后落表从约 70 分钟一次
变成约 20 分钟一次，每次落表加 compaction 实测 10–20 ms、产出只有几十 KB，代价可以忽略。
注意要显式 `#import <cache.h>` 才拿得到 `NewLRUCache`。

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

想单独验证懒加载是否生效，数一下这几类对象在不在堆里就行——懒化之后启动时它们应该是 0：

```bash
heap $PID | awk 'NF>=6 && $2 ~ /^[0-9]+$/ {print $1"\t"$(NF-1)}' \
  | grep -cE "LabelField|ValueField|TextView|PreferencesRow"
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
· `Module.init` 的签名变了：`popup` 与 `preview` 两个参数从「传视图实例」改成
  「传工厂闭包」，模块侧 `private let popupView: Popup` 相应变成计算属性。
  合并上游的模块改动时要留意这里。
· bundle id 仍是 `eu.exelban.Stats`，与上游版共用一份配置
  （`~/Library/Preferences/eu.exelban.Stats.plist`）。两个版本不要同时装。

## 许可

MIT，见 `LICENSE`。上游项目地址：<https://github.com/exelban/stats>。
