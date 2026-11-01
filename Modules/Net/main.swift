//
//  main.swift
//  Net
//
//  Created by Serhiy Mytrovtsiy on 24/05/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit
import SystemConfiguration

public enum Network_t: String, Codable {
    case wifi
    case ethernet
    case bluetooth
    case other
}

public struct Network_interface: Codable {
    public var status: Bool = false
    public var displayName: String = ""
    public var BSDName: String = ""
    public var address: String = ""
    public var transmitRate: Double = 0

    public init(status: Bool = false, displayName: String = "", BSDName: String = "", address: String = "", transmitRate: Double = 0) {
        self.status = status
        self.displayName = displayName
        self.BSDName = BSDName
        self.address = address
        self.transmitRate = transmitRate
    }
}

public struct Network_addr: Codable {
    public var v4: String? = nil
    public var v6: String? = nil
    public var countryCode: String? = nil

    public init(v4: String? = nil, v6: String? = nil, countryCode: String? = nil) {
        self.v4 = v4
        self.v6 = v6
        self.countryCode = countryCode
    }
}

public struct Network_wifi: Codable {
    public var countryCode: String? = nil
    public var ssid: String? = nil
    var bssid: String? = nil
    var RSSI: Int? = nil
    var noise: Int? = nil
    
    var standard: String? = nil
    var mode: String? = nil
    var security: String? = nil
    var channel: String? = nil
    
    var channelBand: String? = nil
    var channelWidth: String? = nil
    var channelNumber: String? = nil
    
    mutating func reset() {
        self.countryCode = nil
        self.ssid = nil
        self.bssid = nil
        self.RSSI = nil
        self.noise = nil
        self.standard = nil
        self.mode = nil
        self.security = nil
        self.channel = nil
        self.channelBand = nil
        self.channelWidth = nil
        self.channelNumber = nil
    }
}

public struct Bandwidth: Codable {
    public var upload: Int64 = 0
    public var download: Int64 = 0

    public init(upload: Int64 = 0, download: Int64 = 0) {
        self.upload = upload
        self.download = download
    }
}

enum WiFiLocationAuthorization: String, Codable {
    case notDetermined, denied, authorized
}

public struct Network_Usage: Codable, RemoteType {
    public var bandwidth: Bandwidth = Bandwidth()
    var total: Bandwidth = Bandwidth()
    
    var laddr: Network_addr = Network_addr() // local ip
    public var raddr: Network_addr = Network_addr() // remote ip
    
    var dns: [String] = []
    
    public var interface: Network_interface? = nil
    public var connectionType: Network_t? = nil
    public var status: Bool = false
    
    public var wifiDetails: Network_wifi = Network_wifi()
    var wifiLocationAuthorization: WiFiLocationAuthorization?

    public init(bandwidth: Bandwidth = Bandwidth(), raddr: Network_addr = Network_addr(), interface: Network_interface? = nil, status: Bool = false) {
        self.bandwidth = bandwidth
        self.raddr = raddr
        self.interface = interface
        self.status = status
    }

    mutating func reset() {
        self.bandwidth = Bandwidth()
        
        self.laddr = Network_addr()
        self.raddr = Network_addr()
        
        self.dns = []
        
        self.interface = nil
        self.connectionType = nil
        
        self.wifiDetails.reset()
    }
    
    public func remote() -> Data? {
        let addr = "\(self.laddr.v4 ?? ""),\(self.laddr.v6 ?? ""),\(self.raddr.v4 ?? ""),\(self.raddr.v6 ?? "")"
        let string = "1,\(self.interface?.BSDName ?? ""),1,\(self.bandwidth.download),\(self.bandwidth.upload),\(addr)$"
        return string.data(using: .utf8)
    }
}

public struct Network_Connectivity: Codable {
    public var status: Bool = false
    var latency: Double = 0
    var jitter: Double = 0
}

public struct Network_Process: Codable, Process_p {
    public var pid: Int
    public var name: String
    public var time: Date
    public var download: Int
    public var upload: Int
    public var icon: NSImage {
        get { ProcessIconCache.shared.icon(for: self.pid) }
    }
    
    public init(pid: Int = 0, name: String = "", time: Date = Date(), download: Int = 0, upload: Int = 0) {
        self.pid = pid
        self.name = name
        self.time = time
        self.download = download
        self.upload = upload
    }
}

public class Network: Module {
    private var popupView: Popup? { self.livePopupView as? Popup }
    private let settingsView: Settings
    private let portalView: Portal
    private let notificationsView: Notifications
    private var previewView: Preview? { self.livePreviewView as? Preview }
    
    private var usageReader: UsageReader? = nil
    private var processReader: ProcessReader? = nil
    private var connectivityReader: ConnectivityReader? = nil
    
    private let ipUpdater = NSBackgroundActivityScheduler(identifier: "eu.exelban.Stats.Network.IP")
    
