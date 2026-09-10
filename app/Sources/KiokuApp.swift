import SwiftUI

@main
struct KiokuApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.ink)
                .onOpenURL { url in
                    Task { await model.importPackage(from: url) }
                }
                .task { await model.start() }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.state {
        case .loading:
            VStack(spacing: 16) {
                ProgressView()
                Text("コレクションを開いています…").font(.footnote).foregroundStyle(Theme.gray1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.paper)
        case .failed(let message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(Theme.gray1)
                Text("起動に失敗しました").font(.headline)
                Text(message).font(.footnote).foregroundStyle(Theme.gray1).multilineTextAlignment(.center).padding(.horizontal)
                Button("再試行") { Task { await model.start() } }.buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.paper)
        case .ready:
            DeckListView()
        }
    }
}
