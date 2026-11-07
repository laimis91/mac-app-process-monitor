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

// MARK: - Disk tab demo results (made up; shown as ~/… so no real user name appears)

extension Demo {
    static func diskCategories() -> [Category] {
        let h = NSHomeDirectory()
        let now = Date()
        func ago(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }
        func item(_ rel: String, _ mb: Double, _ risk: Risk, _ method: Method, age: Double = 12,
                  _ reason: String, running: String? = nil) -> CleanItem {
            var i = CleanItem(path: rel.hasPrefix("tool://") ? rel : h + "/" + rel,
                              name: (rel as NSString).lastPathComponent, size: Int64(mb * 1_048_576),
                              newest: ago(age), risk: risk, method: method, reason: reason, allowRoot: "", fileID: [])
            i.runningOwner = running
            return i
        }
        func tool(_ id: String, _ title: String, _ rel: String, _ mb: Double, _ risk: Risk, _ t: String,
                  _ args: [String], _ why: String) -> Category {
            var i = item(rel, mb, risk, .tool, why)
            i = CleanItem(path: i.path, name: title, size: i.size, newest: i.newest, risk: risk, method: .tool,
                          reason: why, allowRoot: "", fileID: [])
            return Category(id: id, title: title, group: .developer, method: .tool, explanation: why, items: [i],
                            tool: ToolCommand(tool: t, commands: [args], preview: nil, executable: "/opt/homebrew/bin/" + t))
        }
        return [
            Category(id: "J-CACHE", title: "App caches", group: .general, method: .trash,
                     explanation: "Caches apps keep to work faster. Apps re-create them when needed.", items: [
                item("Library/Caches/com.example.photoeditor", 1840, .safe, .trash, "Cache folder of Photo Editor, an app on this Mac. Apps re-create their caches."),
                item("Library/Caches/com.example.musicplayer", 612, .safe, .trash, "Cache folder of Music Player, an app on this Mac. Apps re-create their caches.", running: "Music Player"),
                item("Library/Caches/org.sample.notes", 248, .review, .trash, "Cache folder of org.sample.notes. Its app wasn't found on this Mac, so check it first."),
                item("Library/Caches/GameLauncher", 1310, .review, .trash, "Cache folder “GameLauncher”. Its app can't be identified by name, so check it first."),
            ]),
            Category(id: "J-LOGS", title: "Logs", group: .general, method: .trash, explanation: "Old log files written by apps.", items: [
                item("Library/Logs/com.example.photoeditor", 96, .safe, .trash, age: 41, "Log files, unchanged for 41 days, limit 7."),
                item("Library/Logs/GameLauncher", 38, .safe, .trash, age: 19, "Log files, unchanged for 19 days, limit 7."),
            ]),
            Category(id: "J-TMP", title: "Old temporary files", group: .general, method: .trash,
                     explanation: "Files apps left in your temporary folder.", items: [
                item("tmp-demo/export-4F2A", 420, .review, .trash, age: 9, "Temporary item, unchanged for 9 days, limit 3. Moved only if no app has it open."),
            ]),
            Category(id: "J-MAILDL", title: "Mail attachments", group: .general, method: .trash,
                     explanation: "Copies of attachments you opened from Mail.", items: [], notice: "Needs Full Disk Access"),
            Category(id: "J-TRASH", title: "Trash", group: .general, method: .none,
                     explanation: "Empty the Trash in Finder to free this space.", items: [
                item(".Trash", 2200, .info, .none, "Items already in the Trash. Empty it in Finder to free this space."),
            ]),
            Category(id: "J-XC-DD", title: "Xcode DerivedData", group: .developer, method: .trash, explanation: "Build products and indexes.", items: [
                item("Library/Developer/Xcode/DerivedData/WeatherApp-abcdefgh", 3900, .safe, .trash, "Xcode build data. Xcode rebuilds it on the next build."),
                item("Library/Developer/Xcode/DerivedData/ModuleCache.noindex", 1150, .safe, .trash, "Xcode build data. Xcode rebuilds it on the next build."),
            ]),
            tool("J-NUGET-HTTP", "NuGet download cache", ".local/share/NuGet/http-cache", 2100, .safe, "dotnet",
                 ["nuget", "locals", "http-cache", "--clear"], "Downloaded package files. NuGet downloads them again when needed."),
            tool("J-NUGET-PKG", "NuGet packages", ".nuget/packages", 6400, .review, "dotnet",
                 ["nuget", "locals", "global-packages", "--clear"], "Every project downloads its packages again on next build. Fails if an IDE has projects open."),
            tool("J-NPM", "npm cache", ".npm/_cacache", 1780, .review, "npm", ["cache", "clean", "--force"],
                 "Downloaded npm packages. Installs get slower until it fills again."),
        ]
    }
}