    private var widgetActivationThresholdState: Bool {
        Store.shared.bool(key: "\(self.config.name)_widgetActivationThresholdState", defaultValue: false)
    }
    private var widgetActivationThreshold: Int {
        Store.shared.int(key: "\(self.config.name)_widgetActivationThreshold", defaultValue: 0)
    }
    private var widgetActivationThresholdSize: SizeUnit {
        SizeUnit.fromString(Store.shared.string(key: "\(self.name)_widgetActivationThresholdSize", defaultValue: SizeUnit.MB.key))
    }
    private var publicIPRefreshInterval: String {
        Store.shared.string(key: "\(self.name)_publicIPRefreshInterval", defaultValue: "never")
    }
    private var textValue: String {
        Store.shared.string(key: "\(self.name)_textWidgetValue", defaultValue: "$addr.public - $status")
    }
    
    private var systemWidgetsUpdatesState: Bool {
        self.userDefaults?.bool(forKey: "systemWidgetsUpdates_state") ?? false
    }
    
    public init() {
        self.settingsView = Settings(.network)
        self.portalView = Portal(.network, height: 90)
        self.notificationsView = Notifications(.network)
        
        super.init(
            moduleType: .network,
            popup: { Popup(.network) },
            settings: self.settingsView,
            portal: self.portalView,
            notifications: self.notificationsView,
            preview: { Preview(.network) }
        )
        guard self.available else { return }
        
        self.usageReader = UsageReader(.network) { [weak self] value in
            self?.usageCallback(value)
        }
        self.popupView?.locationPermissionAction = { [weak self] in
            self?.usageReader?.requestWiFiLocationAuthorization()
        }
        self.processReader = ProcessReader(.network) { [weak self] value in
            if let list = value {
                self?.popupView?.processCallback(list)
                self?.previewView?.processCallback(list)
            }
        }
        self.connectivityReader = ConnectivityReader(.network) { [weak self] value in
            self?.connectivityCallback(value)
        }
        
        self.settingsView.callbackWhenUpdateNumberOfProcesses = { [weak self] in
            guard let self else { return }
            self.popupView?.numberOfProcessesUpdated()
            self.previewView?.numberOfProcessesUpdated()
            DispatchQueue.global(qos: .background).async { [weak self] in
                self?.processReader?.read()
            }
        }
        
        self.settingsView.callback = { [weak self] in
            self?.usageReader?.getDetails()
            self?.usageReader?.read()
        }
        self.settingsView.usageResetCallback = { [weak self] in
            self?.setUsageReset()
        }
        self.settingsView.connectivityHostCallback = { [weak self] isDisabled in
            if isDisabled {
                self?.popupView?.resetConnectivityView()
                self?.connectivityCallback(Network_Connectivity(status: false))
            }
        }
        self.settingsView.setInterval = { [weak self] value in
            self?.connectivityReader?.setInterval(value)
        }
        self.settingsView.publicIPRefreshIntervalCallback = { [weak self] in
            self?.setIPUpdater()
        }
        
        self.setReaders([self.usageReader, self.processReader, self.connectivityReader])
        
        self.setIPUpdater()
        self.setUsageReset()
    }
    
    public override func isAvailable() -> Bool {
        var list: [String] = []
        for interface in SCNetworkInterfaceCopyAll() as NSArray {
            if let displayName = SCNetworkInterfaceGetLocalizedDisplayName(interface as! SCNetworkInterface) {
                list.append(displayName as String)
            }
        }
        return !list.isEmpty
    }
    
