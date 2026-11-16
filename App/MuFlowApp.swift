import SwiftUI

@main
struct MuFlowApp: App {
    @State private var model = PlayerModel()
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    if ["xml", "json"].contains(url.pathExtension.lowercased()) { model.importComments(url) }
                    else { model.open(url) }
                }
        }
    }
}
