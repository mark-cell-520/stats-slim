//
//  main.swift
//  Memory
//
//  Created by Serhiy Mytrovtsiy on 12/04/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

public struct RAM_Usage: Codable, RemoteType {
    public var total: Double
    public var used: Double
    public var free: Double
    
    var active: Double
    var inactive: Double
    var wired: Double
    var compressed: Double
    
    var app: Double
    var cache: Double
    
    var swap: Swap
    public var pressure: Pressure
    
    public init(
        total: Double = 0, used: Double = 0, free: Double = 0, active: Double = 0, inactive: Double = 0,
        wired: Double = 0, compressed: Double = 0, app: Double = 0, cache: Double = 0,
        swap: Swap = Swap(), pressure: Pressure = Pressure(), swapins: Int64 = 0, swapouts: Int64 = 0
    ) {
        self.total = total
        self.used = used
        self.free = free
        self.active = active
        self.inactive = inactive
        self.wired = wired
        self.compressed = compressed
        self.app = app
        self.cache = cache
        self.swap = swap
        self.pressure = pressure
        self.swapins = swapins
        self.swapouts = swapouts
    }

    var swapins: Int64
    var swapouts: Int64
    
    public var usage: Double {
        get { Double((self.total - self.free) / self.total) }
    }
    
    public func remote() -> Data? {
        let string = "\(self.total),\(self.used),\(self.pressure.level),\(self.swap.used)$"
        return string.data(using: .utf8)
    }
}

public struct Swap: Codable {
    public var total: Double
    public var used: Double
    public var free: Double

    public init(total: Double = 0, used: Double = 0, free: Double = 0) {
        self.total = total
        self.used = used
        self.free = free
    }
}

public struct Pressure: Codable {
    public var level: Int
    public var value: RAMPressure

    public init(level: Int = 0, value: RAMPressure = .normal) {
        self.level = level
        self.value = value
    }
}

public class RAM: Module {
    private var popupView: Popup? { self.livePopupView as? Popup }
    private let settingsView: Settings
    private let portalView: Portal
    private let notificationsView: Notifications
    private var previewView: Preview? { self.livePreviewView as? Preview }
    
    private var usageReader: UsageReader? = nil
    private var processReader: ProcessReader? = nil
    
    private var splitValueState: Bool {
        return Store.shared.bool(key: "\(self.config.name)_splitValue", defaultValue: false)
    }
    private var appColor: NSColor {
        let color = SColor.secondBlue
        let key = Store.shared.string(key: "\(self.config.name)_appColor", defaultValue: color.key)
        if let c = SColor.fromString(key).additional as? NSColor {
            return c
        }
        return color.additional as! NSColor
    }
    private var wiredColor: NSColor {
        let color = SColor.secondOrange
        let key = Store.shared.string(key: "\(self.config.name)_wiredColor", defaultValue: color.key)
        if let c = SColor.fromString(key).additional as? NSColor {
            return c
        }
        return color.additional as! NSColor
    }
    private var compressedColor: NSColor {
        let color = SColor.pink
        let key = Store.shared.string(key: "\(self.config.name)_compressedColor", defaultValue: color.key)
        if let c = SColor.fromString(key).additional as? NSColor {
            return c
        }
        return color.additional as! NSColor
    }
    
    private var textValue: String {
        Store.shared.string(key: "\(self.name)_textWidgetValue", defaultValue: "$mem.used/$mem.total ($pressure.value)")
    }
    
    private var systemWidgetsUpdatesState: Bool {
        self.userDefaults?.bool(forKey: "systemWidgetsUpdates_state") ?? false
    }
    
    public init() {
        self.settingsView = Settings(.RAM)
        self.portalView = Portal(.RAM, height: 80)
        self.notificationsView = Notifications(.RAM)
        
        super.init(
            moduleType: .RAM,
            popup: { Popup(.RAM) },
            settings: self.settingsView,
            portal: self.portalView,
            notifications: self.notificationsView,
            preview: { Preview(.RAM) }
        )
        guard self.available else { return }
        
        self.settingsView.callback = { [weak self] in
            self?.usageReader?.read()
        }
        self.settingsView.setInterval = { [weak self] value in
            self?.processReader?.read()
            self?.usageReader?.setInterval(value)
        }
        self.settingsView.setTopInterval = { [weak self] value in
            self?.processReader?.setInterval(value)
        }
        
        self.usageReader = UsageReader(.RAM) { [weak self] value in
            self?.loadCallback(value)
        }
        self.processReader = ProcessReader(.RAM) { [weak self] value in
            if let list = value {
                self?.popupView?.processCallback(list)
                self?.previewView?.processCallback(list)
            }
        }
        
        self.settingsView.callbackWhenUpdateNumberOfProcesses = { [weak self] in
            self?.popupView?.numberOfProcessesUpdated()
            self?.previewView?.numberOfProcessesUpdated()
            DispatchQueue.global(qos: .background).async {
                self?.processReader?.read()
            }
        }
        
        self.setReaders([self.usageReader, self.processReader])
    }
    
