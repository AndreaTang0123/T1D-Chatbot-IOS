import Foundation
import Observation
import JoeCore

@MainActor @Observable final class AppState {
    let store: LocalStore
    let health = HealthKitService()
    let calendar = CalendarService()
    let location = LocationService()
    let assistant = AssistantService()
    let speech = SpeechService()
    private let nightscout = NightscoutClient()
    private let forecaster = ForecastService()
    var glucose: [GlucoseSample] = []
    var treatments: [Treatment] = []
    var context: LifestyleContext?
    var calendarSnapshot = CalendarService.Snapshot()
    var forecast: Forecast?
    var forecastStatus = "Waiting for CGM data"
    var syncStatus = "Not synced yet"
    var syncError: String?
    var warnings: [String] = []
    var isRefreshing = false
    var connected = false
    var lastSync: Date?
    var reply = "Hi, I'm Joe. Connect to Nightscout to view measurements and experimental forecasts."
    var assistantMode = "Deterministic on-device explanation"
    var isAnswering = false
    var matchedCount = 0
    var mae30: Double?
    var mae60: Double?
    var latencyMS: Double?
    var exportURL: URL?
    var staleMinutes: Double = {
        let stored = UserDefaults.standard.double(forKey: "staleMinutes")
        return stored > 0 ? min(30, max(5, stored)) : 15
    }() {
        didSet { UserDefaults.standard.set(staleMinutes, forKey: "staleMinutes") }
    }
    init(store: LocalStore) {
        self.store = store
        do { connected = try KeychainStore.load() != nil; try reload() }
        catch { syncError = "Unable to read local data or Keychain" }
        health.onChange = { [weak self] in Task { await self?.refresh() } }; health.observe()
    }
    func reload() throws {
        glucose = try store.glucose(); treatments = try store.treatments(); context = try store.contexts().last
        let rows = try store.forecasts()
        forecast = try rows.first.map { try JSONDecoder().decode(Forecast.self, from: $0.payload) }
        let e30 = rows.compactMap(\.error30); let e60 = rows.compactMap(\.error60)
        matchedCount = e60.count
        mae30 = e30.isEmpty ? nil : e30.map(abs).reduce(0,+)/Double(e30.count)
        mae60 = e60.isEmpty ? nil : e60.map(abs).reduce(0,+)/Double(e60.count)
    }
    func configure(url: String, secret: String, auth: NightscoutCredentials.Auth) async {
        guard !isRefreshing else { return }
        do {
            let credentials = try NightscoutCredentials(url: url, secret: secret, auth: auth)
            let previous = try KeychainStore.load()
            // Do not combine different Nightscout sources in the same research database.
            if let previous, previous.baseURL != credentials.baseURL {
                syncError = "Clear local data before switching to a different Nightscout URL."; return
            }
            try KeychainStore.save(credentials); connected = true; await refresh()
        } catch { syncError = error.localizedDescription }
    }
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true; syncError = nil; warnings = []; defer { isRefreshing = false }
        var now = Date()
        do {
            if let credentials = try KeychainStore.load() {
                // Re-fetch overlap for delayed treatment uploads; bounded 48h startup window.
                let since = max(glucose.last?.timestamp.addingTimeInterval(-6*3600) ?? now.addingTimeInterval(-48*3600), now.addingTimeInterval(-48*3600))
                let result = try await nightscout.sync(credentials, since: since, now: now)
                try Task.checkCancellation()
                try store.ingest(glucose: result.glucose, treatments: result.treatments, profile: result.profile, at: now)
                warnings = result.warnings; syncStatus = "Connected directly to Nightscout"; lastSync = now
                if result.glucose.isEmpty { warnings.append("No valid CGM readings in this response. Showing cached data.") }
            } else { syncStatus = "Connect to Nightscout in Settings" }
        } catch is CancellationError { return }
        catch { syncError = error.localizedDescription; syncStatus = "Connection failed · Cached data" }
        guard !Task.isCancelled else { return }
        now = Date()
        do {
            try reload(); location.refresh()
            let cutoff = glucose.last?.timestamp ?? now
            var collected = await health.snapshot(at: cutoff)
            calendarSnapshot = calendar.snapshot(at: cutoff)
            collected.calendar = calendarSnapshot.current
            collected.place = location.category(at: cutoff)
            context = collected; try store.save(context: collected)
            try store.matchActuals(samples: glucose, now: now)
            try reload()
            forecast = nil
            let row = try FeatureBuilder.build(samples: glucose, treatments: treatments, context: collected, at: now, staleAfter: staleMinutes*60)
            try store.save(feature: row)
            let start = ContinuousClock.now
            let prediction = try forecaster.predict(row: row, at: now)
            let elapsed = start.duration(to: .now).components
            latencyMS = Double(elapsed.attoseconds)/1e15 + Double(elapsed.seconds)*1000
            try store.save(forecast: prediction); forecast = prediction
            forecastStatus = "Experimental · Shadow mode only"
            try reload()
        } catch let issue as DataIssue { forecast = nil; forecastStatus = issue.localizedDescription }
        catch { forecast = nil; forecastStatus = "Local processing failed: " + error.localizedDescription }
    }
    func ask(_ text: String) async {
        guard !isAnswering, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isAnswering = true; defer { isAnswering = false }
        let snapshot = AssistantSnapshot(glucose: glucose.last, forecast: forecast, treatments: treatments,
                                         context: context, now: Date(), staleAfter: staleMinutes*60)
        reply = await assistant.answer(text, snapshot: snapshot); assistantMode = assistant.mode
    }
    func export() {
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Joe-research-export.json")
            try store.exportResearch().write(to: url, options: [.atomic, .completeFileProtection])
            exportURL = url
        } catch { syncError = "Export failed" }
    }
    func erase() {
        guard !isRefreshing, !isAnswering else { return }
        do {
            try KeychainStore.delete(); try store.erase()
            health.disable(); UserDefaults.standard.set(false, forKey: "calendarEnabled"); location.forgetAll(); speech.stop()
            if let exportURL { try? FileManager.default.removeItem(at: exportURL) }; exportURL = nil
            connected = false; glucose = []; treatments = []; context = nil; forecast = nil
            matchedCount = 0; mae30 = nil; mae60 = nil; lastSync = nil; warnings = []; syncError = nil
            syncStatus = "Local data cleared"; forecastStatus = "Waiting for CGM data"; reply = "Local records have been cleared."
        } catch { syncError = "Failed to clear data: " + error.localizedDescription }
    }
}
