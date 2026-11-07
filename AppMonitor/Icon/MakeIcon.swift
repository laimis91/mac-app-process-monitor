// Draws the app icon and writes AppIcon.icns.
// Usage: swift Icon/MakeIcon.swift <output-dir>   (build.sh runs it when the icon is missing)

import SwiftUI
import AppKit

func hex(_ v: UInt32, _ o: Double = 1) -> Color {
    Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: o)
}

let purple = hex(0x8B6CFF), cyan = hex(0x22D3EE), green = hex(0x3FB950)

struct IconView: View {
    var body: some View {
        ZStack {
            // Body on Apple's 1024 grid: 824 pt square with a soft shadow.
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [hex(0x1C2235), hex(0x0B0D13)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom), lineWidth: 4))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.45), radius: 24, y: 14)

            // Gauge track and arc.
            Circle().stroke(Color.white.opacity(0.07), lineWidth: 64).frame(width: 540, height: 540)
            Circle()
                .trim(from: 0, to: 0.74)
                .stroke(AngularGradient(colors: [purple, cyan], center: .center, startAngle: .degrees(0), endAngle: .degrees(266)),
                        style: StrokeStyle(lineWidth: 64, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 540, height: 540)
                .shadow(color: cyan.opacity(0.55), radius: 28)

            // Pulse line across the middle.
            Path { p in
                let pts: [CGPoint] = [(-190, 0), (-90, 0), (-55, -40), (-20, 110), (25, -150), (65, 40), (95, 0), (190, 0)]
                    .map { CGPoint(x: 512 + $0.0, y: 512 + $0.1) }
                p.addLines(pts)
            }
            .stroke(green, style: StrokeStyle(lineWidth: 30, lineCap: .round, lineJoin: .round))
            .shadow(color: green.opacity(0.8), radius: 18)
            .frame(width: 1024, height: 1024)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor func run() throws {
    let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
    let r = ImageRenderer(content: IconView())
    r.scale = 1
    guard let cg = r.cgImage else { fatalError("render failed") }
    let rep = NSBitmapImageRep(cgImage: cg)
    let master = rep.representation(using: .png, properties: [:])!

    let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
    try? FileManager.default.removeItem(at: set)
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    let src = set.appendingPathComponent("master.png")
    try master.write(to: src)
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = size * scale
            let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
            p.arguments = ["-z", "\(px)", "\(px)", src.path, "--out", set.appendingPathComponent(name).path]
            p.standardOutput = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
        }
    }
    try FileManager.default.removeItem(at: src)
    try master.write(to: out.appendingPathComponent("AppIcon.png"))
    let ic = Process()
    ic.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    ic.arguments = ["-c", "icns", set.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
    try ic.run(); ic.waitUntilExit()
    try? FileManager.default.removeItem(at: set)
    print("Wrote \(out.path)/AppIcon.icns")
}

try MainActor.assumeIsolated { try run() }
