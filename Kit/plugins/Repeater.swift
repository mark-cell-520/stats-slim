//
//  Repeater.swift
//  Kit
//
//  Created by Serhiy Mytrovtsiy on 27/06/2022.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2022 Serhiy Mytrovtsiy. All rights reserved.
//

import Foundation

private enum RepeaterState {
    case paused
    case running
}

internal class Repeater {
    private var callback: (() -> Void)
    private var state: RepeaterState = .paused
    private let aligned: Bool

    private var timer: DispatchSourceTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "eu.exelban.Stats.Repeater", qos: .default))

    internal init(seconds: Int, aligned: Bool = false, callback: @escaping (() -> Void)) {
        self.aligned = aligned
        self.callback = callback
        self.setupTimer(seconds)
    }

    deinit {
        self.timer.setEventHandler {}
        self.timer.cancel()
        if self.state == .paused {
            self.timer.resume()
            self.state = .running
        }
    }

    private func setupTimer(_ interval: Int) {
        // 所有 reader 的 Repeater 都在启动后几毫秒内相继建立，deadline 又都是
        // now + interval，于是相位长期一致：同一个瞬间、同一批 reader 一起冲 IOKit / SMC /
        // sysctl / fork。休眠唤醒后 repeating 定时器全部变成「已过期」，约 12 个常驻 reader
        // 会在 200 毫秒的 leeway 里同时补跑，每次唤醒都是一次小型惊群。
        // 给首次触发加一个 [0, interval) 的随机偏移，稳态周期不变，只把起点摊开。
        // 需要严格对齐秒边界的调用方（Reader.alignToSecondBoundary）不抖，它自己算延迟。
        let jitter = self.aligned ? 0 : Double.random(in: 0..<Double(max(interval, 1)))
        self.timer.schedule(
            deadline: DispatchTime.now() + Double(interval) + jitter,
            repeating: .seconds(interval),
            leeway: .milliseconds(200)
        )
        self.timer.setEventHandler { [weak self] in
            self?.callback()
        }
    }
    
    internal func start() {
        guard self.state == .paused else { return }
        
        self.timer.resume()
        self.state = .running
    }
    
    internal func pause() {
        guard self.state == .running else { return }
        
        self.timer.suspend()
        self.state = .paused
    }
    
    internal func reset(seconds: Int, restart: Bool = false) {
        if self.state == .running {
            self.pause()
        }
        
        self.setupTimer(seconds)
        
        if restart {
            self.callback()
            self.start()
        }
    }
}
