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

## 第五轮（2026-11-01）：全面审计与全局修复

前四轮改的都是「已知的浪费」，这一轮是把整个代码base过一遍，把审计出来的问题一次修掉。
25 个文件、约 390 行新增。分四类。

### 1. 前几轮懒加载引入的三个缺陷（都会直接影响使用）

· **Net 模块的定位授权按钮点了没反应。** `Modules/Net/main.swift` 原来在 `init` 里写
  `self.popupView?.locationPermissionAction = {...}`，而 `popupView` 是
  `self.livePopupView as? Popup`——不触发创建的那个访问器。弹窗视图改成懒建之后，
  `init` 执行时它还是 `nil`，整条赋值被可选链短路掉，闭包从来没被装上。后果是弹窗里那颗
  「允许访问 Wi-Fi 详情」按了什么都不发生，SSID、信道、协议永久空白，也跳不到系统设置的
  定位面板。改到新增的 `popupViewDidLoad()` 钩子里补上（和 Sensors 同一个钩子）。
· **GPU 与 Disk 的读取器有数据竞争，打开对应弹窗时可能崩。** `InfoReader.read()` 和
  `SMARTReader.read()` 都在无锁的情况下 `append` / 下标写 / `sort self.list`。而 `read()`
  现在有两个并发入口：`Kit/module/reader.swift` 的后台轮询，以及第三轮加进来的
  「弹窗打开时主动读一次」（跑在后台队列上）。后台那次常常还没跑完，用户就点开了弹窗，
  两边同时写同一个数组就是 Swift 排他性检查 trap 或者 COW 缓冲区踩踏。两个 reader 各加了
  一把 `NSLock`，整段串行化（读取本身只有几毫秒）。
· **打开弹窗时界面会卡住，蓝牙最坏 10 秒。** 上面说的那次主动读原来直接跑在主线程
  （`PopupViewController.viewWillAppear` 调过来的）。蓝牙弹窗会 fork `system_profiler`
  和 `pmset`，各自的超时是 10 秒；CPU 弹窗连 fork 三次 `ps`/`uptime`/`pmset`；Disk 弹窗
  fork `ps` 加整轮 SMART。改成派发到后台队列，主线程不再等这些。

### 2. 周期性开销（常驻程序的 CPU 主要就来自这里）

· **Disk 进程读数是全书单 tick 最贵的一处，而用户完全无法调它的间隔。** 它原来在
  `setup()` 里写死 `setInterval(1)`，于是设置界面里的「Update interval」对它不起作用
  （`Reader.initStoreValues` 见 `interval` 非空就直接返回）。这一 tick 要 fork 一次
  `ps -Aceo`，再对输出里每个进程各做一次 `proc_pid_rusage`。改成跟随用户选的那个间隔，
  并接进 `Modules/Disk/main.swift` 的 `setInterval` 回调（那里已经接着容量读数和活动读数）。
· **Disk 进程读数的快照字典无上限增长。** 它每 tick `var snapshot = self.list`，只往里面
  写、从不删，ps 里已经消失的 PID 永远留着；macOS 的 PID 要涨到 99999 才回绕，于是这张表
  随运行时间单调增长，是全工程唯一真正漏的结构。而且 Swift 字典是值类型，getter 返回后
  第一次写入就整表 COW 拷贝，表越长这笔 memcpy 越贵。改成枚举结束时删掉不在本轮输出里的 key。
· **Net 每 tick 向 configd 要二十几次主接口名。** `interfaceID` 的 getter 是
  `Store.shared.string(key:defaultValue:)`，而 `defaultValue` 是普通参数不是 `@autoclosure`，
  所以每次读它都会实跑一遍 `primaryInterface`——`SCDynamicStoreCopyValue` 向 configd 要一次
  `State:/Network/Global/IPv4`，虚拟接口时还要再走 `physicalInterface()` 里的 `getifaddrs`。
  而 `readInterfaceBandwidth()` 在 `getifaddrs` 的循环里对每个接口各读一次，一台机器上
  二十来个接口。改成每 tick 开头解析一次、本 tick 内复用。
· **Net 每 tick 为一百多个进程各建一个 `NSRunningApplication`，最后只留 8 个。**
  `nettop -P` 把所有带 socket 的进程都列出来，而构造 `NSRunningApplication` 是一次到
  loginwindow 的 XPC 往返。改成先用 nettop 输出的进程名，等排序和 `suffix()` 截断做完，
  只给真正要显示的那几个换 `localizedName`。
