#if os(macOS)
import SwiftUI
import AppKit
import Combine

private enum Theme {
    // Тёмная монохромная тема: плоские заливки, белый текст и иконки, без градиентов.
    static let background = Color(red: 0.105, green: 0.105, blue: 0.115)
    static let sidebar = Color(red: 0.075, green: 0.075, blue: 0.085)
    static let card = Color(red: 0.16, green: 0.16, blue: 0.18)
    static let bar = Color(red: 0.13, green: 0.13, blue: 0.145)
    static let tile = Color.white.opacity(0.09)
    static let ink = Color.white
    static let secondary = Color.white.opacity(0.55)
    static let accent = Color.white
    static let border = Color.white.opacity(0.12)
    static let muted = Color.white.opacity(0.75)
}

private enum Tab: String, CaseIterable, Identifiable {
    case overview = "Обзор"
    case services = "Сайты и порты"
    case processes = "Процессы"
    case storage = "Память и диск"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .services: return "network"
        case .processes: return "cpu"
        case .storage: return "internaldrive"
        }
    }
}

@MainActor
private final class MonitorStore: ObservableObject {
    @Published var snapshot = ResourceSnapshot()
    @Published var probes: [String: SiteProbe] = [:]
    @Published var loading = false
    @Published var cpuHistory: [Double] = []
    @Published var ramHistory: [Double] = []
    @Published var networkDown: Int64 = 0
    @Published var networkUp: Int64 = 0
    @Published var names: [String: String] = UserDefaults.standard.dictionary(forKey: "portNames") as? [String: String] ?? [:]
    @Published var errorMessage: String? = nil
    private var lastProbed = Date.distantPast
    private var scanning = false

    func refresh() {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = MacCollector.capture()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let seconds = max(1, data.timestamp.timeIntervalSince(self.snapshot.timestamp))
                if self.snapshot.networkReceived > 0 && data.networkReceived >= self.snapshot.networkReceived {
                    self.networkDown = Int64(Double(data.networkReceived - self.snapshot.networkReceived) / seconds)
                }
                if self.snapshot.networkSent > 0 && data.networkSent >= self.snapshot.networkSent {
                    self.networkUp = Int64(Double(data.networkSent - self.snapshot.networkSent) / seconds)
                }
                self.snapshot = data
                self.cpuHistory = Array((self.cpuHistory + [data.cpuPercent]).suffix(45))
                let ram = data.totalRAM > 0 ? Double(data.usedRAM) / Double(data.totalRAM) * 100 : 0
                self.ramHistory = Array((self.ramHistory + [ram]).suffix(45))
                self.loading = false
                self.startProbingIfNeeded()
            }
        }
    }

    private func startProbingIfNeeded() {
        guard !scanning && Date().timeIntervalSince(lastProbed) > 25 else { return }
        scanning = true
        lastProbed = Date()
        let services = Array(snapshot.services.prefix(20))
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for item in services {
                let probe = MacCollector.probeWebsite(service: item)
                DispatchQueue.main.async { [weak self] in
                    self?.probes[item.id] = probe
                }
            }
            DispatchQueue.main.async { [weak self] in self?.scanning = false }
        }
    }

    func displayName(_ service: LocalService) -> String {
        if let edited = names[String(service.port)], !edited.isEmpty { return edited }
        if let title = probes[service.id]?.title, !title.isEmpty { return title }
        return service.defaultName
    }

    func saveName(_ name: String, port: Int) {
        let new = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if new.isEmpty { names.removeValue(forKey: String(port)) }
        else { names[String(port)] = new }
        UserDefaults.standard.set(names, forKey: "portNames")
    }

    func stop(_ service: LocalService) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = MacCollector.terminate(service)
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = result
                self?.refresh()
            }
        }
    }
}

