import AppKit
import SwiftUI

/// Monty as still images: the menu bar icon and the app icon.
enum MontyIcons {
    /// Monty's face for the menu bar, in the given mood.
    static func menuBar(_ mood: MontyMood) -> NSImage? {
        // Mid-motion times, so each mood shows its pose (mouth open, cheese up, ...).
        let level: CGFloat = mood == .listening ? 0.6 : 0
        return render(MontyView(mood: mood, size: 20, time: 0.15, level: level), scale: 2)
    }

    /// The app icon artwork: Monty on a dark rounded square, like the notch he lives in.
    struct AppIcon: View {
        var size: CGFloat
        var body: some View {
            // macOS icon grid: an 824-point body on a 1024-point canvas.
            let body = size * 824 / 1024
            ZStack {
                RoundedRectangle(cornerRadius: body * 0.2237, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.2, green: 0.19, blue: 0.24), Color(red: 0.05, green: 0.05, blue: 0.07)],
                        startPoint: .top, endPoint: .bottom))
                    .frame(width: body, height: body)
                    .shadow(color: .black.opacity(0.3), radius: size * 0.02, y: size * 0.01)
                MontyView(mood: .awake, size: body * 0.78)
                    .offset(y: body * 0.03)
            }
            .frame(width: size, height: size)
        }
    }

    /// Writes an .iconset folder (all macOS icon sizes) for iconutil.
    static func writeIconset(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for factor in [1, 2] {
                let pixels = CGFloat(points * factor)
                guard let image = render(AppIcon(size: pixels), scale: 1),
                      let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                else { continue }
                let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                try png.write(to: folder.appendingPathComponent(name))
            }
        }
    }

    static func render<V: View>(_ view: V, scale: CGFloat) -> NSImage? {
        MainActor.assumeIsolated {
            let renderer = ImageRenderer(content: view)
            renderer.scale = scale
            return renderer.nsImage
        }
    }
}