· **Sensors 弹窗关着的时候，每 tick 仍然唤醒主线程几十次。** `usageCallback` 是无条件
  `DispatchQueue.main.async`，块里才判断 `window?.isVisible`。一台 M 机上 30-60 个传感器，
  每个都建了 `LineChartView`，等于每 2 秒给一堆看不见的图表补点、全天不停，正好是 App Nap
  最怕的形态。把可见性判断提到派发之前：已经渲染过就只更新缓存值，等弹窗真打开时
  `appear()` 里的 `replay()` 一次性补上。
· **Sensors 每 tick 把整张传感器表重算六遍。** 六个 `filter{}.map{}` 全表扫（每个都新建一个
  100-200 元素的数组，元素还是装箱的存在值），加上本函数后面十几处
  `firstIndex(where: { $0.key == "..." })` 的线性查找，最后再建一个 100-200 项的字典。
  改成一趟循环同时做三件事：更新值、收集统计量、建一张 key → 下标的表；后面全部改成查表，
  回写时也复用这张表。这些读数本身都是慢变量，为它们每 tick 反复全表重算是纯浪费。
· **SMC 读全程持锁，把 18-36 万次内核 IPC 每小时整个串行化。** `SMC/smc.swift` 的 `read()`
  原来把两次 `IOConnectCallStructMethod` 都罩在进程级单例锁里，而 Sensors 每 tick 读
  50-100 个 key。CPU 的温度读数、GPU 的信息读数、电池的用电读数全排在 Sensors 后面。
  重新划了锁的边界：**查元数据那一步留在锁内**（`Tests/SMC.swift` 的
  `testConcurrentReadsShareMetadataCache` 明确要求 100 个并发读只问驱动一次，锁一放后面的
  线程就会跟着 miss、跟着再问一遍），查到就立刻写进缓存，然后放锁；**每个 tick 都发生的
  读数据那一步移到锁外**。这个边界是先按「只保护字典」改了一版、被那个测试逮回来之后才定下来的。
· **所有 reader 的定时器相位完全一致，每次休眠唤醒都是一次惊群。** `Repeater` 的 deadline
  都是 `now + interval`，而所有 reader 的定时器都在启动后几毫秒内相继建立。唤醒后
  repeating 定时器全部变成「已过期」，约 12 个常驻 reader 会在 200 毫秒的 leeway 里同时补跑。
  给首次触发加一个 `[0, interval)` 的随机偏移，稳态周期不变；需要严格对齐秒边界的调用方
  （`Reader.alignToSecondBoundary`）不抖。
· **电池弹窗的 `top` 每次采两遍全系统。** `-l 2` 让 top 采两次样本再输出，每次约 0.3-0.6 秒
  CPU、1-2 秒墙钟，而这个 reader 的间隔是 2 秒，弹窗开着时等于让 top 背靠背地跑。
  这里要的只是 `power` 那一列的瞬时值，一次采样就够，改成 `-l 1`。
· **RAM 弹窗的 `top` 默认 1 秒一次。** `updateTopInterval` 默认 1，而 macOS 的 `top` 本身就是
  个全系统采样器，单次约 0.3-1 秒 CPU。改成 3，用户在设置里改这个键即可覆盖。
· **蓝牙每 tick 全量枚举一次已配对设备。** `IOBluetoothDevice.pairedDevices()` 单次几十毫秒，
  而这个 reader 跟随模块间隔（默认 2 秒）。已配对设备列表半天才变一次，加了个 30 秒 TTL，
  和旁边 `profilerCache` / `pmsetCache` 一个写法。

### 3. 启动时常驻内存

· **合并视图的弹窗启动时就建。** `Stats/Views/CombinedView.swift` 的 `init` 无条件
  `PopupWindow(title:view:Popup())`，而 `CombinedModules` 默认是关的——关着的时候用户永远看不到
  这个弹窗，却照样在启动时建出一个 NSWindow 加 NSScrollView + NSVisualEffectView，还把 9 个
  模块的 portal 全挂成子视图。改成懒建，和 `Module` 的 `window` / `popup` 同一个套路。