    private func loadCallback(_ raw: RAM_Usage?) {
        guard let value = raw, self.enabled else { return }
        
        self.popupView?.loadCallback(value)
        self.portalView.callback(value)
        self.notificationsView.loadCallback(value)
        self.previewView?.loadCallback(value)
        
        let total: Double = value.total == 0 ? 1 : value.total
        self.menuBar.widgets.filter{ $0.isActive }.forEach { (w: SWidget) in
            switch w.item {
            case let widget as Mini:
                widget.setValue(value.usage)
                widget.setPressure(value.pressure.value)
            case let widget as LineChart:
                widget.setValue(value.usage)
                widget.setPressure(value.pressure.value)
            case let widget as BarChart:
                if self.splitValueState {
                    widget.setValue([[
                        ColorValue(value.app/total, color: self.appColor),
                        ColorValue(value.wired/total, color: self.wiredColor),
                        ColorValue(value.compressed/total, color: self.compressedColor)
                    ]])
                } else {
                    widget.setValue([[ColorValue(value.usage)]])
                    widget.setColorZones((0.8, 0.95))
                    widget.setPressure(value.pressure.value)
                }
            case let widget as PieChart:
                widget.setValue([
                    ColorValue(value.app/total, color: self.appColor),
                    ColorValue(value.wired/total, color: self.wiredColor),
                    ColorValue(value.compressed/total, color: self.compressedColor)
                ])
            case let widget as MemoryWidget:
                let free = Units(bytes: Int64(value.free)).getReadableMemory(style: .memory)
                let used = Units(bytes: Int64(value.used)).getReadableMemory(style: .memory)
                widget.setValue((free, used), usedPercentage: value.usage)
                widget.setPressure(value.pressure.value)
            case let widget as Tachometer:
                widget.setValue([
                    ColorValue(value.app/total, color: self.appColor),
                    ColorValue(value.wired/total, color: self.wiredColor),
                    ColorValue(value.compressed/total, color: self.compressedColor)
                ])
            case let widget as TextWidget:
                var text = "\(self.textValue)"
                let pairs = TextWidget.parseText(text)
                pairs.forEach { pair in
                    var replacement: String? = nil
                    
                    switch pair.key {
                    case "$mem":
                        switch pair.value {
                        case "total": replacement = Units(bytes: Int64(value.total)).getReadableMemory(style: .memory)
                        case "used": replacement = Units(bytes: Int64(value.used)).getReadableMemory(style: .memory)
                        case "free": replacement = Units(bytes: Int64(value.free)).getReadableMemory(style: .memory)
                        case "active": replacement = Units(bytes: Int64(value.active)).getReadableMemory(style: .memory)
                        case "inactive": replacement = Units(bytes: Int64(value.inactive)).getReadableMemory(style: .memory)
                        case "wired": replacement = Units(bytes: Int64(value.wired)).getReadableMemory(style: .memory)
                        case "compressed": replacement = Units(bytes: Int64(value.compressed)).getReadableMemory(style: .memory)
                        case "app": replacement = Units(bytes: Int64(value.app)).getReadableMemory(style: .memory)
                        case "cache": replacement = Units(bytes: Int64(value.cache)).getReadableMemory(style: .memory)
                        case "swapins": replacement = "\(value.swapins)"
                        case "swapouts": replacement = "\(value.swapouts)"
                        default: return
                        }
                    case "$swap":
                        switch pair.value {
                        case "total": replacement = Units(bytes: Int64(value.swap.total)).getReadableMemory(style: .memory)
                        case "used": replacement = Units(bytes: Int64(value.swap.used)).getReadableMemory(style: .memory)
                        case "free": replacement = Units(bytes: Int64(value.swap.free)).getReadableMemory(style: .memory)
                        default: return
                        }
                    case "$pressure":
                        switch pair.value {
                        case "level": replacement = "\(value.pressure.level)"
                        case "value": replacement = value.pressure.value.rawValue
                        default: return
                        }
                    default: return
                    }
                    
                    if let replacement {
                        let key = pair.value.isEmpty ? pair.key : "\(pair.key).\(pair.value)"
                        text = text.replacingOccurrences(of: key, with: replacement)
                    }
                }
                widget.setValue(text)
            case let widget as DotWidget: widget.setValue(value.pressure.value.pressureColor())
            default: break
            }
        }
        
        if self.systemWidgetsUpdatesState {
            SystemWidgetUpdates.shared.update(value, key: "RAM@UsageReader", kinds: [RAMWidgetKind, "UnitedWidget"], defaults: self.userDefaults)
        }
    }
}

// 桌面组件的 kind。此字符串必须与 widget.swift 里 RAM_entry.kind 保持一致——
// 那个结构体现在只编进 WidgetsExtension 目标，app 侧链接不到，所以在这里留一份字面量。
internal let RAMWidgetKind = "RAMWidget"
