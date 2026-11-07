// Demo mode: made-up processes for screenshots, so no real process names, folders or
// numbers from your Mac appear in them.
//
//   open -n "App Monitor.app" --env APPMON_DEMO=1                      # demo window
//   open -n "App Monitor.app" --env APPMON_DEMO=1 --env APPMON_CAPTURE=/tmp/shot.png
//                                                                       # save a screenshot and quit

import SwiftUI
import AppKit

let demoMode = ProcessInfo.processInfo.environment["APPMON_DEMO"] != nil
let captureTo = ProcessInfo.processInfo.environment["APPMON_CAPTURE"]

enum Demo {
    static let expanded: Set<String> = ["g:terminal", "d:zsh-api", "d:dotnet-watch", "d:zsh-ml"]

    private static let terminal = "/System/Applications/Utilities/Terminal.app"
    private static let safari = "/Applications/Safari.app"

    static func sample(tick: Int) -> ([Node], MemInfo, GPUSample) {
        // Small wobble so the demo looks alive.
        func w(_ base: Double, _ amp: Double, _ phase: Double) -> Double {
            max(0, base + amp * sin(Double(tick) * 0.7 + phase))
        }
        func p(_ id: String, _ title: String, _ sub: String? = nil, icon: String? = nil,
               cpu: Double, gpu: Double = 0, mb: Double, _ kids: [Node] = []) -> Node {
            let n = Node(id: "d:" + id, title: title, subtitle: sub.map { "in " + $0 }, tooltip: title,
                         iconPath: icon, isGroup: false, ownCPU: cpu, ownRSS: Int(mb * 1024))
            n.ownGPU = gpu
            n.kids = kids
            return n
        }
        func g(_ id: String, _ title: String, icon: String?, cpu: Double, gpu: Double = 0, mb: Double,
               _ kids: [Node] = []) -> Node {
            let n = Node(id: "g:" + id, title: title, subtitle: nil, tooltip: title, iconPath: icon,
                         isGroup: true, ownCPU: cpu, ownRSS: Int(mb * 1024))
            n.ownGPU = gpu
            n.extraCount = 1
            n.kids = kids
            return n.sum()
        }

        let groups: [Node] = [
            g("terminal", "Terminal", icon: terminal, cpu: w(1.2, 0.4, 0), mb: 180, [
                p("zsh-api", "zsh", "~/Projects/WeatherApi", cpu: 0, mb: 6, [
                    p("dotnet-watch", "dotnet  watch run", cpu: w(3, 1, 1), mb: 210, [
                        p("api", "dotnet  bin/Debug/net9.0/WeatherApi.dll", cpu: w(62, 15, 2), mb: 340),
                        p("msbuild", "dotnet  MSBuild.dll /nodemode:1", cpu: w(18, 8, 3), mb: 420),
                    ]),
                ]),
                p("zsh-web", "zsh", "~/Projects/portfolio-site", cpu: 0, mb: 6, [
                    p("npm", "node  npm run dev", cpu: 0.4, mb: 70, [
                        p("vite", "node  vite --port 5173", cpu: w(9, 4, 4), mb: 160),
                    ]),
                ]),
                p("zsh-ml", "zsh", "~/Projects/ml-playground", cpu: 0, mb: 6, [
                    p("train", "python3  train.py --epochs 20", cpu: w(240, 30, 5), gpu: w(38, 6, 1), mb: 2900),
                ]),
            ]),
            g("windowserver", "WindowServer", icon: nil, cpu: w(24, 6, 2), gpu: w(14, 4, 3), mb: 180),
            g("safari", "Safari", icon: safari, cpu: w(3, 1, 4), mb: 310, [
                p("wc1", "Safari Web Content", icon: safari, cpu: w(12, 5, 1), mb: 640),
                p("gfx", "Safari Graphics and Media", icon: safari, cpu: w(6, 2, 2), gpu: w(9, 3, 4), mb: 120),
                p("wc2", "Safari Web Content", icon: safari, cpu: w(4, 2, 3), mb: 380),
                p("wc3", "Safari Web Content", icon: safari, cpu: 1, mb: 210),
            ]),
            g("kernel", "kernel_task", icon: nil, cpu: w(9, 2, 5), mb: 30),
            g("mds", "mds_stores", icon: nil, cpu: w(6, 4, 0), mb: 90),
            g("photos", "Photos", icon: "/System/Applications/Photos.app", cpu: w(4, 1, 1), gpu: 2, mb: 520),
            g("music", "Music", icon: "/System/Applications/Music.app", cpu: w(3, 1, 3), gpu: 1, mb: 240),
            g("finder", "Finder", icon: "/System/Library/CoreServices/Finder.app", cpu: 1.1, mb: 210),
            g("mail", "Mail", icon: "/System/Applications/Mail.app", cpu: 0.8, mb: 290),
            g("notes", "Notes", icon: "/System/Applications/Notes.app", cpu: 0.4, mb: 140),
            g("maps", "Maps", icon: "/System/Applications/Maps.app", cpu: 0.2, mb: 160),
        ]

        let gb = 1_073_741_824.0
        var m = MemInfo()
        m.total = 36 * gb
        m.app = 15.8 * gb; m.wired = 3.4 * gb; m.compressed = 2.1 * gb; m.cached = 9.6 * gb
        m.free = m.total - m.app - m.wired - m.compressed - m.cached
        m.pressure = 1

        var gpu = GPUSample()
        gpu.name = "Apple GPU"
        gpu.memoryUsed = 2.3 * gb
        gpu.utilization = min(100, groups.reduce(0) { $0 + $1.gpu } + 3)
        return (groups, m, gpu)
    }

    static func history(_ n: Int) -> ([Double], [Double], [Double]) {
        func wave(_ base: Double, _ a1: Double, _ p1: Double, _ a2: Double, _ p2: Double) -> [Double] {
            (0..<n).map { (i: Int) -> Double in
                let x = Double(i)
                return base + a1 * sin(x / p1) + a2 * sin(x / p2)
            }
        }
        let cpu = wave(26, 7, 6, 3, 1.7)
        let gpu = wave(60, 10, 5, 4, 1.3)
        let mem = wave(58, 1.5, 12, 0, 1)
        return (cpu, gpu, mem)
    }
}

/// Saves the app's own window (title bar included) to a PNG, then quits. Draws only this
/// app's views, so it needs no screen-recording permission.
@MainActor func captureWindow(to path: String) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        guard let w = NSApp.windows.first(where: { $0.isVisible }),
              let frameView = w.contentView?.superview else { exit(1) }
        let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)!
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        exit(0)
    }
}
