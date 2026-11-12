import Foundation
import JoeCore
@MainActor final class LiveProvider: AssistantModelProvider {
    let runtime = GemmaRuntime()
    var runtimeVersion: String { "Mac synthetic smoke; " + GemmaModelSpec.modelID + "; " + GemmaModelSpec.revision + "; " + GemmaModelSpec.sha256 + "; " + GemmaPromptBuilder.adapterVersion + "; " + GemmaModelSpec.runtimeVersion + "; CPU/4threads/context4096; " + ProcessInfo.processInfo.operatingSystemVersionString }
    func availability(language: ReplyLanguage) -> ModelAvailability { .available }
    func prewarm() {}
    func respond(to request: AssistantModelRequest) async throws -> ModelReply {
        let payload = try GemmaPromptBuilder.build(request: request)
        return ModelReply(text: try await runtime.generate(prompt: payload.prompt), usedTools: payload.usedTools)
    }
}
@main struct Smoke {
    @MainActor static func main() async throws {
        let model = URL(fileURLWithPath: CommandLine.arguments[1])
        try GemmaModelSpec.verify(file: model)
        print("SHA256 verified")
        let provider = LiveProvider()
        let start = Date()
        try await provider.runtime.load(modelURL: model, cacheURL: URL(fileURLWithPath: FileManager.default.temporaryDirectory.appendingPathComponent("JoeGemmaSmokeCache").path))
        print("Loaded in \(Date().timeIntervalSince(start))s")
        let coordinator = AssistantCoordinator(provider: provider)
        var turns: [AssistantTurnRecord] = []
        for item in PersonaRegressionCase.all {
            let now = Date()
            let snapshot = AssistantSnapshot(glucose: GlucoseSample(id: "synthetic", timestamp: now, glucose: 120, direction: "Flat", receivedAt: now), forecast: nil, treatments: [], context: nil, now: now)
            let turn = await coordinator.answer(item.text, snapshot: snapshot, history: [], regressionCaseID: item.id)
            print("CASE: \(item.id)\nQUESTION: \(item.text)\nREPLY: \(turn.response)\nMODE: \(turn.mode)\nREJECT: \(turn.validationReasons)")
            turns.append(turn)
        }
        // Replay the reported lunch conversation; later turns must resolve the topic from history.
        var history: [JoeChatTurn] = []
        for (index, question) in ["What should I have for lunch?", "Give me some recommendations", "Something healthy but tasty", "Yes give me some suggestions"].enumerated() {
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
        let interval = cal.dateInterval(of: .day, for: now)!
        let day = CalendarDayResult(status: .available, dayStart: interval.start, dayEnd: interval.end, timeZone: zone, events: [
            CalendarDayEvent(title: "Research meeting", start: interval.start.addingTimeInterval(36000), end: interval.start.addingTimeInterval(39600)),
            CalendarDayEvent(title: "Ballet class", start: interval.start.addingTimeInterval(64800), end: interval.start.addingTimeInterval(68400))])
        let snapshot = AssistantSnapshot(glucose: nil, forecast: nil, treatments: [], context: nil, now: now, calendarDay: day)
        let turn = await coordinator.answer("What's on my calendar today?", snapshot: snapshot, history: [], regressionCaseID: "en-calendar-day")
        print("CALENDAR: \(turn.response)\nMODE: \(turn.mode)\nREJECT: \(turn.validationReasons)")
        turns.append(turn)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(turns).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        await provider.runtime.unload()
    }
}
