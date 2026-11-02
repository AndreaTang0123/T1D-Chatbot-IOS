import SwiftUI
import BackgroundTasks

@main struct JoeMobileApp: App {
    @Environment(\.scenePhase) private var phase
    @State private var state: AppState?
    @State private var startupError: String?
    var body: some Scene {
        WindowGroup {
            Group {
                if let state { RootView(state: state) }
                else if let startupError { ContentUnavailableView("无法打开本地数据库", systemImage: "externaldrive.badge.exclamationmark", description: Text(startupError)) }
                else { ProgressView("正在打开 Joe…") }
            }
            .task {
                guard state == nil, startupError == nil else { return }
                do { state = AppState(store: try LocalStore()); await state?.refresh(); scheduleRefresh() }
                catch { startupError = error.localizedDescription }
            }
        }
        .onChange(of: phase) { _, phase in
            if phase == .active { Task { await state?.refresh() } }
            if phase == .background { state?.speech.stop(); scheduleRefresh() }
        }
        .backgroundTask(.appRefresh("org.joe.mobile.refresh")) { await refreshInBackground() }
    }
    @MainActor private func refreshInBackground() async {
        if state == nil {
            do { state = AppState(store: try LocalStore()) }
            catch { return }
        }
        await state?.refresh()
        scheduleRefresh()
    }
    private func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "org.joe.mobile.refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15*60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
