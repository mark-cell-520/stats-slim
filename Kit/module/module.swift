//
//  module.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 09/04/2020.
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa

public struct module_c {
    public var name: String
    public var icon: NSImage?
    
    public var defaultState: Bool = false
    internal var defaultWidget: widget_t = .unknown
    internal var availableWidgets: [widget_t] = []
    
    internal var widgetsConfig: NSDictionary = NSDictionary()
    internal var settingsConfig: NSDictionary = NSDictionary()
    internal var previewConfig: NSDictionary = NSDictionary()
    
    public var hasPreview: Bool { self.previewConfig["available"] as? Bool ?? false }
    
    init(in path: String) {
        let dict: NSDictionary = NSDictionary(contentsOfFile: path)!
        
        if let name = dict["Name"] as? String {
            self.name = name
        } else {
            fatalError("failed to initialize module, name is missing")
        }
        
        if let state = dict["State"] as? Bool {
            self.defaultState = state
        }
        if let symbol = dict["Symbol"] as? String {
            self.icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        if self.icon == nil, let symbol = dict["AlternativeSymbol"] as? String {
            self.icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        
        if let widgetsDict = dict["Widgets"] as? NSDictionary {
            var list: [String: Int] = [:]
            self.widgetsConfig = widgetsDict
            
            for widgetName in widgetsDict.allKeys {
                if let widget = widget_t(rawValue: widgetName as! String) {
                    let widgetDict = widgetsDict[widgetName as! String] as! NSDictionary
                    if widgetDict["Default"] as! Bool {
                        self.defaultWidget = widget
                    }
                    var order = 0
                    if let o = widgetDict["Order"] as? Int {
                        order = o
                    }
                    
                    list[widgetName as! String] = order
                }
            }
            
            self.availableWidgets = list.sorted(by: { $0.1 < $1.1 }).map{ (widget_t(rawValue: $0.key) ?? .unknown) }
        }
        
        if let settingsDict = dict["Settings"] as? NSDictionary {
            self.settingsConfig = settingsDict
        }
        
        if let previewDict = dict["Preview"] as? NSDictionary {
            self.previewConfig = previewDict
        }
    }
}

open class Module {
    public var config: module_c
    
    public var available: Bool = false
    public var enabled: Bool = false
    
    public var menuBar: MenuBar
    // 设置窗口与弹窗都是「用户点开才需要」的东西，上游却在启动时为每个模块各建一份：
    // Window 会搭整套设置界面（分段控件、标签页、控件选择器、各设置容器），PopupWindow 会建
    // 一个 NSWindow 加整套弹窗视图。实测这两样在 10 个模块上一共占掉约 67M 物理内存
    // （141M → 74M），而绝大多数模块的设置和弹窗用户从来不打开。改成第一次用到时才建。
    // 所有访问点都在主线程（菜单栏点击、设置界面、启动流程），不需要额外加锁。
    private var _window: Window? = nil
    public var window: Window? {
        get {
            if self._window == nil {
                self._window = Window(
                    config: self.config,
                    widgets: self.menuBar.widgets,
                    // 传工厂而不是 self.previewViewRef / self.popupViewRef 本身：传实例会让这两个
                    // 实参在调用 Window.init 时就被求值，等于「打开设置窗口」顺带把该模块的
                    // Preview 与 Popup 两棵子树建出来。Popup 那棵因此推迟到用户真点到 Popup
                    // 标签页，原因见 Window.init 上的注释。
                    // 闭包用 [weak self]：否则 Module → _window → Window → 闭包 → Module 是个环。
                    // 模块本身由 AppDelegate 的 modules 数组持有、和进程同寿，这个环实际漏不掉
                    // 什么，但没有理由特意留一个。
                    modulePreview: { [weak self] in self?.previewViewRef },
                    moduleSettings: self.settingsView,
                    popupSettings: { [weak self] in self?.popupViewRef },
                    notificationsSettings: self.notificationsView
                )
            }
            return self._window
        }
        set { self._window = newValue }
    }
    public let portal: Portal_p?
    
    public var name: String { config.name }
    public var combinedPosition: Int {
        get { Store.shared.int(key: "\(self.name)_position", defaultValue: 0) }
        set { Store.shared.set(key: "\(self.name)_position", value: newValue) }
    }
    public var userDefaults: UserDefaults? = UserDefaults(suiteName: "\(Bundle.main.object(forInfoDictionaryKey: "TeamId") as! String).eu.exelban.Stats.widgets")

    // 弹窗快捷键直接从 Store 读，不从弹窗视图上取。Stats/helpers.swift 的 handleKeyEvent 会在
    // 每次按键时遍历所有模块比对这个值，而弹窗视图现在是懒建的——从视图上取会把所有模块的
    // 弹窗一次性全部建出来，正好把这项优化抵消掉。PopupWrapper 本来就以 Store 为准
    // （init 时读、setKeyboardShortcut 时写），所以这里读 Store 与读视图等价。
    public var popupKeyboardShortcut: [UInt16] {
        Store.shared.array(key: "\(self.config.name)_popup_keyboardShortcut", defaultValue: []) as? [UInt16] ?? []
    }

    private var moduleType: ModuleType

    private var settingsView: Settings_v? = nil
    private var notificationsView: NotificationsWrapper? = nil

    // 弹窗视图与预览页都是「用户点开才需要」的东西，上游却在模块 init 里就把整棵子树建出来：
    // Popup 子类在 init 里铺仪表盘、图表、详情、平均负载、进程列表，Preview 子类在 init 里铺
    // 十几行预览字段。10 个模块这两棵合计实测约 7-10M，而弹窗和设置窗口对绝大多数模块来说
    // 整个会话都不会打开一次。改成只存工厂，第一次用到时才建。
    // 设置页（Settings）与通知页（Notifications）刻意不动：Settings 的行是在 load(widgets:)
    // 里铺的、init 本身几乎不花钱，Notifications 的 init 只建几个通知 id，懒化它们没有收益，
    // 只会多两条要维护的路径。Portal 也不能懒化——Stats/Views/CombinedView.swift 要用
    // `m.portal != nil` 判断模块能不能进合并视图，懒了会全都判成不能进。
    private var popupViewFactory: (() -> Popup_p?)?
    private var previewViewFactory: (() -> PreviewWrapper?)?
    private var _popupView: Popup_p? = nil
    private var _previewView: PreviewWrapper? = nil
    // 这两棵视图改成启动后按需创建，写入发生在主线程（Module 自己的 window / popup getter
    // 都只在主线程被访问），但模块的读取器回调会在后台线程读它们。上游这里是 init 时一次性
    // 赋值的 let，怎么读都安全；现在多了一次运行期写入，就得加锁，否则后台线程可能读到
    // 赋值过程中的中间状态。锁只在创建时走一次，之后每次回调都是一次无竞争的 lock/unlock。
    private let lazyViewsLock = NSLock()

    /// 弹窗视图，第一次访问时创建。只给 Module 自己的 window / popup getter 用。
    public var popupViewRef: Popup_p? {
        self.lazyViewsLock.lock()
        var created = false
        if self._popupView == nil, let factory = self.popupViewFactory {
            self._popupView = factory()
            created = true
        }
        let view = self._popupView
        self.lazyViewsLock.unlock()
        // 钩子放在锁外调用：Sensors 的 popupViewDidLoad 会回头读 popupView，放锁内会死锁。
        if created { self.popupViewDidLoad() }
        return view
    }
    /// 已经建好的弹窗视图，不触发创建。模块的读取器回调走这个：弹窗没打开时，没必要为了
    /// 更新一个看不见的界面而把整套视图建出来。
    public var livePopupView: Popup_p? {
        self.lazyViewsLock.lock()
        defer { self.lazyViewsLock.unlock() }
        return self._popupView
    }
    /// 懒建的弹窗视图第一次建好时调用，让模块有机会往里填数据。Sensors 靠它把传感器列表
    /// 送进弹窗——它原来在 init 里就调一次 setup()，那会把懒建出来的视图立刻建回去。
    open func popupViewDidLoad() {}

    /// 预览页，第一次访问时创建。只给 Module 自己的 window getter 用。
    public var previewViewRef: PreviewWrapper? {
        self.lazyViewsLock.lock()
        var created = false
        if self._previewView == nil, let factory = self.previewViewFactory {
            self._previewView = factory()
            created = true
        }
        let view = self._previewView
        self.lazyViewsLock.unlock()
        if created { self.previewViewDidLoad() }
        return view
    }
    /// 已经建好的预览页，不触发创建。
    public var livePreviewView: PreviewWrapper? {
        self.lazyViewsLock.lock()
        defer { self.lazyViewsLock.unlock() }
        return self._previewView
    }
    open func previewViewDidLoad() {}

    private var _popup: PopupWindow? = nil
    private var popup: PopupWindow? {
        get {
            if self._popup == nil {
                self._popup = PopupWindow(title: self.config.name, module: self.moduleType, view: self.popupViewRef, visibilityCallback: self.popupVisibilityCallback)
            }
            return self._popup
        }
        set { self._popup = newValue }
    }
    
    private let log: NextLog
    private var readers: [Reader_p] = []
    private var popupVisible = false
    private var settingsVisible = false
    
    private var pauseState: Bool {
        get { Store.shared.bool(key: "pause", defaultValue: false) }
        set { Store.shared.set(key: "pause", value: newValue) }
    }
    
    public init(
        moduleType: ModuleType,
        popup: (() -> Popup_p?)? = nil,
        settings: Settings_v? = nil,
        portal: Portal_p? = nil,
        notifications: NotificationsWrapper? = nil,
        preview: (() -> PreviewWrapper?)? = nil
    ) {
        self.moduleType = moduleType
        self.portal = portal
        self.config = module_c(in: Bundle(for: type(of: self)).path(forResource: "config", ofType: "plist")!)

        self.log = NextLog.shared.copy(category: self.config.name)
        self.settingsView = settings
        self.popupViewFactory = popup
        self.previewViewFactory = preview
        self.notificationsView = notifications
        self.menuBar = MenuBar(moduleName: self.config.name)
        self.available = self.isAvailable()
        self.enabled = Store.shared.bool(key: "\(self.config.name)_state", defaultValue: self.config.defaultState)
        self.userDefaults?.set(self.enabled, forKey: "\(self.config.name)_state")
        
        if !self.available {
            debug("Module is not available", log: self.log)
            
            if self.enabled {
                self.enabled = false
                Store.shared.set(key: "\(self.config.name)_state", value: false)
            }
            
            return
        } else if self.pauseState {
            self.disable()
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(listenForMouseDownInSettings), name: .clickInSettings, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(listenForModuleToggle), name: .toggleModule, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(listenForPopupToggle), name: .togglePopup, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(listenForToggleWidget), name: .toggleWidget, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(listenForWindowOpen), name: .openWindow, object: nil)
        
        // swiftlint:disable empty_count
        if self.config.widgetsConfig.count != 0 {
            // swiftlint:enable empty_count
            self.initWidgets()
        } else {
            debug("Module started without widget", log: self.log)
        }

        // Window 与 PopupWindow 都不在这里建了，改由各自的 getter 在第一次用到时创建。
        // 启动时只建这两个的话，10 个模块一共要多付约 67M 物理内存，而设置窗口和弹窗
        // 对绝大多数模块来说整个会话都不会被打开一次。
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // load function which call when app start
    public func mount() {
        guard self.enabled else { return }
        self.startReaders()
        self.menuBar.enable()
    }
    
    // disable module
    public func unmount() {
        self.enabled = false
        self.available = false
    }
    
    // terminate function which call before app termination
    public func terminate() {
        self.willTerminate()
        self.readers.forEach{
            $0.stop()
            $0.terminate()
        }
        self.menuBar.disable()
        debug("Module terminated", log: self.log)
    }
    
    // function to call before module terminate
    open func willTerminate() {}
    
    // set module state to enabled
    public func enable() {
        guard self.available else { return }
        
        self.enabled = true
        Store.shared.set(key: "\(self.config.name)_state", value: true)
        self.userDefaults?.set(true, forKey: "\(self.config.name)_state")
        self.startReaders()
        self.menuBar.enable()
        self._window?.setState(self.enabled)
        debug("Module enabled", log: self.log)
    }
    
    // set module state to disabled
    public func disable() {
        guard self.available else { return }
        
        self.enabled = false
        if !self.pauseState { // omit saving the disable state when toggle by pause, need for resume state restoration
            Store.shared.set(key: "\(self.config.name)_state", value: false)
            self.userDefaults?.set(false, forKey: "\(self.config.name)_state")
        }
        self.readers.forEach {
            $0.lock()
            $0.stop()
        }
        self.popupVisible = false
        self.menuBar.disable()
        self._window?.setState(self.enabled)
        self._popup?.setIsVisible(false)
        debug("Module disabled", log: self.log)
    }
    
    public func setReaders(_ list: [Reader_p?]) {
        self.readers = list.filter({ $0 != nil }).map({ $0! as Reader_p })
    }
    
    // determine if module is available (can be overrided in module)
    open func isAvailable() -> Bool { return true }
    
    // load the widget and set up. Calls when module init
    private func initWidgets() {
        guard self.available else { return }
        
        self.config.availableWidgets.forEach { (widgetType: widget_t) in
            if let widget = widgetType.new(
                module: self.config.name,
                config: self.config.widgetsConfig,
                defaultWidget: self.config.defaultWidget,
                icon: self.config.icon
            ) {
                self.menuBar.append(widget)
            }
        }
    }
    
    // call when popup appear/disappear
    private func popupVisibilityCallback(_ state: Bool) {
        self.popupVisible = state
        self.updateReaderVisibility()
        if state {
            // 弹窗视图是懒建的，刚建出来还是空的。主动读一次，不然要等到下一个轮询周期
            // （最长一个间隔）才填上，头一两秒会显示空白。
            // 必须放后台队列：这个回调来自 PopupViewController.viewWillAppear，是主线程。
            // 有些 reader 的 read() 会 fork 子进程——蓝牙的 system_profiler 与 pmset 各自
            // 有 10 秒超时，CPU 的 fork ps 和 uptime、Disk 的 ps 加 SMART 也不便宜。
            // 在主线程同步跑这些，打开弹窗的瞬间界面就卡住，蓝牙最坏要卡 10 秒。
            // 上游这里只有 Kit/module/reader.swift 的后台异步读，所以没有这个问题。
            let readers = self.readers
            DispatchQueue.global(qos: .userInitiated).async {
                readers.forEach { $0.read() }
            }
        }
    }
    
    @objc private func listenForWindowOpen(_ notification: Notification) {
        guard let state = notification.userInfo?["state"] as? Bool else { return }
        self.settingsVisible = state && (notification.userInfo?["module"] as? String == self.config.name)
        self.updateReaderVisibility()
    }
    
    private func readerHasVisibleConsumer(_ reader: Reader_p) -> Bool {
        // Regular readers can enter sleep mode while either view is already open.
        let shared = reader.sleep || (!reader.popup && !reader.preview)
        return self.enabled && (
            (self.popupVisible && (reader.popup || shared)) ||
            (self.settingsVisible && (reader.preview || shared))
        )
    }
    
    private func startReaders() {
        self.readers.forEach { reader in
            reader.initStoreValues(title: self.config.name)
            if self.readerHasVisibleConsumer(reader) {
                reader.unlock()
            } else {
                reader.lock()
            }
            reader.start()
        }
    }
    
    private func updateReaderVisibility() {
        self.readers.forEach { reader in
            let visible = self.readerHasVisibleConsumer(reader)
            if visible {
                reader.unlock()
            } else {
                reader.lock()
            }
            guard reader.popup || reader.preview || reader.sleep else { return }
            
            if visible {
                reader.initStoreValues(title: self.config.name)
                reader.start()
            } else {
                reader.pause()
            }
        }
    }
    
    @objc private func listenForPopupToggle(_ notification: Notification) {
        guard let popup = self.popup,
              let name = notification.userInfo?["module"] as? String,
              let buttonOrigin = notification.userInfo?["origin"] as? CGPoint,
              let buttonCenter = notification.userInfo?["center"] as? CGFloat,
              self.config.name == name else {
            return
        }
        
        let openedWindows = NSApplication.shared.windows.filter{ $0 is NSPanel }
        openedWindows.forEach{ $0.setIsVisible(false) }
        
        var reopen: Bool = false
        if let widget = notification.userInfo?["widget"] as? widget_t {
            reopen = popup.openedBy != nil && popup.openedBy != widget
            popup.openedBy = widget
        }
        
        if popup.occlusionState.rawValue == 8192 || reopen {
            NSApplication.shared.activate(ignoringOtherApps: true)
            
            popup.contentView?.invalidateIntrinsicContentSize()
            
            let windowCenter = popup.contentView!.intrinsicContentSize.width / 2
            var x = buttonOrigin.x - windowCenter + buttonCenter
            let y = buttonOrigin.y - popup.contentView!.intrinsicContentSize.height - 3
            
            let buttonPoint = NSPoint(x: buttonOrigin.x + buttonCenter, y: buttonOrigin.y)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(buttonPoint) }) ?? NSScreen.main {
                if x + popup.contentView!.intrinsicContentSize.width > screen.frame.maxX {
                    x = screen.frame.maxX - popup.contentView!.intrinsicContentSize.width - 3
                }
                if x < screen.frame.minX {
                    x = screen.frame.minX + 3
                }
            }
            
            popup.setFrameOrigin(NSPoint(x: x, y: y))
            popup.setIsVisible(true)
        } else {
            popup.locked = false
            popup.openedBy = nil
            popup.setIsVisible(false)
        }
    }
    
    @objc private func listenForModuleToggle(_ notification: Notification) {
        if let name = notification.userInfo?["module"] as? String {
            if name == self.config.name {
                if let state = notification.userInfo?["state"] as? Bool {
                    if state && !self.enabled {
                        self.enable()
                    } else if !state && self.enabled {
                        self.disable()
                    }
                } else {
                    if self.enabled {
                        self.disable()
                    } else {
                        self.enable()
                    }
                }
            }
            
            if self.pauseState == true {
                self.pauseState = false
                NotificationCenter.default.post(name: .pause, object: nil, userInfo: ["state": false])
            }
        }
    }
    
    @objc private func listenForMouseDownInSettings() {
        if let popup = self._popup, popup.isVisible && !popup.locked {
            self._popup?.setIsVisible(false)
        }
    }
    
    @objc private func listenForToggleWidget(_ notification: Notification) {
        guard let name = notification.userInfo?["module"] as? String, name == self.config.name else {
            return
        }
        let isEmpty = self.menuBar.widgets.filter({ $0.isActive }).isEmpty
        if !isEmpty && !self.enabled {
            NotificationCenter.default.post(name: .toggleModule, object: nil, userInfo: ["module": self.config.name, "state": true])
        }
    }
}
