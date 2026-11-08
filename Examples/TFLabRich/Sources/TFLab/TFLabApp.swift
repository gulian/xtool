import SwiftUI

@main
struct TFLabApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Text("TF Lab · catalog")
                    .font(.title.bold())
                HStack(spacing: 16) {
                    tile("a", "red square")
                    tile("HeroBackgroundImageLarge", "green disc")
                    tile("Moon", "yellow / blue in dark")
                    tile("Big", "pink disc, 512 px")
                }
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color("Brand", bundle: .main))
                    .frame(width: 220, height: 44)
                    .overlay(Text("Brand: orange / purple in dark").font(.caption).foregroundStyle(.white))
                Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")
                    .font(.caption.monospaced())
            }
        }
    }

    private func tile(_ name: String, _ expected: String) -> some View {
        VStack {
            Image(name, bundle: .main)
                .resizable()
                .frame(width: 64, height: 64)
                .border(.gray)
            Text(expected).font(.caption2).multilineTextAlignment(.center).frame(width: 90)
        }
    }
}
