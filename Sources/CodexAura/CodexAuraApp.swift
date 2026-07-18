import SwiftUI

@main
enum CodexAuraEntry {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--cli" {
            let code = await CLI.run(Array(args.dropFirst()))
            exit(code)
        }
        CodexAuraApp.main()
    }
}

struct CodexAuraApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("CodexAura", systemImage: "paintpalette.fill") {
            MenuContentView()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}
