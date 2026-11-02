import SwiftUI
import Charts
import JoeCore

struct RootView: View {
    @Bindable var state: AppState
    var body: some View {
        TabView {
            DashboardView(state: state).tabItem { Label("概览", systemImage: "waveform.path.ecg") }
            ContextView(state: state).tabItem { Label("生活", systemImage: "leaf") }
            AssistantView(state: state).tabItem { Label("Joe", systemImage: "bubble.left.and.bubble.right") }
            SettingsView(state: state).tabItem { Label("设置", systemImage: "gearshape") }
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
                                    Label(fresh ? "最近测量" : "历史读数 · 已过期", systemImage: fresh ? "checkmark.circle" : "clock.badge.exclamationmark")
                                        .foregroundStyle(fresh ? .teal : .orange)
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(sample.glucose.formatted(.number.precision(.fractionLength(0)))).font(.system(size: 60, weight: .semibold, design: .rounded))
                                        Text("mg/dL").foregroundStyle(.secondary)
                                    }
                                    Text(sample.direction ?? "趋势未知")
                                    Text("CGM 时间：" + sample.timestamp.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                                    Text("\(max(0, Int(timeline.date.timeIntervalSince(sample.timestamp)/60))) 分钟前").font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            } else { ContentUnavailableView("暂无 CGM", systemImage: "waveform.path.ecg", description: Text("在设置中连接 Nightscout。没有数据时不会猜测血糖。")) }
                        }
                    }
                    if !state.glucose.isEmpty {
                        GroupBox("最近 6 小时 · 测量数据") {
                            Chart(state.glucose.filter { $0.timestamp > Date().addingTimeInterval(-6*3600) }) { sample in
                                LineMark(x: .value("时间", sample.timestamp), y: .value("mg/dL", sample.glucose))
                                    .foregroundStyle(.teal)
                            }.chartYScale(domain: 40...400).frame(height: 180)
                        }
                    }
                    GroupBox("本地预测") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(state.forecastStatus).font(.subheadline).foregroundStyle(.secondary)
                            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                                if let forecast = state.forecast, let latest = state.glucose.last,
                                   latest.isFresh(at: timeline.date, threshold: state.staleMinutes*60), forecast.sourceTimestamp == latest.timestamp {
                                    Text("30 分钟：\(Int(forecast.glucose30)) mg/dL")
                                    Text("60 分钟：\(Int(forecast.glucose60)) mg/dL")
                                    Text("以 CGM 时间为起点；验证集误差 P90：±\(Int(forecast.uncertainty30)) / ±\(Int(forecast.uncertainty60)) mg/dL，不是保证范围。").font(.caption)
                                    Text("缺失：" + forecast.flags.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text("研究 shadow mode；不提供胰岛素剂量或泵控制。").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("泵与餐食记录") {
                        VStack(alignment: .leading, spacing: 8) {
                            if state.treatments.isEmpty { Text("没有可见记录，不代表没有给药或进食").foregroundStyle(.secondary) }
                            ForEach(Array(state.treatments.suffix(5).reversed())) { event in
                                VStack(alignment: .leading) {
                                    Text(event.kind)
                                    Text(event.timestamp.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                    if let units = event.insulin { Text("记录：\(units.formatted()) U").font(.caption) }
                                    if let carbs = event.carbs { Text("碳水：\(carbs.formatted()) g").font(.caption) }
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("前瞻验证") {
                        VStack(alignment: .leading) {
                            Text("60 分钟已匹配：\(state.matchedCount) 条")
                            Text("MAE 30m / 60m：\(state.mae30.map { String(format: "%.1f", $0) } ?? "—") / \(state.mae60.map { String(format: "%.1f", $0) } ?? "—") mg/dL")
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
                Section("HealthKit · 仅请求读取") {
                    Button("启用步数、心率、睡眠与运动") { Task {
                        do { try await state.health.authorize(); await state.refresh() }
                        catch { status = "HealthKit 请求失败" }
                    } }
                    Button("暂停读取 HealthKit") { state.health.disable(); Task { await state.refresh() } }
                    LabeledContent("30 分钟步数", value: state.context?.steps.map { String(Int($0)) } ?? "缺失")
                    LabeledContent("心率", value: state.context?.heartRate.map { "\(Int($0)) bpm" } ?? "缺失")
                    LabeledContent("最近睡眠", value: state.context?.sleepHours.map { String(format: "%.1f 小时", $0) } ?? "缺失")
                    Text("空结果可能表示无数据、部分授权或未授权。iOS 不向 app 披露具体读取拒绝状态。").font(.caption).foregroundStyle(.secondary)
                }
                Section("日历 · 仅保存类别") {
                    Button("启用日历读取") { Task {
                        do { status = try await state.calendar.authorize() ? "日历已启用" : "日历未授权"; await state.refresh() }
                        catch { status = "日历请求失败" }
                    } }
                    Button("暂停日历读取") { UserDefaults.standard.set(false, forKey: "calendarEnabled"); Task { await state.refresh() } }
                    LabeledContent("当前", value: state.context?.calendar ?? "无可见事件 / 未授权")
                    LabeledContent("下一项", value: state.calendarSnapshot.next ?? "无可见事件")
                    if let date = state.calendarSnapshot.nextStart { Text("下一项：" + date.formatted(date: .omitted, time: .shortened)) }
                }
                Section("地点 · 低功耗") {
                    Button("启用使用期间定位") { state.location.authorize() }
                    Button("允许后台 Visits / 地理围栏（可选）") { state.location.enableBackgroundVisits() }
                    Button("获取当前位置类别") { state.location.refresh() }
                    Button("暂停定位") { state.location.disable() }
                    LabeledContent("最近类别", value: state.location.category ?? "未知")
                    Picker("命名地点", selection: $place) {
                        ForEach(["home", "school", "work", "gym", "restaurant", "other"], id: \.self) { Text($0) }
                    }
                    Button("将当前地点保存为 \(place)") { state.location.saveCurrentPlace(category: place) }
                    ForEach(state.location.places) { saved in
                        HStack { Text(saved.id); Spacer(); Button("删除") { state.location.removePlace(saved.id) } }
                    }
                    Text("只保存你主动命名地点的坐标；访问记录只保存类别和时间，不保存轨迹。后台更新由 iOS 决定。").font(.caption).foregroundStyle(.secondary)
                    if let message = state.location.message { Text(message).foregroundStyle(.orange) }
                }
                if let status { Text(status) }
            }.navigationTitle("生活 Context")
        }
    }
}

struct AssistantView: View {
    @Bindable var state: AppState
    @State private var question = "请解释当前结果"
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(state.assistant.availability).font(.caption).foregroundStyle(.secondary)
                    Text(state.reply).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding().background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    Text(state.assistantMode).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("朗读", systemImage: "speaker.wave.2") { state.speech.speak(state.reply) }
                        Button("停止", systemImage: "stop") { state.speech.stop() }
                    }
                    TextField("输入问题", text: $question, axis: .vertical).textFieldStyle(.roundedBorder)
                    Button { let text = question; Task { await state.ask(text) } } label: {
                        if state.isAnswering { ProgressView() } else { Label("询问 Joe", systemImage: "arrow.up.circle.fill") }
                    }.buttonStyle(.borderedProminent).disabled(state.isAnswering || question.isEmpty)
                }.padding()
            }.navigationTitle("与 Joe 对话")
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
                Section("Nightscout 直连") {
                    TextField("https://your-nightscout.example.com", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Picker("认证", selection: $auth) { Text("只读 access token").tag(NightscoutCredentials.Auth.token); Text("API secret SHA-1").tag(NightscoutCredentials.Auth.secretSHA1) }
                    SecureField("Token 或 SHA-1", text: $secret).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("保存并连接") { let credential = secret; secret = ""; Task { await state.configure(url: url, secret: credential, auth: auth) } }
                        .disabled(state.isRefreshing || secret.isEmpty || url.isEmpty)
                    Text(state.connected ? "凭据已保存在本机 Keychain" : "尚未配置").font(.caption)
                    if let error = state.syncError { Text(error).foregroundStyle(.orange) }
                    Text("请先关闭 Tailscale、关闭 Wi-Fi，用蜂窝网络测试 Nightscout HTTPS。URL 和凭据只存入 Keychain，不会自动读取旧 repo 的密钥。").font(.caption).foregroundStyle(.secondary)
                }
                Section("数据质量") {
                    Stepper("CGM 过期阈值：\(Int(state.staleMinutes)) 分钟", value: $state.staleMinutes, in: 5...30, step: 5)
                    Text("启动、回到前台、手动刷新与 iOS 允许的后台时机同步；不保证每五分钟唤醒。").font(.caption)
                }
                Section("研究数据 · 留在本机") {
                    Button("准备导出研究 JSON") { state.export() }.disabled(state.isRefreshing)
                    if let exportURL = state.exportURL { ShareLink("分享导出文件", item: exportURL) }
                    Text("导出包含健康记录、类别、预测和误差，不包含 Nightscout 凭据或日历标题。请自行选择保存位置。").font(.caption).foregroundStyle(.secondary)
                    Button("清除本地数据与凭据", role: .destructive) { eraseConfirmation = true }.disabled(state.isRefreshing || state.isAnswering)
                }
                Section("关于预测") {
                    Text("模型缺失、数据过期或历史不足时暂停预测。Apple 本地模型不可用时自动使用确定性解释。所有预测仅用于研究观察，不用于调整治疗。")
                    Text("Joe 不含泵控制接口。运行时无需 Mac、Python server、Tailscale、Ollama 或云端 LLM。").font(.caption)
                }
            }.navigationTitle("设置")
                .confirmationDialog("清除所有本地研究数据、地点和 Nightscout 凭据？", isPresented: $eraseConfirmation, titleVisibility: .visible) {
                    Button("清除", role: .destructive) { state.erase(); url = ""; secret = "" }
                }
        }
    }
}