// MARK: - Space map demo (made up; shown as ~/… so no real user name appears)

extension Demo {
    /// A made-up Space map: the root and the home folder node.
    static func spaceMap() -> (SpaceNode, SpaceNode) {
        let now = Date().timeIntervalSince1970
        var ino: UInt64 = 1
        let gb = 1_073_741_824.0
        func node(_ name: String, _ g: Double = 0, days: Double = 3, items: Int = 0, app: (String, String)? = nil,
                  note: String? = nil, package: Bool = false, other: (Int, Double)? = nil, _ kids: [SpaceNode] = []) -> SpaceNode {
            ino += 1
            let n = SpaceNode(name: name, isDir: !kids.isEmpty || items > 0 || other != nil || note != nil, dev: 1, ino: ino)
            n.size = Int64(g * gb)
            n.newest = now - days * 86_400
            n.items = items
            if let (name, path) = app { n.owner = AppInfo(id: "demo." + name, name: name, path: path) }
            n.note = note
            if note != nil { n.flags.insert(.incomplete) }
            if package { n.flags.insert(.package) }
            if let (count, size) = other { n.otherCount = count; n.otherSize = Int64(size * gb); n.size += n.otherSize }
            kids.forEach { n.attach($0) }
            return n
        }
        let library = node("Library", 0.4, items: 12, [
            node("Application Support", 0.2, items: 40, other: (61, 3.1), [
                node("Photo Editor", 6.4, days: 2, items: 8_120, app: ("Photo Editor", "")),
                node("com.example.musicplayer", 4.1, days: 1, items: 2_340, app: ("Music Player", "")),
                node("GameLauncher", 2.7, days: 240, items: 15_400, app: ("Game Launcher", "")),
            ]),
            node("Developer", 0.1, items: 4, [
                node("Xcode", 16.2, days: 1, items: 220_000),
                node("CoreSimulator", 11.8, days: 6, items: 380_000),
            ]),
            node("Caches", 5.2, days: 0, items: 41_000),
            node("Containers", note: "Needs Full Disk Access"),
            node("Mail", 1.8, days: 0, items: 96_000),
        ])
        let home = node("Home folder", 0.01, items: 30, [
            library,
            node("Projects", 0.05, items: 6, [
                node("ml-playground", 0.1, items: 3, [
                    node("datasets", 18.6, days: 412, items: 1_204),
                    node("checkpoints", 7.9, days: 196, items: 88),
                    node("src", 0.02, days: 1, items: 310),
                ]),
                node("weather-api", 1.4, days: 2, items: 52_000),
                node("portfolio-site", 0.9, days: 14, items: 61_000),
            ]),
            node("Movies", 0.01, items: 3, [
                node("Holiday 2023.fcpbundle", 42.0, days: 590, items: 2_300, package: true),
                node("Screen recordings", 3.6, days: 40, items: 64),
            ]),
            node("Downloads", 0.01, items: 140, other: (131, 1.2), [
                node("Game Installer 3.2.dmg", 7.3, days: 380),
                node("ubuntu-24.04-desktop-arm64.iso", 2.9, days: 221),
                node("Course videos", 4.4, days: 30, items: 48),
            ]),
            node("Pictures", 0.01, items: 4, [
                node("Photos Library.photoslibrary", 38.5, days: 0, items: 54_000, package: true),
            ]),
            node("Documents", 6.2, days: 1, items: 9_800),
            node("Music", 3.1, days: 60, items: 2_200),
            node(".docker", 12.4, days: 9, items: 3_100),
        ])
        home.base = NSHomeDirectory()
        home.flags.insert(.shell)
        let apps = node("Applications", 0, items: 0, [
            node("Photo Editor.app", 3.2, days: 20, items: 9_000, app: ("Photo Editor", "")),
            node("Game Launcher.app", 1.1, days: 300, items: 2_100, app: ("Game Launcher", "")),
            node("Code Editor.app", 0.9, days: 5, items: 6_400, app: ("Code Editor", "")),
            node("Music Player.app", 0.4, days: 12, items: 1_300, app: ("Music Player", "")),
        ])
        apps.base = "/Applications"
        apps.flags.insert(.shell)
        let root = SpaceNode.root()
        root.attach(home)
        root.attach(apps)
        return (root, home)
    }
}