@main
struct MacScopeNativeApp: App {
    @StateObject private var store = MonitorStore()
    var body: some Scene {
        WindowGroup("MacScope") {
            MacScopeWindow(store: store)
                .frame(minWidth: 1000, minHeight: 660)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1220, height: 790)
        .windowStyle(.hiddenTitleBar)
        Settings { EmptyView() }
    }
}

private struct MacScopeWindow: View {
    @ObservedObject var store: MonitorStore
    @State private var tab: Tab = .overview
    @State private var search = ""
    @State private var selectedService: String? = nil
    @State private var pendingStop: LocalService? = nil
    @State private var showStopAlert = false
    @State private var renameService: LocalService? = nil
    @State private var renameDraft = ""
    @State private var showErrorAlert = false
    @State private var diskTargets: [DiskTarget] = []
    private let timer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    private var services: [LocalService] {
        guard !search.isEmpty && tab == .services else { return store.snapshot.services }
        return store.snapshot.services.filter { service in
            "\(store.displayName(service)) \(service.processName) \(service.port) \(service.workingDirectory)".localizedCaseInsensitiveContains(search)
        }
    }
    private var processes: [ProcessInfoRow] {
        let all = store.snapshot.processes
        return (search.isEmpty || tab != .processes ? all : all.filter {
            "\($0.name) \($0.command) \($0.pid)".localizedCaseInsensitiveContains(search)
        }).prefix(150).map { $0 }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.border).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                topbar
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch tab {
                        case .overview: overview
                        case .services: servicesPage
                        case .processes: processPage
                        case .storage: storagePage
                        }
                    }
                    .padding(30)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Theme.background)
            }
        }
        .background(Theme.background)
        .onAppear { store.refresh(); diskTargets = MacCollector.interestingFiles() }
        .onReceive(timer) { _ in store.refresh() }
        .alert("Остановить процесс?", isPresented: $showStopAlert) {
            Button("Отмена", role: .cancel) { pendingStop = nil }
            Button("Остановить", role: .destructive) {
                if let service = pendingStop { store.stop(service) }
                pendingStop = nil
            }
        } message: {
            Text("Процесс \(pendingStop?.processName ?? "") (PID \(pendingStop?.pid ?? 0)) будет завершён через SIGTERM. Все его сервисы перестанут работать. Несохранённые данные могут быть потеряны.")
        }
        .sheet(item: $renameService) { service in
            VStack(alignment: .leading, spacing: 16) {
                Text("Название сервиса").font(.title2.bold())
                Text("Как показывать этот порт в MacScope? Название сохраняется на твоём Mac.")
                    .foregroundStyle(Theme.secondary)
                TextField("Название проекта", text: $renameDraft).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Отмена") { renameService = nil }
                    Button("Сохранить") { store.saveName(renameDraft, port: service.port); renameService = nil }
                        .buttonStyle(.borderedProminent).tint(.white)
                }
            }
            .padding(25).frame(width: 440)
        }
        .onChange(of: store.errorMessage) { newValue in showErrorAlert = newValue != nil }
        .alert("Не удалось выполнить действие", isPresented: $showErrorAlert) {
            Button("Понятно") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.system(size: 21, weight: .semibold)).foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Theme.tile, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 1) {
                    Text("MacScope").font(.system(size: 19, weight: .bold, design: .rounded))
                    Text("Локальный монитор").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                }
            }
            .padding(.horizontal, 20).padding(.top, 36).padding(.bottom, 37)
            Text("РАБОЧЕЕ ПРОСТРАНСТВО").font(.system(size: 10, weight: .bold))
                .tracking(1.2).foregroundStyle(Theme.secondary)
                .padding(.horizontal, 22).padding(.bottom, 10)
            ForEach(Tab.allCases) { item in
                Button {
                    tab = item; search = ""
                    if item == .storage { diskTargets = MacCollector.interestingFiles() }
                } label: {
                    HStack(spacing: 13) {
                        Image(systemName: item.symbol).frame(width: 18)
                        Text(item.rawValue)
                        Spacer()
                        if item == .services {
                            Text("\(store.snapshot.services.count)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(tab == item ? Theme.accent : Theme.secondary)
                        }
                    }
                    .font(.system(size: 13, weight: tab == item ? .semibold : .medium))
                    .foregroundStyle(tab == item ? Theme.accent : Theme.ink)
                    .padding(.horizontal, 13).frame(height: 41)
                    .background(tab == item ? Color.white.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12).padding(.bottom, 5)
            }
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(Theme.muted).frame(width: 7, height: 7)
                Text("Только этот Mac")
            }.font(.system(size: 11)).foregroundStyle(Theme.secondary)
                .padding(.horizontal, 22).padding(.bottom, 12)
            Text("Без облака и телеметрии")
                .font(.system(size: 10)).foregroundStyle(Theme.secondary)
                .padding(.horizontal, 22).padding(.bottom, 24)
        }
        .frame(width: 228).background(Theme.sidebar)
    }

    private var topbar: some View {
        HStack(spacing: 12) {
            Text(tab.rawValue).font(.system(size: 16, weight: .semibold))
            Spacer()
            Text("Обновлено \(store.snapshot.timestamp.formatted(date: .omitted, time: .standard))")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            if store.loading { ProgressView().controlSize(.small) }
            Button { store.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .help("Обновить мониторинг")
        }
        .padding(.horizontal, 30).frame(height: 58).background(Theme.bar)
        .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Всё, что работает на твоём Mac").font(.system(size: 27, weight: .bold, design: .rounded))
                Text("Нагрузка, приложения и локальные серверы — без загадочных номеров портов.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
            HStack(spacing: 14) {
                MetricCard(symbol: "cpu", title: "Процессор", value: String(format: "%.0f%%", store.snapshot.cpuPercent), footer: "Всего на всех ядрах · прибл.", progress: store.snapshot.cpuPercent / 100)
                MetricCard(symbol: "memorychip", title: "Оперативная память", value: CoreLogic.bytes(store.snapshot.usedRAM), footer: "из \(CoreLogic.bytes(store.snapshot.totalRAM)) · оценка", progress: ratio(store.snapshot.usedRAM, store.snapshot.totalRAM))
                MetricCard(symbol: "arrow.left.arrow.right", title: "Swap (SSD)", value: CoreLogic.bytes(store.snapshot.swapRAM), footer: "Память, выгруженная на диск", progress: nil)
                MetricCard(symbol: "network", title: "Локальные сервисы", value: String(store.snapshot.services.count), footer: "Открытых TCP-портов", progress: nil)
            }
            HStack(spacing: 14) {
                panel(title: "Нагрузка CPU", subtitle: "Последние 3 минуты · все ядра") {
                    HStack(alignment: .firstTextBaseline) {
                        Text(String(format: "%.0f%%", store.snapshot.cpuPercent)).font(.system(size: 19, weight: .bold))
                        Text("занято").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                    Sparkline(values: store.cpuHistory, color: Theme.accent).frame(height: 65)
                }
                panel(title: "Загрузка RAM", subtitle: "Последние 3 минуты · оценка") {
                    HStack(alignment: .firstTextBaseline) {
                        Text(CoreLogic.bytes(store.snapshot.usedRAM)).font(.system(size: 19, weight: .bold))
                        Text("из \(CoreLogic.bytes(store.snapshot.totalRAM))").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                    Sparkline(values: store.ramHistory, color: Theme.muted).frame(height: 65)
                }
                panel(title: "Сеть", subtitle: "Трафик сетевых интерфейсов en*") {
                    HStack {
                        Image(systemName: "arrow.down").foregroundStyle(Theme.muted)
                        Text(CoreLogic.bytes(store.networkDown) + "/с")
                    }.font(.system(size: 14, weight: .semibold))
                    HStack {
                        Image(systemName: "arrow.up").foregroundStyle(Theme.accent)
                        Text(CoreLogic.bytes(store.networkUp) + "/с")
                    }.font(.system(size: 14, weight: .semibold))
                    Text("Скорость приблизительная").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                panel(title: "Сайты и серверы", subtitle: "Что именно слушает локальные порты") {
                    if store.snapshot.services.isEmpty {
                        blank("Активных TCP-серверов пока не найдено")
                    } else {
                        ForEach(store.snapshot.services.prefix(7)) { service in
                            HStack(spacing: 11) {
                                serviceIcon(service).frame(width: 33, height: 33)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(store.displayName(service)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                    Text(service.kind.rawValue).font(.system(size: 10)).foregroundStyle(Theme.secondary)
                                }
                                Spacer()
                                Text(":\(service.port)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary)
                            }.padding(.vertical, 7)
                            Divider()
                        }
                        Button("Открыть все порты →") { tab = .services }
                            .font(.system(size: 12, weight: .semibold)).buttonStyle(.plain)
                            .foregroundStyle(Theme.accent).padding(.top, 8)
                    }
                }
                panel(title: "Больше всего ресурсов", subtitle: "Процессы с максимальной загрузкой CPU") {
                    ForEach(store.snapshot.processes.prefix(7)) { process in
                        HStack(spacing: 10) {
                            processIcon(process, size: 28)
                            Text(process.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer()
                            Text(String(format: "%.1f%%", process.cpu)).font(.system(size: 11, design: .monospaced)).frame(width: 60, alignment: .trailing)
                            Text(CoreLogic.bytes(process.memoryBytes, digits: 0)).font(.system(size: 11, design: .monospaced)).frame(width: 73, alignment: .trailing).foregroundStyle(Theme.secondary)
                        }.padding(.vertical, 10)
                        Divider()
                    }
                    Button("Все процессы →") { tab = .processes }
                        .font(.system(size: 12, weight: .semibold)).buttonStyle(.plain)
                        .foregroundStyle(Theme.accent).padding(.top, 8)
                }
            }
            if let error = store.snapshot.error { Text(error).font(.callout).foregroundStyle(.red) }
        }
    }

    private var servicesPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Локальные сайты и сервисы").font(.system(size: 27, weight: .bold, design: .rounded))
                    Text("Порт, сайт, имя проекта, команда запуска и сколько ресурсов расходует сервер.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                searchField
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 0) {
                    HStack {
                        Text("НАЙДЕНО \(services.count)").font(.system(size: 10, weight: .bold)).tracking(1.1).foregroundStyle(Theme.secondary)
                        Spacer()
                        Text("ПОРТ").font(.system(size: 10, weight: .bold)).tracking(1.1).foregroundStyle(Theme.secondary)
                    }.padding(15)
                    Divider()
                    if services.isEmpty { blank("Ничего не найдено") }
                    ForEach(services) { service in
                        Button { selectedService = service.id } label: {
                            HStack(spacing: 11) {
                                serviceIcon(service)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(store.displayName(service)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                    HStack(spacing: 5) {
                                        Text(service.processName)
                                        if let probe = store.probes[service.id], probe.isHTTP {
                                            Text("· \(probe.detail)").foregroundStyle(Theme.muted)
                                        }
                                    }.font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                Text(":\(service.port)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary)
                                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Theme.secondary)
                            }
                            .padding(13)
                            .background((selectedService ?? services.first?.id) == service.id ? Theme.accent.opacity(0.075) : Color.clear)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Divider()
                    }
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(Theme.border, lineWidth: 0.7))
                .frame(minWidth: 330, maxWidth: .infinity)

                if let item = services.first(where: { $0.id == (selectedService ?? services.first?.id) }) {
                    serviceDetails(item).frame(minWidth: 310, maxWidth: .infinity)
                } else { blank("Выбери сервис").frame(maxWidth: .infinity) }
            }
            Text("Названия веб-страниц определяются через HTTP на 127.0.0.1. Не-HTTP сервисы остаются отдельными типами. Если несколько процессов используют один порт, отображается владелец LISTEN-сокета.")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
    }

    private func serviceDetails(_ service: LocalService) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 12) {
                serviceIcon(service).frame(width: 39, height: 39)
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.displayName(service)).font(.system(size: 18, weight: .bold)).lineLimit(2)
                    Text(store.probes[service.id]?.isHTTP == true ? "Локальная веб-страница" : service.kind.rawValue)
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                Spacer()
            }
            Divider()
            detail("Адрес", "\(service.address):\(service.port)")
            detail("Процесс", "\(service.processName) · PID \(service.pid)")
            detail("Владелец", service.userOwned ? "Твой пользователь" : "Другой пользователь / система")
            detail("CPU", String(format: "%.1f%% одного ядра", service.cpu))
            detail("RAM", CoreLogic.bytes(service.memoryBytes))
            detail("Проверка HTTP", store.probes[service.id]?.detail ?? "Проверяется…")
            if !service.workingDirectory.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ПАПКА ПРОЕКТА").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(Theme.secondary)
                    Text(service.workingDirectory).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .lineLimit(3)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("КОМАНДА ЗАПУСКА").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(Theme.secondary)
                Text(CoreLogic.safeCommand(service.command)).font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled).lineLimit(5)
            }
            Divider()
            HStack(spacing: 8) {
                Button {
                    if let url = service.pageURL { NSWorkspace.shared.open(url) }
                } label: { Label("Открыть сайт", systemImage: "arrow.up.right.square") }
                .buttonStyle(.borderedProminent).tint(.white)
                .disabled(store.probes[service.id]?.isHTTP != true)
                Button { renameDraft = store.names[String(service.port)] ?? service.defaultName; renameService = service } label: {
                    Image(systemName: "pencil")
                }.buttonStyle(.bordered).help("Переименовать порт")
                Spacer(minLength: 0)
                Button(role: .destructive) { pendingStop = service; showStopAlert = true } label: {
                    Label("Стоп", systemImage: "stop.circle")
                }.buttonStyle(.bordered).disabled(!service.userOwned)
            }.controlSize(.small)
        }
        .padding(20)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(Theme.border, lineWidth: 0.7))
    }

    private var processPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Все процессы").font(.system(size: 27, weight: .bold, design: .rounded))
                    Text("Настоящие процессы macOS, отсортированные по CPU. 100% = одно ядро.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                searchField
            }
            VStack(spacing: 0) {
                HStack {
                    Text("ПРОЦЕСС").frame(maxWidth: .infinity, alignment: .leading)
                    Text("PID").frame(width: 70, alignment: .trailing)
                    Text("CPU").frame(width: 80, alignment: .trailing)
                    Text("RAM").frame(width: 100, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(Theme.secondary)
                .padding(15)
                Divider()
                ForEach(processes) { process in
                    HStack(spacing: 12) {
                        processIcon(process)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(process.name).font(.system(size: 12, weight: .semibold))
                            Text(CoreLogic.safeCommand(process.command)).font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text(String(process.pid)).frame(width: 70, alignment: .trailing)
                        Text(String(format: "%.1f%%", process.cpu)).frame(width: 80, alignment: .trailing)
                        Text(CoreLogic.bytes(process.memoryBytes)).frame(width: 100, alignment: .trailing)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 15).padding(.vertical, 10)
                    Divider()
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(Theme.border, lineWidth: 0.7))
        }
    }

    private var storagePage: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Память и хранилище").font(.system(size: 27, weight: .bold, design: .rounded))
                Text("Что занято в оперативной памяти и какие файлы разработки могут съедать SSD.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            HStack(spacing: 14) {
                MetricCard(symbol: "memorychip", title: "RAM занято (оценка)", value: CoreLogic.bytes(store.snapshot.usedRAM), footer: "из \(CoreLogic.bytes(store.snapshot.totalRAM))", progress: ratio(store.snapshot.usedRAM, store.snapshot.totalRAM))
                MetricCard(symbol: "archivebox", title: "Сжатая память", value: CoreLogic.bytes(store.snapshot.compressedRAM), footer: "Физические страницы компрессора", progress: nil)
                MetricCard(symbol: "arrow.left.arrow.right", title: "Swap", value: CoreLogic.bytes(store.snapshot.swapRAM), footer: "Используется на SSD", progress: nil)
            }
            panel(title: "SSD", subtitle: "Общий размер и свободное пространство") {
                HStack(alignment: .firstTextBaseline) {
                    Text(CoreLogic.bytes(max(0, store.snapshot.diskTotal - store.snapshot.diskFree)))
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                    Text("занято из \(CoreLogic.bytes(store.snapshot.diskTotal))").foregroundStyle(Theme.secondary)
                    Spacer()
                    Text("Свободно \(CoreLogic.bytes(store.snapshot.diskFree))").fontWeight(.medium)
                }.font(.system(size: 12))
                ProgressView(value: ratio(max(0, store.snapshot.diskTotal - store.snapshot.diskFree), store.snapshot.diskTotal))
                    .tint(Theme.accent).padding(.vertical, 6)
            }
            panel(title: "Данные разработчика", subtitle: "Известные большие файлы и папки — без удаления автоматически") {
                if diskTargets.isEmpty { blank("Крупные технические файлы не найдены по стандартным путям") }
                ForEach(diskTargets) { target in
                    HStack(spacing: 12) {
                        Image(systemName: "doc.zipper").foregroundStyle(Theme.accent).frame(width: 25)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(target.label).font(.system(size: 12, weight: .semibold))
                            Text(target.path).font(.system(size: 10, design: .monospaced)).lineLimit(1)
                                .truncationMode(.middle).foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        Text(target.size.map { CoreLogic.bytes($0) } ?? "Папка").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target.path)]) }
                            .buttonStyle(.bordered).controlSize(.small)
                    }.padding(.vertical, 7)
                    Divider()
                }
            }
            Text("Для больших папок размер не рассчитывается автоматически: рекурсивное сканирование может сильно нагружать SSD. MacScope ничего не удаляет.")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
            TextField("Название, порт или PID", text: $search).textFieldStyle(.plain)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12).frame(width: 245, height: 34)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
    }

    private func serviceIcon(_ service: LocalService) -> some View {
        let http = store.probes[service.id]?.isHTTP == true
        let kind = http ? ServiceKind.website : service.kind
        let icon: String = kind == .website ? "globe" : (kind == .database ? "externaldrive" : "server.rack")
        return Image(systemName: icon)
            .font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.ink)
            .frame(width: 38, height: 38)
            .background(Theme.tile, in: RoundedRectangle(cornerRadius: 10))
    }

    private func processIcon(_ process: ProcessInfoRow, size: CGFloat = 30) -> some View {
        Image(systemName: ProcessIcon.symbol(name: process.name, command: process.command))
            .font(.system(size: size * 0.45, weight: .medium)).foregroundStyle(Theme.ink)
            .frame(width: size, height: size)
            .background(Theme.tile, in: RoundedRectangle(cornerRadius: 8))
    }

    private enum ProcessIcon {
        // Подбор иконки по имени и команде: только штатные SF Symbols, без картинок.
        private static let rules: [([String], String)] = [
            (["safari", "chrome", "chromium", "firefox", "arc", "edge", "opera", "brave", "vivaldi"], "globe"),
            (["terminal", "iterm", "alacritty", "kitty", "wezterm", "tmux", "zsh", "bash", "fish", "dash"], "terminal"),
            (["xcode", "vscode", "cursor", "sublime", "vim", "nvim", "neovim", "emacs", "zed", "intellij", "pycharm", "webstorm", "goland", "textmate", "nova", "node", "deno", "bun", "python", "ruby", "java", "cargo", "rustc", "php", "perl", "dotnet", "swift", "code"], "chevron.left.forwardslash.chevron.right"),
            (["postgres", "mysql", "mariadb", "mongo", "redis", "elasticsearch", "sqlite", "clickhouse", "rabbitmq", "kafka", "cassandra", "valkey"], "externaldrive"),
            (["docker", "containerd", "colima", "podman", "nerdctl"], "shippingbox"),
            (["nginx", "apache", "httpd", "caddy", "traefik", "qemu", "utm", "parallels", "vmware", "virtualbox", "vagrant", "minikube", "kubectl"], "server.rack"),
            (["mail", "outlook", "thunderbird"], "envelope"),
            (["facetime", "zoom", "teams", "webex"], "video"),
            (["telegram", "discord", "slack", "skype", "whatsapp", "messages"], "message"),
            (["music", "spotify", "podcasts", "itunes"], "music.note"),
            (["vlc", "iina", "mpv", "quicktime"], "play.tv"),
            (["photos", "photo"], "photo"),
            (["preview", "pages", "numbers", "keynote", "textedit", "acrobat"], "doc.text"),
            (["windowserver"], "display"),
            (["loginwindow"], "person"),
            (["finder"], "folder"),
            (["dropbox", "googledrive", "onedrive", "bird", "cloudd", "fileproviderd"], "arrow.triangle.2.circlepath"),
            (["vpn", "wireguard", "tailscale", "snitch", "defender", "antivirus", "crowdstrike", "sentinelone"], "lock.shield"),
            (["installer", "softwareupdate", "appstore", "mas"], "arrow.down.circle"),
            (["steam"], "gamecontroller"),
            (["kernel_task", "launchd", "syslogd", "configd", "trustd", "opendirectoryd", "mds", "mdworker", "revisiond", "diskarbitrationd", "securityd", "coreaudiod", "bluetoothd", "airportd", "locationd", "spindump", "reportcrash", "powerd", "hidd"], "gearshape"),
        ]

        static func symbol(name: String, command: String) -> String {
            let text = "\(name) \(command)".lowercased()
            for (keys, icon) in rules {
                for key in keys where text.contains(key) { return icon }
            }
            return "app"
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).foregroundStyle(Theme.secondary).frame(width: 100, alignment: .leading)
            Text(value).foregroundStyle(Theme.ink).lineLimit(2).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 11))
    }

    private func panel<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title).font(.system(size: 15, weight: .bold))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.secondary).padding(.top, -9)
            content()
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(Theme.border, lineWidth: 0.7))
    }

    private func blank(_ message: String) -> some View {
        Text(message).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, minHeight: 110)
    }

    private func ratio(_ value: Int64, _ total: Int64) -> Double {
        total > 0 ? min(1, max(0, Double(value) / Double(total))) : 0
    }
}

private struct MetricCard: View {
    let symbol: String
    let title: String
    let value: String
    let footer: String
    let progress: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                Spacer(minLength: 0)
                Image(systemName: symbol).foregroundStyle(Theme.accent)
            }
            Text(value).font(.system(size: 24, weight: .bold, design: .rounded)).minimumScaleFactor(0.75).lineLimit(1)
            if let progress {
                ProgressView(value: progress).tint(Theme.accent)
            } else { Spacer().frame(height: 4) }
            Text(footer).font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading).frame(height: 108)
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(Theme.border, lineWidth: 0.7))
    }
}
#endif

#if os(macOS)
private struct Sparkline: View {
    let values: [Double]
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let series = values.isEmpty ? [0] : values
                let width = geometry.size.width
                let height = geometry.size.height
                for (index, value) in series.enumerated() {
                    let x = series.count > 1 ? width * CGFloat(index) / CGFloat(series.count - 1) : 0
                    let y = height * (1 - CGFloat(min(100, max(0, value))) / 100)
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}
#endif
