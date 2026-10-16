import SwiftUI
@main
struct PreviewApp: App {
    var body: some Scene { WindowGroup { PreviewScreen() } }
}
struct PreviewScreen: View {
    @State private var index = 0
    @State private var vertical = false
    @State private var zoomed = false
    @State private var images: [UIImage] = (0..<3).map { i in
        UIGraphicsImageRenderer(size: CGSize(width: 360, height: 640)).image { c in
            [UIColor.systemTeal, UIColor.systemOrange, UIColor.systemIndigo][i].setFill()
            c.fill(CGRect(x: 0,y: 0,width: 360,height: 640))
            let text = "PAGE \(i + 1)"
            text.draw(at: CGPoint(x: 85,y: 290), withAttributes: [.font:UIFont.boldSystemFont(ofSize: 44), .foregroundColor:UIColor.white])
        }
    }
    var body: some View {
        ZStack {
            NativeMediaPager(count: 3, selection: $index, vertical: vertical, enabled: !zoomed) { position, active in
                PhoneZoomableImage(image: images[position], onTap: {}, onZoomChanged: { if active { zoomed = $0 } })
            }.id(vertical).ignoresSafeArea()
            VStack {
                Picker("Direction", selection: $vertical) { Text("Horizontal").tag(false); Text("Vertical").tag(true) }.pickerStyle(.segmented)
                Text("Selected \(index + 1) / 3").font(.headline).padding(8).background(.regularMaterial,in:Capsule())
                Text(zoomed ? "Zoomed" : "Fit").font(.caption).padding(6).background(.regularMaterial,in:Capsule())
                Spacer()
            }.padding()
        }.onChange(of: index) { _, _ in zoomed = false }
    }
}