// MARK: - Leftovers demo (made up)

extension Demo {
    static func leftoverCategories() -> [Category] {
        let h = NSHomeDirectory()
        let now = Date()
        func item(_ rel: String, _ mb: Double, age: Double, limit: Int = 30, _ reason: String) -> CleanItem {
            CleanItem(path: h + "/" + rel, name: (rel as NSString).lastPathComponent, size: Int64(mb * 1_048_576),
                      newest: now.addingTimeInterval(-age * 86_400), risk: .review, method: .trash, reason: reason,
                      allowRoot: "", fileID: [], ageLimitDays: limit)
        }
        func gone(_ noun: String, _ app: String, _ id: String, _ d: Int) -> String {
            "\(noun) of \(app) (\(id)), an app not found on this Mac, unchanged for \(d) days, limit 30."
        }
        return [
            Category(id: "L:com.example.videostudio", title: "Video Studio", group: .leftovers, method: .trash,
                     explanation: "com.example.videostudio · not found on this Mac", items: [
                item("Library/Application Support/com.example.videostudio", 2860, age: 212, gone("App data", "Video Studio", "com.example.videostudio", 212)),
                item("Library/Caches/com.example.videostudio", 940, age: 212, gone("Cache", "Video Studio", "com.example.videostudio", 212)),
                item("Library/Preferences/com.example.videostudio.plist", 0.02, age: 214, gone("Settings file", "Video Studio", "com.example.videostudio", 214)),
                item("Library/HTTPStorages/com.example.videostudio", 0.4, age: 212, gone("Web storage", "Video Studio", "com.example.videostudio", 212)),
            ]),
            Category(id: "L:org.sample.mapviewer", title: "org.sample.mapviewer", group: .leftovers, method: .trash,
                     explanation: "org.sample.mapviewer · not found on this Mac", items: [
                item("Library/Caches/org.sample.mapviewer", 315, age: 96, gone("Cache", "org.sample.mapviewer", "org.sample.mapviewer", 96).replacingOccurrences(of: "org.sample.mapviewer (org.sample.mapviewer)", with: "org.sample.mapviewer")),
                item("Library/Logs/org.sample.mapviewer", 12, age: 96, gone("Logs", "org.sample.mapviewer", "org.sample.mapviewer", 96).replacingOccurrences(of: "org.sample.mapviewer (org.sample.mapviewer)", with: "org.sample.mapviewer")),
            ]),
            Category(id: "L:com.example.oldsync", title: "com.example.oldsync", group: .possible, method: .trash,
                     explanation: "com.example.oldsync · same vendor as an installed app", items: [
                item("Library/Application Support/com.example.oldsync", 128, age: 402, limit: 90, "App data of com.example.oldsync, an app not found on this Mac, unchanged for 402 days, limit 90. Another app from com.example is on this Mac and may use it, so check it first."),
            ]),
            Category(id: Leftovers.fdaID, title: "App containers and shared app data", group: .leftovers, method: .none,
                     explanation: "Leftovers in Library/Containers, Library/Group Containers are checked only with Full Disk Access.",
                     items: [], notice: "Needs Full Disk Access"),
        ]
    }
}