    private func usageCallback(_ raw: Network_Usage?) {
        guard let value = raw, self.enabled else { return }
        
        self.popupView?.usageCallback(value)
        self.portalView.usageCallback(value)
        self.notificationsView.usageCallback(value)
        self.previewView?.usageCallback(value)
        
        var upload: Int64 = value.bandwidth.upload
        var download: Int64 = value.bandwidth.download
        if self.widgetActivationThresholdState {
            upload = 0
            download = 0
            let threshold = self.widgetActivationThresholdSize.toBytes(self.widgetActivationThreshold)
            if value.bandwidth.upload >= threshold || value.bandwidth.download >= threshold {
                upload = value.bandwidth.upload
                download = value.bandwidth.download
            }
        }
        
        self.menuBar.widgets.filter{ $0.isActive }.forEach { (w: SWidget) in
            switch w.item {
            case let widget as SpeedWidget: widget.setValue(input: download, output: upload)
            case let widget as NetworkChart: widget.setValue(upload: Double(upload), download: Double(download))
            case let widget as TextWidget:
                var text = self.textValue
                let pairs = TextWidget.parseText(text)
                pairs.forEach { pair in
                    var replacement: String? = nil
                    
                    switch pair.key {
                    case "$addr":
                        switch pair.value {
                        case "public": replacement = value.raddr.v4 ?? value.raddr.v6 ?? "-"
                        case "publicV4": replacement = value.raddr.v4 ?? "-"
                        case "publicV6": replacement = value.raddr.v6 ?? "-"
                        case "private": replacement = value.laddr.v4 ?? value.laddr.v6 ?? "-"
                        case "privateV4": replacement = value.laddr.v4 ?? "-"
                        case "privateV6": replacement = value.laddr.v6 ?? "-"
                        case "countryCode": replacement = value.raddr.countryCode ?? "-"
                        case "flag": replacement = value.raddr.countryCode != nil ? countryFlag(value.raddr.countryCode!) : "-"
                        default: return
                        }
                    case "$interface":
                        switch pair.value {
                        case "displayName": replacement = value.interface?.displayName ?? "-"
                        case "BSDName": replacement = value.interface?.BSDName ?? "-"
                        case "address": replacement = value.interface?.address ?? "-"
                        case "transmitRate": replacement = "\(value.interface?.transmitRate ?? 0)"
                        default: return
                        }
                    case "$wifi":
                        switch pair.value {
                        case "ssid": replacement = value.wifiDetails.ssid ?? "-"
                        case "bssid": replacement = value.wifiDetails.bssid ?? "-"
                        case "RSSI": replacement = "\(value.wifiDetails.RSSI ?? 0)"
                        case "noise": replacement = "\(value.wifiDetails.noise ?? 0)"
                        case "standard": replacement = value.wifiDetails.standard ?? "-"
                        case "mode": replacement = value.wifiDetails.mode ?? "-"
                        case "security": replacement = value.wifiDetails.security ?? "-"
                        case "channel": replacement = value.wifiDetails.channel ?? "-"
                        case "channelBand": replacement = value.wifiDetails.channelBand ?? "-"
                        case "channelWidth": replacement = value.wifiDetails.channelWidth ?? "-"
                        case "channelNumber": replacement = value.wifiDetails.channelNumber ?? "-"
                        default: return
                        }
                    case "$status":
                        replacement = localizedString(value.status ? "UP" : "DOWN")
                    case "$upload":
                        switch pair.value {
                        case "total": replacement = Units(bytes: value.total.upload).getReadableMemory()
                        default: replacement = Units(bytes: value.bandwidth.upload).getReadableMemory()
                        }
                    case "$download":
                        switch pair.value {
                        case "total": replacement = Units(bytes: value.total.download).getReadableMemory()
                        default: replacement = Units(bytes: value.bandwidth.download).getReadableMemory()
                        }
                    case "$type":
                        replacement = value.connectionType?.rawValue ?? "-"
                    case "$icmp":
                        guard let connectivity = self.connectivityReader?.value else { return }
                        switch pair.value {
                        case "status": replacement = localizedString(connectivity.status ? "UP" : "DOWN")
                        case "latency": replacement = "\(Int(connectivity.latency)) ms"
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
            default: break
            }
        }
        
        if self.systemWidgetsUpdatesState {
            SystemWidgetUpdates.shared.update(raw, key: "Network@UsageReader", kinds: [NetWidgetKind], defaults: self.userDefaults)
        }
    }
    
    private func connectivityCallback(_ raw: Network_Connectivity?) {
        guard let value = raw, self.enabled else { return }
        
        self.popupView?.connectivityCallback(value)
        self.notificationsView.connectivityCallback(value)
        self.previewView?.connectivityCallback(value)
        
        self.menuBar.widgets.filter{ $0.isActive }.forEach { (w: SWidget) in
            switch w.item {
            case let widget as DotWidget:
                let value = value.status ? SColor.secondGreen : SColor.secondRed
                widget.setValue(value.additional as? NSColor ?? .systemGray)
            default: break
            }
        }
    }
    
    private func setIPUpdater() {
        self.ipUpdater.invalidate()
        
        switch self.publicIPRefreshInterval {
        case "hour":
            self.ipUpdater.interval = 60 * 60
        case "12":
            self.ipUpdater.interval = 60 * 60 * 12
        case "24":
            self.ipUpdater.interval = 60 * 60 * 24
        default: return
        }
        
        self.ipUpdater.repeats = true
        self.ipUpdater.schedule { (completion: @escaping NSBackgroundActivityScheduler.CompletionHandler) in
            guard self.enabled && self.isAvailable() else { return }
            debug("going to automatically refresh IP address...")
            NotificationCenter.default.post(name: .refreshPublicIP, object: nil, userInfo: nil)
            completion(NSBackgroundActivityScheduler.Result.finished)
        }
    }
    
    private func setUsageReset() {
        if AppUpdateInterval(rawValue: Store.shared.string(key: "\(self.config.name)_usageReset", defaultValue: AppUpdateInterval.never.rawValue)) == .atStart {
            NotificationCenter.default.post(name: .resetTotalNetworkUsage, object: nil, userInfo: nil)
        }
    }
}

// 桌面组件的 kind。此字符串必须与 widget.swift 里 Network_entry.kind 保持一致——
// 那个结构体现在只编进 WidgetsExtension 目标，app 侧链接不到，所以在这里留一份字面量。
internal let NetWidgetKind = "NetworkWidget"
