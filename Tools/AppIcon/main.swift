import SwiftUI
import AppKit

// macOS app-icon generator for Proxy Manager.
//
// Renders the Proxy Manager mark as a Big Sur+ app icon: an 824×824 continuous
// ("squircle") rounded rectangle centered on a 1024×1024 transparent canvas,
// with a subtle vertical gradient, a top rim highlight, and a soft drop shadow.
// The transparent margin is intentional — the system derives the Dock/Finder
// shadow from the alpha channel.
//
// Emits a single 1024×1024 PNG; Tools/AppIcon/make.sh downsamples it with
// `sips` into the .iconset and packs the .icns. (Rendering each size directly
// via ImageRenderer.scale mis-renders very small sizes, so we don't.)
//
// Usage: appicon-gen <output-1024.png>

private let canvas: CGFloat = 1024
private let side: CGFloat = 824
private let corner: CGFloat = 185.4

private func rgb(_ hex: UInt32) -> Color {
    Color(.sRGB,
          red: Double((hex >> 16) & 0xFF) / 255.0,
          green: Double((hex >> 8) & 0xFF) / 255.0,
          blue: Double(hex & 0xFF) / 255.0)
}

/// The routing mark: one source node branching to two destinations.
private struct Glyph: View {
    var body: some View {
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: 11.6, y: 14.4))
                path.addLine(to: CGPoint(x: 20.0, y: 9.4))
                path.move(to: CGPoint(x: 11.6, y: 17.6))
                path.addLine(to: CGPoint(x: 20.0, y: 22.6))
            }
            .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            Circle().frame(width: 6.0, height: 6.0).position(x: 9, y: 16)
            Circle().frame(width: 5.2, height: 5.2).position(x: 23, y: 9)
            Circle().frame(width: 5.2, height: 5.2).position(x: 23, y: 23)
        }
        .foregroundStyle(.white)
        .frame(width: 32, height: 32)
    }
}

private struct IconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(LinearGradient(colors: [rgb(0x36C77D), rgb(0x0E7C45)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [Color.white.opacity(0.40),
                                                    Color.white.opacity(0.02)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 2.5
                        )
                )
                .frame(width: side, height: side)
                .shadow(color: .black.opacity(0.16), radius: 11, x: 0, y: 6)
            Glyph().scaleEffect(18.9)
        }
        .frame(width: canvas, height: canvas)
    }
}

func run() {
    MainActor.assumeIsolated {
        let renderer = ImageRenderer(content: IconView())
        renderer.scale = 1
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write("render failed\n".data(using: .utf8)!)
            exit(1)
        }
        let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
        try! png.write(to: URL(fileURLWithPath: out))
        print("Wrote \(out) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
    }
}

run()
