import SwiftUI
import AppKit

extension Color { init(_ hex: UInt) { self.init(.sRGB, red: Double((hex>>16)&0xff)/255, green: Double((hex>>8)&0xff)/255, blue: Double(hex&0xff)/255, opacity: 1) } }

struct IconView: View {
    var body: some View {
        Canvas { ctx, size in
            let S = size.width / 1024.0
            func s(_ v: CGFloat) -> CGFloat { v * S }
            let full = CGRect(origin: .zero, size: size)
            // clip to the macOS squircle (continuous corners)
            let squircle = Path(roundedRect: full, cornerSize: CGSize(width: s(228), height: s(228)), style: .continuous)
            ctx.clip(to: squircle)
            // background gradient
            ctx.fill(Path(full), with: .linearGradient(
                Gradient(stops: [.init(color: Color(0x1ab9a4), location: 0), .init(color: Color(0x0e8d82), location: 0.5), .init(color: Color(0x0a5d59), location: 1)]),
                startPoint: CGPoint(x: size.width/2, y: 0), endPoint: CGPoint(x: size.width/2, y: size.height)))
            // top sheen
            ctx.fill(Path(full), with: .radialGradient(
                Gradient(stops: [.init(color: .white.opacity(0.22), location: 0), .init(color: .white.opacity(0), location: 0.55)]),
                center: CGPoint(x: size.width/2, y: 0), startRadius: 0, endRadius: size.width))
            // equalizer bars (gold)
            let gold = Gradient(colors: [Color(0xffe491), Color(0xffc24b)])
            let bars: [(CGFloat,CGFloat,CGFloat,Double)] = [(250,724,92,0.70),(316,664,152,0.76),(382,604,212,0.82),(448,564,252,0.88),(514,604,212,0.82),(580,664,152,0.76),(646,724,92,0.70)]
            for (x,y,h,op) in bars {
                ctx.opacity = op
                ctx.fill(Path(roundedRect: CGRect(x: s(x), y: s(y), width: s(44), height: s(h)), cornerSize: CGSize(width: s(22), height: s(22))),
                         with: .linearGradient(gold, startPoint: CGPoint(x: s(x), y: s(y)), endPoint: CGPoint(x: s(x), y: s(y+h))))
            }
            ctx.opacity = 1
            // duck body + head (cream)
            let cream = Gradient(colors: [Color(0xfefcf6), Color(0xece3d0)])
            func ell(_ cx: CGFloat,_ cy: CGFloat,_ rx: CGFloat,_ ry: CGFloat) {
                ctx.fill(Path(ellipseIn: CGRect(x: s(cx-rx), y: s(cy-ry), width: s(rx*2), height: s(ry*2))),
                         with: .linearGradient(cream, startPoint: CGPoint(x: 0, y: s(cy-ry)), endPoint: CGPoint(x: 0, y: s(cy+ry))))
            }
            ell(470,468,252,176)
            ell(620,298,146,146)
            // head sheen
            ctx.opacity = 0.5
            ctx.fill(Path(ellipseIn: CGRect(x: s(600-82), y: s(240-44), width: s(164), height: s(88))), with: .color(.white))
            ctx.opacity = 1
            // bill (gold)
            ctx.fill(Path(roundedRect: CGRect(x: s(688), y: s(298), width: s(166), height: s(88)), cornerSize: CGSize(width: s(44), height: s(44))),
                     with: .linearGradient(Gradient(colors: [Color(0xffd25a), Color(0xf5a623)]), startPoint: CGPoint(x: s(688), y: s(298)), endPoint: CGPoint(x: s(854), y: s(386))))
            // eye
            ctx.fill(Path(ellipseIn: CGRect(x: s(650-21), y: s(276-21), width: s(42), height: s(42))), with: .color(Color(0x0a5d59)))
        }
        .frame(width: 1024, height: 1024)
    }
}

MainActor.assumeIsolated {
    let r = ImageRenderer(content: IconView())
    r.scale = 1.0
    guard let cg = r.cgImage else { print("ERR: no cgImage"); exit(1) }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let data = rep.representation(using: .png, properties: [:]) else { print("ERR: no png"); exit(1) }
    try! data.write(to: URL(fileURLWithPath: "/tmp/icon_master.png"))
    print("wrote /tmp/icon_master.png \(cg.width)x\(cg.height)")
}
