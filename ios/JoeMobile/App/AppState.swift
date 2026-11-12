import Foundation
import Observation
import JoeCore

struct ChatMessage: Identifiable {
    enum Role { case user, joe }
    let id = UUID()
    let role: Role
    let text: String
    let timestamp: Date
    init(role: Role, text: String, timestamp: Date = Date(), mode: String? = nil, diagnostics: [String] = []) {
        self.role = role; self.text = text; self.timestamp = timestamp; self.mode = mode; self.diagnostics = diagnostics
    }
    let diagnostics: [String]
    var mode: String? = nil
}

@MainActor @Observable final class AppState {
    let store: LocalStore
    let health = HealthKitService()
    let calendar = CalendarService()
    let location = LocationService()
    let assistant = AssistantService()
    private let coordinator: AssistantCoordinator
    let speech = SpeechService()
    let voiceInput = SpeechInputService()
    private let nightscout = NightscoutClient()
    private let forecaster = ForecastService()
    var healthGlucoseHistory: [GlucoseSample] = []
    var healthHistoryStatus = "Historical glucose uses available Nightscout and authorized Apple Health records."
    var historyDays = 14
    var historySamples: [GlucoseSample] {
        healthGlucoseHistory + glucose.map { g in GlucoseSample(id: g.id, timestamp: g.timestamp, glucose: g.glucose, direction: g.direction,
            receivedAt: g.receivedAt, sourceName: g.sourceName ?? "Nightscout") }
    }
    var historySummary: GlucoseHistorySummary? { GlucoseHistorySummary(samples: historySamples, days: historyDays, now: Date()) }
    var glucose: [GlucoseSample] = []
    var treatments: [Treatment] = []
    var context: LifestyleContext?
    var currentContext: LifestyleContext?
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
    var messages: [ChatMessage] = [ChatMessage(role: .joe, text: "Hi, I'm Joe. Ask about your glucose, forecasts, or lifestyle context. You can type or hold the microphone to talk. Connect your data sources in Settings.")]
    var assistantMode = "Deterministic on-device explanation"
    var isAnswering = false
    var isRunningPersonaRegression = false
    @ObservationIgnored private var regressionTask: Task<Void, Never>?
    var regressionStatus: String?
    var autoSpeak = (UserDefaults.standard.object(forKey: "autoSpeak") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autoSpeak, forKey: "autoSpeak") }
    }
    var speechLocale = UserDefaults.standard.string(forKey: "speechLocale") ?? "en-US" {
        didSet { UserDefaults.standard.set(speechLocale, forKey: "speechLocale") }
    }
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
        self.coordinator = AssistantCoordinator(provider: assistant)
        KeychainStore.removeLegacyConversationCredential()
        do { connected = try KeychainStore.load() != nil; try reload() }
        catch { syncError = "Unable to read local data or Keychain" }
        do {
            let recent = try store.assistantTurns(includeRegression: false).suffix(3)
            if !recent.isEmpty {
                messages = recent.flatMap { turn in [ChatMessage(role: .user, text: turn.question, timestamp: turn.timestamp),
                    ChatMessage(role: .joe, text: turn.response, timestamp: turn.timestamp, mode: turn.mode, diagnostics: turn.fallbackDetails)] }
            }
        } catch { warnings.append("Conversation history could not be restored.") }
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
        await refreshHealthHistory()
        var now = Date()
        do {
            if let credentials = try KeychainStore.load() {
                // Re-fetch overlap for delayed treatment uploads; bounded 72h startup window.
                let since = max(glucose.last?.timestamp.addingTimeInterval(-6*3600) ?? now.addingTimeInterval(-72*3600), now.addingTimeInterval(-72*3600))
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
            calendarSnapshot = calendar.snapshot(at: now)
            var live = await health.snapshot(at: now)
            live.calendar = calendarSnapshot.current
            live.place = location.category(at: now)
            currentContext = live
            collected.calendar = calendar.snapshot(at: cutoff).current
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
    func refreshHealthHistory() async {
        do {
            let records = try await health.glucoseHistory(at: Date())
            guard health.enabled else { healthGlucoseHistory = []; healthHistoryStatus = "Apple Health collection is off. Cached Nightscout history remains available."; return }
            guard !Task.isCancelled else { return }
            healthGlucoseHistory = records
            healthHistoryStatus = records.isEmpty ? "No visible blood glucose records. Check Dexcom sharing and Joe's read access; iOS does not reveal read denial." : "Apple Health history refreshed. Not a real-time glucose source."
        } catch {
            healthGlucoseHistory = []
            healthHistoryStatus = "Unable to read Apple Health glucose. Unlock iPhone and retry; check Health permissions."
        }
    }
    func refreshThreeDayHistory() async {
        let now = Date()
        do {
            if let credentials = try KeychainStore.load() {
                let records = try await nightscout.glucoseHistory(credentials, since: now.addingTimeInterval(-72*3600), now: now)
                try Task.checkCancellation()
                try store.ingest(glucose: records, treatments: [], profile: nil, at: now)
                glucose = try store.glucose()
                healthHistoryStatus = "Three-day history refreshed. Sources and coverage are reported; gaps remain missing."
            } else { healthHistoryStatus = "Using visible Apple Health and cached Nightscout history; no live Nightscout connection is configured." }
        } catch is CancellationError { return }
        catch {
            healthHistoryStatus = "Three-day Nightscout refresh failed. Using available cached/Apple Health records; coverage may be incomplete."
            warnings.append(healthHistoryStatus)
        }
    }
    func assistantSnapshot(at now: Date, historyWindow: Int? = nil) -> AssistantSnapshot {
        AssistantSnapshot(glucose: glucose.last, forecast: forecast, treatments: treatments,
            context: currentContext ?? context, now: now, policy: SafetyPolicy(cgmStaleSeconds: staleMinutes*60),
            nextEventCategory: calendarSnapshot.next, nextEventStart: calendarSnapshot.nextStart,
            currentEventEnd: calendarSnapshot.currentEnd, glucoseHistory: GlucoseHistorySummary(samples: historySamples, days: historyWindow ?? historyDays, now: now),
            contextAccess: ["calendar": !calendar.enabled ? "collection_disabled" : calendar.hasAccess ? "authorized" : "not_authorized",
                            "location": !location.collectionEnabled ? "collection_disabled" : location.hasAccess ? "authorized" : "not_authorized"], calendarDay: calendarDay)
    }
    func safetyDecision(at now: Date) -> SafetyDecision {
        let snapshot = assistantSnapshot(at: now)
        return SafetyDecisionEngine(policy: snapshot.policy).evaluate(cgm: snapshot.currentGlucose, forecast: snapshot.forecastResult)
    }
    private var calendarDay: CalendarDayResult?
    var isInBackground = false
    func ask(_ text: String) async {
        guard !isAnswering, !isRunningPersonaRegression, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        messages.append(ChatMessage(role: .user, text: question))
        isAnswering = true; defer { isAnswering = false }
        let intent = QuestionIntent(question)
        calendarDay = intent.calendar && !intent.sharingExperience ? calendar.daySchedule(at: Date(), question: question) : nil
        if intent.history {
            await refreshHealthHistory()
            if GlucoseHistorySummary.requestedDays(question, defaultDays: historyDays) == 3 { await refreshThreeDayHistory() }
        }
        if intent.context && !intent.sharingExperience {
            // Refresh local permission-gated sources independently of Nightscout synchronization.
            location.refresh()
            let now = Date()
            calendarSnapshot = calendar.snapshot(at: now)
            var live = await health.snapshot(at: now)
            live.calendar = calendarSnapshot.current
            live.place = location.category(at: Date())
            currentContext = live
        }
        let preflight = assistantSnapshot(at: Date(), historyWindow: GlucoseHistorySummary.requestedDays(question, defaultDays: historyDays))
        let needsModel = ExplanationFallback().requiredResponse(decision: SafetyDecisionEngine(policy: preflight.policy).evaluate(cgm: preflight.currentGlucose, forecast: preflight.forecastResult), userText: question, snapshot: preflight) == nil
        let modelUse = needsModel ? await assistant.prepareForTurn() : false
        defer { if modelUse { assistant.finishTurn() } }
        let snapshot = assistantSnapshot(at: Date(), historyWindow: GlucoseHistorySummary.requestedDays(question, defaultDays: historyDays))
        let history = messages.map { JoeChatTurn(role: $0.role == .user ? "user" : "assistant", content: $0.text) }
        let turn = await coordinator.answer(question, snapshot: snapshot, history: history)
        reply = turn.response; assistantMode = turn.mode
        do { try store.save(assistantTurn: turn) }
        catch { warnings.append("The response is shown, but its research log could not be saved.") }
        messages.append(ChatMessage(role: .joe, text: reply, mode: assistantMode, diagnostics: turn.fallbackDetails))
        if autoSpeak && !isInBackground { voiceInput.cancel(); speech.speak(reply) }
    }
    func startPersonaRegression() {
        guard !isAnswering, !isRunningPersonaRegression else { return }
        regressionTask = Task { await runPersonaRegression() }
    }
    func cancelPersonaRegression() { regressionTask?.cancel() }
    func runPersonaRegression() async {
        guard !isAnswering, !isRunningPersonaRegression else { return }
        isRunningPersonaRegression = true; speech.stop(); voiceInput.cancel()
        defer { isRunningPersonaRegression = false; regressionTask = nil }
        let modelUse = await assistant.prepareForTurn()
        defer { if modelUse { assistant.finishTurn() } }
        guard !Task.isCancelled else { regressionStatus = "Regression canceled."; return }
        var generated = 0; var fallbacks = 0
        for item in PersonaRegressionCase.all {
            guard !Task.isCancelled else { regressionStatus = "Regression canceled."; return }
            let now = Date()
            // Synthetic data is isolated from clinical records, chat bubbles, forecasts, and audio.
            let synthetic = AssistantSnapshot(glucose: GlucoseSample(id: "regression-only", timestamp: now, glucose: 120, direction: "Flat", receivedAt: now),
                forecast: nil, treatments: [], context: nil, now: now)
            let turn = await coordinator.answer(item.text, snapshot: synthetic,
                history: [JoeChatTurn(role: "user", content: item.text)], regressionCaseID: item.id)
            guard !Task.isCancelled else { regressionStatus = "Regression canceled."; return }
            do { try store.save(assistantTurn: turn) }
            catch { regressionStatus = "Regression log could not be saved."; return }
            if turn.mode == "Gemma 4 E2B · Validated" { generated += 1 } else { fallbacks += 1 }
            regressionStatus = "Completed \(generated + fallbacks)/\(PersonaRegressionCase.all.count) cases."
        }
        regressionStatus = "Complete: \(generated) validated model replies, \(fallbacks) fallbacks. Export research JSON for versions, safety decisions and rejection reasons. Tone/empathy still require manual review."
    }
    func export() {
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Joe-research-export.json")
            try store.exportResearch().write(to: url, options: [.atomic, .completeFileProtection])
            exportURL = url
        } catch { syncError = "Export failed" }
    }
    func erase() {
        guard !isRefreshing, !isAnswering, !isRunningPersonaRegression else { return }
        do {
            KeychainStore.removeLegacyConversationCredential(); try KeychainStore.delete(); try store.erase()
            health.disable(); UserDefaults.standard.set(false, forKey: "calendarEnabled"); location.forgetAll(); voiceInput.cancel(); speech.stop()
            if let exportURL { try? FileManager.default.removeItem(at: exportURL) }; exportURL = nil
            healthGlucoseHistory = []; healthHistoryStatus = "Health collection paused."
            calendarDay = nil
            connected = false; glucose = []; treatments = []; context = nil; currentContext = nil; forecast = nil
            matchedCount = 0; mae30 = nil; mae60 = nil; lastSync = nil; warnings = []; syncError = nil
            syncStatus = "Local data cleared"; forecastStatus = "Waiting for CGM data"; reply = "Local records have been cleared."
            messages = [ChatMessage(role: .joe, text: reply)]
        } catch { syncError = "Failed to clear data: " + error.localizedDescription }
    }
}
