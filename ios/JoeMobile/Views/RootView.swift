import SwiftUI
import Charts
import JoeCore

struct RootView: View {
    @Bindable var state: AppState
    var body: some View {
        TabView {
            DashboardView(state: state).tabItem { Label("Overview", systemImage: "waveform.path.ecg") }
            ContextView(state: state).tabItem { Label("Lifestyle", systemImage: "leaf") }
            AssistantView(state: state).tabItem { Label("Joe", systemImage: "bubble.left.and.bubble.right") }
            SettingsView(state: state).tabItem { Label("Settings", systemImage: "gearshape") }
        }.tint(.teal)
    }
}

struct DashboardView: View {
    @Bindable var state: AppState
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    TimelineView(.periodic(from: .now, by: 30)) { timeline in
                        GroupBox {
                            if let sample = state.glucose.last {
                                let fresh = sample.isFresh(at: timeline.date, threshold: state.staleMinutes*60)
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(fresh ? "Latest measurement" : "Historical reading · Stale", systemImage: fresh ? "checkmark.circle" : "clock.badge.exclamationmark")
                                        .foregroundStyle(fresh ? .teal : .orange)
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(sample.glucose.formatted(.number.precision(.fractionLength(0)))).font(.system(size: 60, weight: .semibold, design: .rounded))
                                        Text("mg/dL").foregroundStyle(.secondary)
                                    }
                                    Text(sample.direction ?? "Trend unavailable")
                                    Text("CGM time: " + sample.timestamp.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                                    Text("\(max(0, Int(timeline.date.timeIntervalSince(sample.timestamp)/60))) minutes ago").font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            } else { ContentUnavailableView("No CGM data", systemImage: "waveform.path.ecg", description: Text("Connect to Nightscout in Settings. Glucose is never guessed when data is unavailable.")) }
                        }
                    }
                    if !state.glucose.isEmpty {
                        GroupBox("Last 6 hours · Measurements") {
                            Chart(state.glucose.filter { $0.timestamp > Date().addingTimeInterval(-6*3600) }) { sample in
                                LineMark(x: .value("Time", sample.timestamp), y: .value("mg/dL", sample.glucose))
                                    .foregroundStyle(.teal)
                            }.chartYScale(domain: 40...400).frame(height: 180)
                        }
                    }
                    GroupBox("On-device forecast") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(state.forecastStatus).font(.subheadline).foregroundStyle(.secondary)
                            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                                if let forecast = state.forecast, let latest = state.glucose.last,
                                   latest.isFresh(at: timeline.date, threshold: state.staleMinutes*60), forecast.sourceTimestamp == latest.timestamp {
                                    Text("30 min: \(Int(forecast.glucose30)) mg/dL")
                                    Text("60 min: \(Int(forecast.glucose60)) mg/dL")
                                    Text("Relative to the CGM timestamp; validation absolute error P90: ±\(Int(forecast.uncertainty30)) / ±\(Int(forecast.uncertainty60)) mg/dL. These are not guaranteed bounds.").font(.caption)
                                    Text("Missing: " + forecast.flags.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text("Research shadow mode. No insulin dosing advice or pump control.").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("Pump and meal records") {
                        VStack(alignment: .leading, spacing: 8) {
                            if state.treatments.isEmpty { Text("No visible records does not mean no insulin was delivered or food was consumed").foregroundStyle(.secondary) }
                            ForEach(Array(state.treatments.suffix(5).reversed())) { event in
                                VStack(alignment: .leading) {
                                    Text(event.kind)
                                    Text(event.timestamp.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                    if let units = event.insulin { Text("Recorded: \(units.formatted()) U").font(.caption) }
                                    if let carbs = event.carbs { Text("Carbs: \(carbs.formatted()) g").font(.caption) }
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("Prospective evaluation") {
                        VStack(alignment: .leading) {
                            Text("Matched at 60 min: \(state.matchedCount) records")
                            Text("MAE 30m / 60m: \(state.mae30.map { String(format: "%.1f", $0) } ?? "—") / \(state.mae60.map { String(format: "%.1f", $0) } ?? "—") mg/dL")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(state.syncStatus).font(.caption).foregroundStyle(.secondary)
                    if let error = state.syncError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    ForEach(state.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                }.padding()
            }
            .navigationTitle("Joe")
            .toolbar { Button { Task { await state.refresh() } } label: {
                if state.isRefreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
            }.disabled(state.isRefreshing) }
            .refreshable { await state.refresh() }
        }
    }
}

struct ContextView: View {
    @Bindable var state: AppState
    @State private var status: String?
    @State private var place = "home"
    var body: some View {
        NavigationStack {
            Form {
                Section("HealthKit · Read-only access") {
                    Button("Enable steps, heart rate, sleep, and workouts") { Task {
                        do { try await state.health.authorize(); await state.refresh() }
                        catch { status = "HealthKit authorization request failed" }
                    } }
                    Button("Pause HealthKit collection") { state.health.disable(); Task { await state.refresh() } }
                    LabeledContent("Steps in the last 30 min", value: state.context?.steps.map { String(Int($0)) } ?? "Missing")
                    LabeledContent("Heart rate", value: state.context?.heartRate.map { "\(Int($0)) bpm" } ?? "Missing")
                    LabeledContent("Most recent sleep", value: state.context?.sleepHours.map { String(format: "%.1f hours", $0) } ?? "Missing")
                    Text("Empty results may indicate no data, partial access, or denied access. iOS does not disclose which read permissions were denied.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Calendar · Categories only") {
                    Button("Enable calendar access") { Task {
                        do { status = try await state.calendar.authorize() ? "Calendar enabled" : "Calendar access not granted"; await state.refresh() }
                        catch { status = "Calendar authorization request failed" }
                    } }
                    Button("Pause calendar collection") { UserDefaults.standard.set(false, forKey: "calendarEnabled"); Task { await state.refresh() } }
                    LabeledContent("Current", value: state.context?.calendar ?? "No visible events / Access unavailable")
                    LabeledContent("Next event", value: state.calendarSnapshot.next ?? "No visible events")
                    if let date = state.calendarSnapshot.nextStart { Text("Next event: " + date.formatted(date: .omitted, time: .shortened)) }
                }
                Section("Location · Low power") {
                    Button("Enable location while using the app") { state.location.authorize() }
                    Button("Allow background Visits / geofences (optional)") { state.location.enableBackgroundVisits() }
                    Button("Refresh current place category") { state.location.refresh() }
                    Button("Pause location collection") { state.location.disable() }
                    LabeledContent("Latest category", value: state.location.category ?? "Unknown")
                    Picker("Named place", selection: $place) {
                        ForEach(["home", "school", "work", "gym", "restaurant", "other"], id: \.self) { Text($0) }
                    }
                    Button("Save current location as \(place)") { state.location.saveCurrentPlace(category: place) }
                    ForEach(state.location.places) { saved in
                        HStack { Text(saved.id); Spacer(); Button("Delete") { state.location.removePlace(saved.id) } }
                    }
                    Text("Coordinates are saved only for places you explicitly name. Visit records contain categories and times, not routes. iOS controls background updates.").font(.caption).foregroundStyle(.secondary)
                    if let message = state.location.message { Text(message).foregroundStyle(.orange) }
                }
                if let status { Text(status) }
            }.navigationTitle("Lifestyle Context")
        }
    }
}

struct AssistantView: View {
    @Bindable var state: AppState
    @State private var question = "Explain my current results"
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(state.assistant.availability).font(.caption).foregroundStyle(.secondary)
                    Text(state.reply).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding().background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    Text(state.assistantMode).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Read aloud", systemImage: "speaker.wave.2") { state.speech.speak(state.reply) }
                        Button("Stop", systemImage: "stop") { state.speech.stop() }
                    }
                    TextField("Enter a question", text: $question, axis: .vertical).textFieldStyle(.roundedBorder)
                    Button { let text = question; Task { await state.ask(text) } } label: {
                        if state.isAnswering { ProgressView() } else { Label("Ask Joe", systemImage: "arrow.up.circle.fill") }
                    }.buttonStyle(.borderedProminent).disabled(state.isAnswering || question.isEmpty)
                }.padding()
            }.navigationTitle("Chat with Joe")
        }
    }
}

struct SettingsView: View {
    @Bindable var state: AppState
    @State private var url = ""
    @State private var secret = ""
    @State private var auth = NightscoutCredentials.Auth.token
    @State private var eraseConfirmation = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Direct Nightscout connection") {
                    TextField("https://your-nightscout.example.com", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Picker("Authentication", selection: $auth) { Text("Read-only access token").tag(NightscoutCredentials.Auth.token); Text("API secret SHA-1").tag(NightscoutCredentials.Auth.secretSHA1) }
                    SecureField("Token or SHA-1 hash", text: $secret).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save and connect") { let credential = secret; secret = ""; Task { await state.configure(url: url, secret: credential, auth: auth) } }
                        .disabled(state.isRefreshing || secret.isEmpty || url.isEmpty)
                    Text(state.connected ? "Credentials are stored in this device's Keychain" : "Not configured").font(.caption)
                    if let error = state.syncError { Text(error).foregroundStyle(.orange) }
                    Text("Disable Tailscale and Wi-Fi, then test Nightscout HTTPS over cellular. The URL and credentials are stored only in Keychain. Secrets from the old repository are not imported automatically.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Data quality") {
                    Stepper("CGM stale threshold: \(Int(state.staleMinutes)) minutes", value: $state.staleMinutes, in: 5...30, step: 5)
                    Text("Sync runs on launch, foreground entry, manual refresh, and background opportunities granted by iOS. Five-minute wakeups are not guaranteed.").font(.caption)
                }
                Section("Research data · Stored locally") {
                    Button("Prepare research JSON export") { state.export() }.disabled(state.isRefreshing)
                    if let exportURL = state.exportURL { ShareLink("Share export", item: exportURL) }
                    Text("Exports contain health records, categories, forecasts, and errors, but no Nightscout credentials or calendar titles. Choose where to save the file.").font(.caption).foregroundStyle(.secondary)
                    Button("Clear local data and credentials", role: .destructive) { eraseConfirmation = true }.disabled(state.isRefreshing || state.isAnswering)
                }
                Section("About forecasts") {
                    Text("Forecasting pauses when the model is missing, data is stale, or history is insufficient. Deterministic explanations are used when Apple's on-device model is unavailable. Forecasts are for observational research, not treatment adjustments.")
                    Text("Joe has no pump-control interface. Runtime use requires no Mac, Python server, Tailscale, Ollama, or cloud LLM.").font(.caption)
                }
            }.navigationTitle("Settings")
                .confirmationDialog("Clear all local research data, places, and Nightscout credentials?", isPresented: $eraseConfirmation, titleVisibility: .visible) {
                    Button("Clear", role: .destructive) { state.erase(); url = ""; secret = "" }
                }
        }
    }
}
