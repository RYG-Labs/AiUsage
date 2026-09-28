// Renders the 1024px app icon (concentric usage rings) to the given PNG path.
// swiftc -parse-as-library make_icon.swift -o /tmp/make_icon && /tmp/make_icon icon_1024.png
import SwiftUI
import AppKit

let orange = Color(red: 0.851, green: 0.467, blue: 0.341)
let green = Color(red: 0.20, green: 0.78, blue: 0.35)

struct Ring: View {
    var value: Double, color: Color, size: CGFloat
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.13), lineWidth: 58)
            Circle().trim(from: 0, to: value)
                .stroke(color, style: StrokeStyle(lineWidth: 58, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}

struct Icon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.04)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 4))
            Ring(value: 0.72, color: orange, size: 560)
            Ring(value: 0.45, color: .white.opacity(0.92), size: 400)
            Ring(value: 0.30, color: green, size: 240)
        }
        .frame(width: 824, height: 824)                       // macOS icon grid
        .shadow(color: .black.opacity(0.35), radius: 20, y: 12)
        .frame(width: 1024, height: 1024)
    }
}

@main struct MakeIcon {
    @MainActor static func main() {
        let r = ImageRenderer(content: Icon())
        r.scale = 1
        let rep = NSBitmapImageRep(cgImage: r.cgImage!)
        try! rep.representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
