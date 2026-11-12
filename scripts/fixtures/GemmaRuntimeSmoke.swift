import Foundation
import JoeCore
@MainActor final class LiveProvider: AssistantModelProvider {
    let runtime = GemmaRuntime()
    var runtimeVersion: String { "Mac synthetic smoke; " + GemmaModelSpec.modelID + "; " + GemmaModelSpec.revision + "; " + GemmaModelSpec.sha256 + "; " + GemmaPromptBuilder.adapterVersion + "; " + GemmaModelSpec.runtimeVersion + "; CPU/4threads/context4096; " + ProcessInfo.processInfo.operatingSystemVersionString }
    func availability(language: ReplyLanguage) -> ModelAvailability { .available }
    func prewarm() {}
    func respond(to request: AssistantModelRequest) async throws -> ModelReply {
        let payload = try GemmaPromptBuilder.build(request: request)
        return ModelReply(text: try await runtime.generate(prompt: payload.prompt, maxOutputTokens: payload.maxOutputTokens), usedTools: payload.usedTools)
    }
}
@main struct Smoke {
    @MainActor static func main() async throws {
        let model = URL(fileURLWithPath: CommandLine.arguments[1])
        try GemmaModelSpec.verify(file: model)
        print("SHA256 verified")
        if CommandLine.arguments.contains("--lifecycle-only") {
            let runtime = GemmaRuntime()
            let lifecycle = LocalModelLifecycle(idleSeconds: 0.1, backgroundSeconds: 0.05, load: {
                try await runtime.load(modelURL: model, cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent("JoeGemmaLifecycleCache"))
            }, unload: { await runtime.unload() })
            var states: [String] = []
            var replies: [String] = []
            func useModel() async throws {
                try await lifecycle.beginUse()
                defer { lifecycle.endUse() }
                let now = Date()
                let snapshot = AssistantSnapshot(glucose: GlucoseSample(id: "synthetic", timestamp: now, glucose: 120, receivedAt: now), forecast: nil, treatments: [], context: nil, now: now)
                let payload = try GemmaPromptBuilder.build(request: AssistantModelRequest(question: "Hello Joe", history: [], snapshot: snapshot, decision: .normal, allowedTools: []))
                let reply = try await runtime.generate(prompt: payload.prompt, maxOutputTokens: payload.maxOutputTokens)
                guard !reply.isEmpty else { throw AssistantFailure.generationError }
                replies.append(reply)
            }
            try await useModel()
            guard lifecycle.phase == .ready else { throw AssistantFailure.assetsUnavailable }
            states.append("loaded and generated")
            await lifecycle.setBackground(true)
            guard lifecycle.phase == .ready else { throw AssistantFailure.assetsUnavailable }
            states.append("brief background retained engine")
            await lifecycle.setBackground(false)
            for _ in 0..<100 {
                if lifecycle.phase == .unloaded { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard lifecycle.phase == .unloaded else { throw AssistantFailure.generationError }
            do {
                _ = try await runtime.generate(prompt: "Should not run without weights")
                throw AssistantFailure.generationError
            } catch AssistantFailure.assetsUnavailable { states.append("idle unload released native engine") }
            try await useModel()
            guard lifecycle.phase == .ready else { throw AssistantFailure.assetsUnavailable }
            states.append("next use reloaded and generated")
            await lifecycle.release()
            guard lifecycle.phase == .unloaded else { throw AssistantFailure.generationError }
            states.append("explicit release completed")
            let report: [String: Any] = ["scope": "Synthetic Mac CPU lifecycle integration; not iPhone memory/thermal validation", "runtime": GemmaModelSpec.runtimeVersion, "sha256": GemmaModelSpec.sha256, "states": states, "replies": replies]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
            print("LIFECYCLE: " + states.joined(separator: "; "))
            return
        }
        let provider = LiveProvider()
        let start = Date()
        try await provider.runtime.load(modelURL: model, cacheURL: URL(fileURLWithPath: FileManager.default.temporaryDirectory.appendingPathComponent("JoeGemmaSmokeCache").path))
        print("Loaded in \(Date().timeIntervalSince(start))s")
        let coordinator = AssistantCoordinator(provider: provider)
        var turns: [AssistantTurnRecord] = []
        let calendarOnly = CommandLine.arguments.contains("--calendar-only")
        for item in (calendarOnly ? [] : PersonaRegressionCase.all) {
            let now = Date()
            let snapshot = AssistantSnapshot(glucose: GlucoseSample(id: "synthetic", timestamp: now, glucose: 120, direction: "Flat", receivedAt: now), forecast: nil, treatments: [], context: nil, now: now)
            let turn = await coordinator.answer(item.text, snapshot: snapshot, history: [], regressionCaseID: item.id)
            print("CASE: \(item.id)\nQUESTION: \(item.text)\nREPLY: \(turn.response)\nMODE: \(turn.mode)\nREJECT: \(turn.validationReasons)")
            turns.append(turn)
        }
        // Replay the reported lunch conversation; later turns must resolve the topic from history.
        var history: [JoeChatTurn] = []
        for (index, question) in (calendarOnly ? [] : ["What should I have for lunch?", "Give me some recommendations", "Something healthy but tasty", "Yes give me some suggestions"]).enumerated() {
            let now = Date()
            let snapshot = AssistantSnapshot(glucose: GlucoseSample(id: "synthetic", timestamp: now, glucose: 120, direction: "Flat", receivedAt: now), forecast: nil, treatments: [], context: nil, now: now)
            history.append(JoeChatTurn(role: "user", content: question))
            let turn = await coordinator.answer(question, snapshot: snapshot, history: history, regressionCaseID: "en-lunch-followup-\(index)")
            history.append(JoeChatTurn(role: "assistant", content: turn.response))
            print("LUNCH: \(question)\nREPLY: \(turn.response)\nMODE: \(turn.mode)\nREJECT: \(turn.validationReasons)")
            turns.append(turn)
        }
        let now = Date()
        let zone = TimeZone(secondsFromGMT: 0)!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
        let range = CalendarQueryRange(question: "calendar this week", now: now, timeZone: zone)
        let interval = DateInterval(start: range.start, end: range.end)
        let day = CalendarDayResult(status: .available, dayStart: interval.start, dayEnd: interval.end, timeZone: zone, events: [
            CalendarDayEvent(title: "Research meeting", start: interval.start.addingTimeInterval(36000), end: interval.start.addingTimeInterval(39600)),
            CalendarDayEvent(title: "Ballet class", start: interval.start.addingTimeInterval(2 * 86400 + 64800), end: interval.start.addingTimeInterval(2 * 86400 + 68400))], scope: range.scope, queriedAt: now)
        let snapshot = AssistantSnapshot(glucose: nil, forecast: nil, treatments: [], context: nil, now: now, calendarDay: day)
        let turn = await coordinator.answer("What's on my calendar this week?", snapshot: snapshot, history: [], regressionCaseID: "en-calendar-week")
        print("CALENDAR: \(turn.response)\nMODE: \(turn.mode)\nREJECT: \(turn.validationReasons)")
        turns.append(turn)
        let today = CalendarQueryRange(question: "calendar today", now: now, timeZone: zone)
        let sixEvents = [
            CalendarDayEvent(title: "No-meeting day", start: today.start, end: today.end, allDay: true),
            CalendarDayEvent(title: "Team member - PTO", start: today.start, end: today.end, allDay: true),
            CalendarDayEvent(title: "Class", start: today.start.addingTimeInterval(34200), end: today.start.addingTimeInterval(38700)),
            CalendarDayEvent(title: "TRAINING WIRE", start: today.start.addingTimeInterval(37800), end: today.start.addingTimeInterval(39600)),
            CalendarDayEvent(title: "Research Meeting", start: today.start.addingTimeInterval(46800), end: today.start.addingTimeInterval(52200)),
            CalendarDayEvent(title: "Private Appointment", start: today.start.addingTimeInterval(59400), end: today.start.addingTimeInterval(61200))]
        let fullDay = CalendarDayResult(status: .available, dayStart: today.start, dayEnd: today.end, timeZone: zone, events: sixEvents, scope: today.scope, queriedAt: now)
        let todaySnapshot = AssistantSnapshot(glucose: nil, forecast: nil, treatments: [], context: nil, now: now, calendarDay: fullDay)
        let todayTurn = await coordinator.answer("What's on my calendar today?", snapshot: todaySnapshot, history: [], regressionCaseID: "en-calendar-six-events")
        print("SIX EVENTS: \(todayTurn.response)\nMODE: \(todayTurn.mode)\nREJECT: \(todayTurn.validationReasons)")
        turns.append(todayTurn)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(turns).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        await provider.runtime.unload()
    }
}