· **打开某个模块的设置窗口，会顺带把它的 Preview 与 Popup 两棵子树建出来。**
  `Module.window` 的 getter 把 `self.previewViewRef` / `self.popupViewRef` 作为实参传给
  `Window.init`，传实例就等于在调用时求值。Popup 那棵只在用户真点到 Popup 标签页时才用得上
  （`loadPopupSettings()` 的调用点在 `tabView.view` 的惰性闭包里）。改成传工厂闭包，Popup
  子树推迟到第一次显示那个标签页。对 Sensors 还顺带避开一件事：`popupViewDidLoad()` 会
  提前给每个 FanView 发一遍 `setFanMode` / `setSpeed` 的 SMC XPC。
  Preview 那棵没有推迟空间——它默认就顶着设置界面显示，见 `Window.preview()`。
· **60 张只在设置窗口出现的预览图，从启动活到退出。** `widget_t.new()` 为每个模块的每种
  控件各建一张 `NSImage`（10 个模块共 60 个控件类型），每张都是一个 NSPDFImageRep 加一份
  解析后的 CGPDFDocument。改成只存 `dataWithPDF` 出来的字节，访问时才解，窗口关掉就释放。
  没有在 SWidget 里缓存解出来的图，也没有连 preview 视图一起存——后者会把 60 棵预览视图树
  留在内存里，比这 60 张图贵得多，正好和前三轮的懒加载反着来。

### 4. 两处会给出错误答案的缺陷，和一个跑不起来的测试目标

· **`isNewestVersion` 在 beta 对 beta 时永远返回 true。** 三个分支的公共条件写成了
  `latest.patch >= current.patch`，于是「当前 beta2、最新 beta1」也告诉用户有新版本，
  甚至「当前 beta1、最新 beta1」每次启动都弹一次更新。重写成按
  (major, minor, patch, beta) 依次比，并且加了一条上游没有的规则：最新版是 beta 而当前版
  不是 → 不算有新版本（不能把稳定版用户往 beta 上推）。
· **设置界面显示的间隔和实际跑的不是一回事。** `Reader.defaultInterval` 第二轮从 1 改成了 2，
  但各模块 Settings 视图里 `updateIntervalValue` 的初值没跟着改：全新安装下 CPU/GPU/RAM
  实际 2 秒而界面显示 1 秒、Sensors 实际 2 秒显示 3 秒、Disk 实际 2 秒显示 10 秒、
  Net 的 ICMP 实际 30 秒显示 1 秒。五处初值都对齐到实际值，并在 `defaultInterval` 上写了注释
  说明这两处必须同步。
· **Tests 目标从建库起就编不过，仓库里其他测试一个都跑不了。** `Tests/Disk.swift` 调了
  `drive(uuid:BSDName:)`，而 `drive` 只有一个 public 的 `init(size:free:)`。因为整个目标编不过，
  Kit / RAM / Bluetooth / Disk 的其余测试从来没在 CI 里跑过（CI 只有 `linter`、`build`、
  `release`、`smc-tests` 四条工作流，没有一条跑它）。改成先建再赋值，测试要表达的意思不变。
  修好之后这个目标第一次真正跑起来：25 个测试，其中 `testIsNewestVersion_beta` 红了 2 条，
  就是上面那个 beta 比较 bug。

### 这一轮验证到什么程度

· Xcode Tests 目标 25 个测试全过（修好之后才第一次能跑）。
· `make test-smc` 166 个测试全过（intel 76 + arm64 90）。SMC 锁边界那版改动是先被
  `testConcurrentReadsShareMetadataCache` 逮住、退回重做才过的。
· Release 构建 0 error，产物是通用二进制（x86_64 + arm64），版本校验通过，zip 9.09 MB。
· 上面每一项都在代码注释里写了文件位置、原因和回退方法，可以单独回退。

**没有验证到的**：这一轮没有重新测内存与 CPU 的绝对值，上面凡是提到量级的地方都写的是
「频率」和「每次的代价」，不是实测的占用变化。Sensors `read()` 的重写是靠编译加逐行比对
  语义保证的，没有为它写测试——它的输入是 SMC 与 IOKit，仓库现有的测试手法（
  `Kit/scripts/run-smc-tests.py` 那套「一次性源码副本 + 替换系统调用边界」）要mock的边界太多，
  这一轮没有搭。安装与发布的注意事项见下面「安装」一节。

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
