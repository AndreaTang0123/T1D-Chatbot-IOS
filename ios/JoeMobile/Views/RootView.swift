import SwiftUI
import Charts
import JoeCore

struct RootView: View {
    @Bindable var state: AppState
    @State private var selection = 0
    var body: some View {
        TabView(selection: $selection) {
            AssistantView(state: state).tabItem { Label("Joe", systemImage: "bubble.left.and.bubble.right") }.tag(0)
            DashboardView(state: state).tabItem { Label("Overview", systemImage: "waveform.path.ecg") }.tag(1)
            ContextView(state: state).tabItem { Label("Lifestyle", systemImage: "leaf") }.tag(2)
            SettingsView(state: state).tabItem { Label("Settings", systemImage: "gearshape") }.tag(3)
        }.tint(.teal)
    }
}

struct DashboardView: View {
    @Bindable var state: AppState
    @State private var hours = 3
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    TimelineView(.periodic(from: .now, by: 30)) { timeline in
                        if let sample = state.glucose.last {
                            glucoseHeader(sample, now: timeline.date)
                        } else {
                            ContentUnavailableView("No CGM data", systemImage: "waveform.path.ecg", description: Text("Connect to Nightscout in Settings to see your readings."))
                        }
                    }
                    chartCard
                    forecastCard
                    bolusCard
                    GroupBox("Prospective evaluation") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Matched at 60 min: \(state.matchedCount) records")
                            Text("MAE 30m / 60m: \(state.mae30.map { String(format: "%.1f", $0) } ?? "—") / \(state.mae60.map { String(format: "%.1f", $0) } ?? "—") mg/dL")
                        }.font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(state.syncStatus).font(.caption).foregroundStyle(.secondary)
                        if let error = state.syncError { Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange) }
                        ForEach(state.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Overview")
            .toolbar { Button { Task { await state.refresh() } } label: {
                if state.isRefreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
            }.disabled(state.isRefreshing).accessibilityLabel("Refresh data") }
            .refreshable { await state.refresh() }
        }
    }
    private func glucoseHeader(_ sample: GlucoseSample, now: Date) -> some View {
        let fresh = sample.isFresh(at: now, threshold: state.staleMinutes * 60)
        let trend = GlucoseTrend(direction: sample.direction)
        return VStack(spacing: 14) {
            Text(fresh ? "LATEST GLUCOSE" : "HISTORICAL READING · STALE")
                .font(.caption.weight(.semibold)).tracking(2).foregroundStyle(fresh ? Color.secondary : Color.orange)
            HStack(alignment: .center, spacing: 20) {
                VStack(spacing: 0) {
                    Text(sample.glucose.formatted(.number.precision(.fractionLength(0))))
                        .font(.system(size: 70, weight: .semibold, design: .rounded)).minimumScaleFactor(0.6)
                    Text("mg/dL").font(.title3).foregroundStyle(.secondary)
                }
                Text(trend.arrow).font(.system(size: 48, weight: .semibold)).foregroundStyle(fresh ? Color.primary : Color.secondary)
                    .accessibilityLabel(fresh ? trend.label : "Historical trend: " + trend.label)
            }
            .frame(minWidth: 230, minHeight: 205)
            .padding(20)
            .background(.background, in: RoundedRectangle(cornerRadius: 100))
            .overlay(RoundedRectangle(cornerRadius: 100).stroke(.quaternary, lineWidth: 8))
            .shadow(color: .black.opacity(0.05), radius: 18, y: 8)
            Text("\(max(0, Int(now.timeIntervalSince(sample.timestamp) / 60))) minutes ago · " + sample.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.footnote).foregroundStyle(.secondary)
            if !fresh { Text("This reading does not represent your current glucose.").font(.caption).foregroundStyle(.orange) }
        }.frame(maxWidth: .infinity).padding(.vertical, 12)
    }
    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            Picker("Chart history", selection: $hours) {
                ForEach([3, 6, 12, 24], id: \.self) { Text("\($0)h").tag($0) }
            }.pickerStyle(.segmented)
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                let start = timeline.date.addingTimeInterval(-Double(hours) * 3600)
                let visible = state.glucose.filter { $0.timestamp >= start && $0.timestamp <= timeline.date }
                if visible.isEmpty {
                    ContentUnavailableView("No readings in this window", systemImage: "chart.xyaxis.line")
                        .frame(height: 230)
                } else {
                    Chart {
                        RuleMark(y: .value("Low reference", 70)).foregroundStyle(.pink.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                        RuleMark(y: .value("High reference", 180)).foregroundStyle(.orange.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                        ForEach(visible) { sample in
                            PointMark(x: .value("Time", sample.timestamp), y: .value("mg/dL", sample.glucose))
                                .foregroundStyle(Color.primary.opacity(0.8)).symbolSize(18)
                        }
                    }
                    .chartXScale(domain: start...timeline.date)
                    .chartYScale(domain: 40...400)
                    .chartYAxis { AxisMarks(position: .trailing, values: [40, 70, 180, 400]) }
                    .frame(height: 230)
                    .accessibilityLabel("Measured glucose over the last \(hours) hours")
                }
            }
            Text("Measurements · mg/dL").font(.caption).foregroundStyle(.secondary)
        }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 24))
    }
    private var forecastCard: some View {
        GroupBox("On-device forecast") {
            VStack(alignment: .leading, spacing: 10) {
                Text(state.forecastStatus).font(.subheadline).foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    if let forecast = state.forecast, let latest = state.glucose.last,
                       latest.isFresh(at: timeline.date, threshold: state.staleMinutes * 60), forecast.sourceTimestamp == latest.timestamp {
                        Text("30 min: \(Int(forecast.glucose30)) mg/dL")
                        Text("60 min: \(Int(forecast.glucose60)) mg/dL")
                        Text("Relative to the CGM timestamp. Validation error P90: ±\(Int(forecast.uncertainty30)) / ±\(Int(forecast.uncertainty60)) mg/dL; not guaranteed bounds.").font(.caption)
                        Text("Missing: " + forecast.flags.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Experimental research forecasts. No insulin dosing advice or pump control.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var bolusCard: some View {
        GroupBox("Latest bolus") {
            if let event = Treatment.latestBolus(in: state.treatments, at: Date()), let units = event.insulin {
                HStack(alignment: .top) {
                    Image(systemName: "drop.fill").foregroundStyle(.teal).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(units.formatted()) U").font(.title2.weight(.semibold))
                        Text(event.timestamp.formatted(date: .abbreviated, time: .shortened)).font(.subheadline).foregroundStyle(.secondary)
                        if let carbs = event.carbs { Text("Carbs recorded: \(carbs.formatted()) g").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("No bolus is visible in the synced records. This does not mean no insulin was delivered.")
                    .font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct ContextView: View {
    @Bindable var state: AppState
    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                let context = state.currentContext.flatMap { timeline.date.timeIntervalSince($0.timestamp) <= 900 ? $0 : nil }
                Form {
                    Section("Activity") {
                        LabeledContent("Steps · Last 30 min", value: context?.steps.map { String(Int($0)) } ?? "Unavailable")
                        LabeledContent("Heart rate", value: context?.heartRate.map { "\(Int($0)) bpm" } ?? "Unavailable")
                        LabeledContent("Recent workout", value: context?.workoutActive.map { $0 ? "Recent / active" : "No recent workout in visible records" } ?? "Unavailable")
                    }
                    Section("Sleep") {
                        LabeledContent("Latest sleep episode", value: context?.sleepHours.map { String(format: "%.1f hours", $0) } ?? "Unavailable")
                    }
                    Section("Calendar") {
                        LabeledContent("Current event category", value: currentCalendar(at: timeline.date) ?? "No current event / Access unavailable")
                    }
                    Section("Place") {
                        LabeledContent("Current category", value: state.location.category(at: timeline.date) ?? "Unavailable")
                    }
                    Section {
                        if let context { Text("Updated " + context.timestamp.formatted(date: .omitted, time: .shortened)) }
                        Text("Manage data access in Settings. Unavailable values are never estimated.")
                    }.font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Lifestyle")
            .toolbar { Button { Task { await state.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(state.isRefreshing).accessibilityLabel("Refresh context") }
            .refreshable { await state.refresh() }
        }
    }
    private func currentCalendar(at now: Date) -> String? {
        guard let context = state.currentContext, now.timeIntervalSince(context.timestamp) <= 900,
              let end = state.calendarSnapshot.currentEnd, end > now else { return nil }
        return context.calendar
    }
}

struct AssistantView: View {
    @Bindable var state: AppState
    @State private var question = ""
    @State private var isHolding = false
    @State private var voicePrefix = ""
    @FocusState private var inputFocused: Bool
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        Label("Your on-device companion", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                        ForEach(state.messages) { message in messageBubble(message).id(message.id) }
                        if state.isAnswering {
                            HStack(spacing: 8) { ProgressView(); Text("Joe is thinking…").font(.subheadline).foregroundStyle(.secondary) }
                                .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 18))
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: state.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: state.isAnswering) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: inputFocused) { _, focused in if focused { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } } }
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Joe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button { state.speech.stop() } label: { Image(systemName: "speaker.slash") }.accessibilityLabel("Stop reading aloud") }
            .onChange(of: state.voiceInput.transcript) { _, text in
                guard !text.isEmpty else { return }
                question = voicePrefix.isEmpty ? text : voicePrefix + " " + text
            }
            .onDisappear { isHolding = false; state.voiceInput.cancel(); state.speech.stop() }
        }
    }
    private func messageBubble(_ message: ChatMessage) -> some View {
        let fromJoe = message.role == .joe
        return HStack(alignment: .bottom, spacing: 8) {
            if !fromJoe { Spacer(minLength: 42) }
            VStack(alignment: .leading, spacing: 8) {
                Text(message.text).textSelection(.enabled).font(.body)
                HStack {
                    Text(message.timestamp.formatted(date: .omitted, time: .shortened)).font(.caption2)
                    if fromJoe {
                        Spacer()
                        Button { state.voiceInput.cancel(); state.speech.speak(message.text) } label: { Image(systemName: "speaker.wave.2") }
                            .buttonStyle(.plain).accessibilityLabel("Read Joe's message aloud")
                    }
                }.foregroundStyle(fromJoe ? Color.secondary : Color.white.opacity(0.85))
            }
            .padding(15)
            .foregroundStyle(fromJoe ? Color.primary : Color.white)
            .background(fromJoe ? Color(.secondarySystemGroupedBackground) : Color.teal, in: RoundedRectangle(cornerRadius: 20))
            if fromJoe { Spacer(minLength: 42) }
        }
    }
    private var composer: some View {
        VStack(spacing: 10) {
            if state.messages.count == 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(["My glucose", "Explain my forecast", "My lifestyle context"], id: \.self) { text in
                            Button(text) { send(text) }.buttonStyle(.bordered).disabled(state.isAnswering || voiceBusy)
                        }
                    }
                }
            }
            if let message = state.voiceInput.message { Text(message).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading) }
            HStack(alignment: .bottom, spacing: 10) {
                Image(systemName: state.voiceInput.isRecording ? "waveform" : "mic.fill")
                    .font(.title3).foregroundStyle(state.voiceInput.isRecording ? Color.white : Color.teal)
                    .frame(width: 46, height: 46)
                    .background(state.voiceInput.isRecording ? Color.red : Color.teal.opacity(0.1), in: Circle())
                    .contentShape(Circle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { _ in
                        guard !isHolding, !state.isAnswering, !state.voiceInput.isFinishing else { return }
                        isHolding = true; voicePrefix = question; inputFocused = false; state.speech.stop()
                        Task { guard isHolding else { return }; await state.voiceInput.press() }
                    }.onEnded { _ in isHolding = false; state.voiceInput.release() })
                    .accessibilityElement().accessibilityLabel("Hold to talk")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(named: Text("Start or stop dictation")) {
                        if state.voiceInput.isRecording { state.voiceInput.release() }
                        else if !state.isAnswering && !voiceBusy {
                            voicePrefix = question; state.speech.stop(); Task { await state.voiceInput.press() }
                        }
                    }
                TextField("Message Joe…", text: $question, axis: .vertical)
                    .lineLimit(1...5).focused($inputFocused).padding(12)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 22))
                    .disabled(voiceBusy)
                Button { send(question) } label: {
                    Image(systemName: "arrow.up").font(.title3.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).background(Color.teal, in: Circle())
                }.disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isAnswering || voiceBusy)
                    .opacity(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isAnswering || voiceBusy ? 0.4 : 1)
                    .accessibilityLabel("Send message")
            }
            Text(state.voiceInput.isPreparing ? "Preparing microphone…" : state.voiceInput.isRecording ? "Listening… Release to finish" : state.voiceInput.isFinishing ? "Finishing transcription…" : "Hold to talk · Review, then send")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(.horizontal).padding(.vertical, 12).background(.bar)
    }
    private var voiceBusy: Bool { state.voiceInput.isPreparing || state.voiceInput.isRecording || state.voiceInput.isFinishing }
    private func send(_ text: String) {
        guard !state.isAnswering, !voiceBusy, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let outgoing = text; question = ""; inputFocused = false
        Task { await state.ask(outgoing) }
    }
}

struct DataAccessSettingsView: View {
    @Bindable var state: AppState
    @State private var status: String?
    @State private var place = "home"
    var body: some View {
        Group {
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
            if let status { Section { Text(status).font(.footnote).foregroundStyle(.secondary) } }
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
                DataAccessSettingsView(state: state)
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
