import SwiftUI

@main
struct TFLabApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Image(systemName: "airplane.departure")
                    .font(.system(size: 64))
                Text("TF Lab")
                    .font(.largeTitle.bold())
                Text("Built on Linux with xtool")
                    .foregroundStyle(.secondary)
                Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")
                    .font(.caption.monospaced())
            }
        }
    }
}
