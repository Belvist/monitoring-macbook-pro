import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
import FoundationNetworking
#endif

struct DiskTarget: Identifiable {
    let label: String
    let path: String
    let size: Int64?
    var id: String { path }
}

enum Shell {
    static func output(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Read while the process runs so a large `ps` output can't block on a full pipe.
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch { return "" }
    }
}

struct MacCollector {
    static func capture() -> ResourceSnapshot {
        var s = ResourceSnapshot()
        s.timestamp = Date()
        let psRaw = Shell.output("/bin/ps", ["-ww", "-axo", "pid=,uid=,ppid=,%cpu=,rss=,command="])
        s.processes = CoreLogic.parsePS(psRaw)
        if psRaw.isEmpty { s.error = "macOS не разрешила получить список процессов" }

        // ps rss — только резидентная память: сжатая, swap и GPU-память (MPS/Metal) в неё
        // не входят, поэтому процесс на 6 ГБ выглядит как 400 МБ. MEM у top — полный
        // footprint как в Activity Monitor. top считается отдельно раз в 10 с, здесь только читаем кэш.
        let topMem = cachedFootprint()
        if !topMem.isEmpty {
            for i in s.processes.indices {
                if let m = topMem[s.processes[i].pid] { s.processes[i].memoryBytes = m }
            }
        }

        // %cpu из ps — среднее за всё время жизни процесса, для текущей нагрузки врёт.
        // Считаем по дельтам суммарного cputime между замерами, как Activity Monitor.
        let count = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let times = CoreLogic.parsePSTime(Shell.output("/bin/ps", ["-axo", "pid=,time="]))
        var deltaTotal: Double? = nil
        if let deltas = sampledCPU(processes: s.processes, times: times, cores: count) {
            for i in s.processes.indices {
                if let v = deltas[s.processes[i].pid] { s.processes[i].cpu = v }
            }
            deltaTotal = deltas.values.reduce(0, +)
        }
        s.processes.sort { $0.cpu > $1.cpu }

        let rawLsof = Shell.output("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcfn"])
        let listeners = CoreLogic.parseLsof(rawLsof)
        let byPID = Dictionary(uniqueKeysWithValues: s.processes.map { ($0.pid, $0) })
        // Раньше на каждый PID отдельный lsof — 3+ секунды на обновление. Один батч: ~25 мс.
        var cwdByPID: [Int32: String] = [:]
        let pids = Array(Set(listeners.map(\.pid))).sorted()
        if !pids.isEmpty {
            let list = pids.map(String.init).joined(separator: ",")
            cwdByPID = CoreLogic.parseLsofCWD(Shell.output("/usr/sbin/lsof",
                ["-nP", "-a", "-d", "cwd", "-p", list, "-Fn"]))
        }
        for l in listeners {
            guard let process = byPID[l.pid] else { continue }
            let cwd = cwdByPID[l.pid] ?? ""
            s.services.append(LocalService(pid: l.pid, port: l.port, address: l.address,
                processName: process.name,
                project: CoreLogic.projectName(path: cwd, processName: process.name),
                kind: CoreLogic.detectKind(process: process.name, command: process.command, port: l.port),
                command: process.command, workingDirectory: cwd,
                cpu: process.cpu, memoryBytes: process.memoryBytes,
                userOwned: process.uid == getuid()))
        }
        s.services = CoreLogic.dedupServices(s.services)

        if let deltaTotal { s.cpuPercent = min(100, deltaTotal / Double(count)) }
        else { s.cpuPercent = min(100, s.processes.reduce(0) { $0 + $1.cpu } / Double(count)) }
        s.totalRAM = Int64(ProcessInfo.processInfo.physicalMemory)
        let vm = Shell.output("/usr/bin/vm_stat", [])
        let memory = parseVM(vm, physical: s.totalRAM)
        s.usedRAM = memory.used
        s.compressedRAM = memory.compressed
        s.swapRAM = parseSwap(Shell.output("/usr/sbin/sysctl", ["-n", "vm.swapusage"]))
        let traffic = parseNetstat(Shell.output("/usr/sbin/netstat", ["-ibn"]))
        s.networkReceived = traffic.received
        s.networkSent = traffic.sent
        if let disk = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()) {
            s.diskTotal = (disk[.systemSize] as? NSNumber)?.int64Value ?? 0
            s.diskFree = (disk[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        }
        return s
    }

    private static let cpuLock = NSLock()
    private static var cpuPrevious: (at: Date, times: [Int32: (time: Double, command: String)])? = nil

    /// Возвращает per-core % по дельтам cputime или nil на первом замере (тогда caller берёт ps %cpu).
    static func sampledCPU(processes: [ProcessInfoRow], times: [Int32: Double], cores: Int) -> [Int32: Double]? {
        let now = Date()
        var current: [Int32: (time: Double, command: String)] = [:]
        current.reserveCapacity(processes.count)
        for row in processes {
            guard let t = times[row.pid] else { continue }
            current[row.pid] = (t, row.command)
        }
        cpuLock.lock()
        defer { cpuLock.unlock(); cpuPrevious = (now, current) }
        guard let prev = cpuPrevious else { return nil }
        let wall = now.timeIntervalSince(prev.at)
        guard wall > 0.5 else { return nil }
        return CoreLogic.deltaCPU(current: current, previous: prev.times, wall: wall, cores: cores)
    }

    static func parseVM(_ raw: String, physical: Int64) -> (used: Int64, compressed: Int64) {
        let size: Int64
        if let re = try? NSRegularExpression(pattern: #"page size of\s+(\d+)\s+bytes"#),
           let m = re.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
           let r = Range(m.range(at: 1), in: raw), let v = Int64(raw[r]) { size = v }
        else { size = 16384 }
        var counters: [String: Int64] = [:]
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count != 2 { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let number = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: " .\t"))
            if let pages = Int64(number) { counters[key] = pages }
        }
        // Как Activity Monitor: занято = active + wired + compressed.
        // Inactive/speculative — это файловый кэш, он считается отдельно, а не занятой памятью.
        let used = ((counters["Pages active"] ?? 0) + (counters["Pages wired down"] ?? 0)
            + (counters["Pages occupied by compressor"] ?? 0)) * size
        let compressed = (counters["Pages occupied by compressor"] ?? 0) * size
        guard !raw.isEmpty, physical > 0 else { return (0, 0) }
        return (max(0, min(physical, used)), compressed)
    }

    static func parseSwap(_ raw: String) -> Int64 {
        guard let re = try? NSRegularExpression(pattern: #"used\s*=\s*([\d.,]+)([KMGT])"#, options: .caseInsensitive),
              let match = re.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let r = Range(match.range(at: 1), in: raw),
              let ur = Range(match.range(at: 2), in: raw),
              let value = Double(raw[r].replacingOccurrences(of: ",", with: ".")) else { return 0 }
        let mul: Double = ["K": 1024, "M": 1048576, "G": 1073741824, "T": 1099511627776][String(raw[ur]).uppercased()] ?? 1
        return Int64(value * mul)
    }

    static func parseNetstat(_ raw: String) -> (received: Int64, sent: Int64) {
        let rows = raw.split(separator: "\n").map {
            $0.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        }
        guard let header = rows.first,
              let rx = header.firstIndex(of: "Ibytes"),
              let tx = header.firstIndex(of: "Obytes") else { return (0, 0) }
        var received: Int64 = 0
        var sent: Int64 = 0
        for cells in rows.dropFirst() {
            // Один link-row на интерфейс; lo0 исключаем, остальное (en*, bridge, utun/VPN) считаем.
            guard cells.count > max(rx, tx), let device = cells.first,
                  device != "lo0",
                  cells.contains(where: { $0.hasPrefix("<Link#") }),
                  let rin = Int64(cells[rx]), let rout = Int64(cells[tx]) else { continue }
            received += max(0, rin)
            sent += max(0, rout)
        }
        return (received, sent)
    }

    static func interestingFiles() -> [DiskTarget] {
        let home = NSHomeDirectory()
        let paths: [(String, String)] = [
            ("Docker — виртуальный диск", "/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"),
            ("Docker — альтернативный диск", "/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.qcow2"),
            ("Модели Ollama", "/.ollama/models"),
            ("Кэш Hugging Face", "/.cache/huggingface"),
            ("Кэш PyTorch", "/.cache/torch")
        ]
        return paths.compactMap { title, relative in
            let path = home + relative
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
            let size = isDir.boolValue ? nil : ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.int64Value
            return DiskTarget(label: title, path: path, size: size)
        }
    }

    private static let footprintLock = NSLock()
    private static var footprintCache: [Int32: Int64] = [:]
    private static var footprintAt = Date.distantPast

    /// Пересчитывает footprint раз в 10 с в фоне, чтобы не тормозить обычное обновление метрик.
    static func refreshFootprint(force: Bool = false) {
        let now = Date()
        if !force && now.timeIntervalSince(footprintAt) < 10 { return }
        let rows = CoreLogic.parseTopMem(Shell.output("/usr/bin/top",
            ["-l", "1", "-n", "1200", "-o", "mem", "-stats", "pid,mem"]))
        guard !rows.isEmpty else { return }
        footprintLock.lock()
        footprintCache = rows
        footprintAt = Date()
        footprintLock.unlock()
    }

    static func cachedFootprint() -> [Int32: Int64] {
        footprintLock.lock()
        defer { footprintLock.unlock() }
        return footprintCache
    }

    // Одна сессия на всё время работы приложения: создавать её на каждую пробу дорого.
    private static let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.9
        config.timeoutIntervalForResource = 1.1
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()

    static func probeWebsite(service: LocalService) -> SiteProbe {
        guard (1...65535).contains(service.port), let url = service.probeURL else {
            return SiteProbe(httpStatus: nil, title: nil, detail: "Неверный порт")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("MacScope/1.0", forHTTPHeaderField: "User-Agent")
        let box = ProbeResultBox()
        let done = DispatchSemaphore(value: 0)
        let task = probeSession.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let response = response as? HTTPURLResponse {
                let body = String(data: (data ?? Data()).prefix(128_000), encoding: .utf8) ?? ""
                let title = CoreLogic.htmlTitle(body)
                box.set(SiteProbe(httpStatus: response.statusCode, title: title,
                                  detail: "HTTP \(response.statusCode)"))
            } else if let error = error as NSError?, error.code == NSURLErrorTimedOut {
                box.set(SiteProbe(httpStatus: nil, title: nil, detail: "Нет ответа за 1 с"))
            } else {
                box.set(SiteProbe(httpStatus: nil, title: nil, detail: "Сокет закрыт / не HTTP"))
            }
        }
        task.resume()
        guard done.wait(timeout: .now() + 1.3) == .success else {
            task.cancel()
            return SiteProbe(httpStatus: nil, title: nil, detail: "Нет ответа за 1 с")
        }
        return box.get()
    }

    private final class ProbeResultBox: @unchecked Sendable {
        private var result = SiteProbe(httpStatus: nil, title: nil, detail: "Не HTTP или нет ответа")
        private let lock = NSLock()
        func set(_ probe: SiteProbe) { lock.lock(); result = probe; lock.unlock() }
        func get() -> SiteProbe { lock.lock(); defer { lock.unlock() }; return result }
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil) // never follow a local server redirect to a remote domain
        }
    }

    static func canKill(pid: Int32, uid: UInt32) -> Bool {
        pid > 1 && pid != getpid() && uid == getuid()
    }

    static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    static func zombiePIDs(_ pids: [Int32]) -> Set<Int32> {
        guard !pids.isEmpty else { return [] }
        let wanted = Set(pids)
        let raw = Shell.output("/bin/ps", ["-axo", "pid=,stat="])
        var zombies: Set<Int32> = []
        for line in raw.split(separator: "\n") {
            let parts = line.split(omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2, let pid = Int32(parts[0]), wanted.contains(pid),
                  parts[1].uppercased().contains("Z") else { continue }
            zombies.insert(pid)
        }
        return zombies
    }

    /// Полное снятие задачи: SIGTERM всему дереву, несдавшимся — SIGKILL.
    /// Возвращает nil при успехе (зомби считаются успехом: они уже мертвы), иначе текст ошибки.
    static func killTree(pid: Int32, command: String) -> String? {
        let selfPID = getpid()
        guard pid > 1, pid != selfPID else { return "Этот процесс нельзя остановить из MacScope." }
        let myUID = getuid()
        // Дерево строим по свежему снимку, корень сверяем с командой — защита от reused PID.
        let rows = CoreLogic.parsePS(Shell.output("/bin/ps", ["-ww", "-axo", "pid=,uid=,ppid=,%cpu=,rss=,command="]))
        guard let root = rows.first(where: { $0.pid == pid }),
              root.uid == myUID, root.command == command else {
            return "Процесс уже завершился или изменился. Обнови список."
        }
        let tree = CoreLogic.processTree(rootPID: pid, rows: rows)
            .filter { $0.uid == myUID && $0.pid != selfPID }
        guard !tree.isEmpty else { return "Процесс уже завершился." }
        for p in tree { kill(p.pid, SIGTERM) }
        Thread.sleep(forTimeInterval: 1.2)
        var alive = Set(tree.map(\.pid).filter { isAlive($0) })
        if !alive.isEmpty {
            // Детей добиваем первыми, корень последним.
            for p in tree.reversed() where alive.contains(p.pid) { kill(p.pid, SIGKILL) }
            Thread.sleep(forTimeInterval: 0.5)
            alive = Set(tree.map(\.pid).filter { isAlive($0) })
        }
        let still = alive.subtracting(zombiePIDs(Array(alive)))
        guard !still.isEmpty else { return nil }
        let names = tree.filter { still.contains($0.pid) }.prefix(4)
            .map { "\($0.name) (\($0.pid))" }.joined(separator: ", ")
        return "Не удалось завершить: \(names). Возможно, висит в дисковом ожидании — уйдёт сам или после перезагрузки."
    }

    static func terminate(_ service: LocalService) -> String? {
        guard service.userOwned, service.pid > 1, service.pid != getpid() else { return "Этот процесс нельзя остановить из MacScope." }
        // PID might have been reused since the last refresh; verify ownership and command.
        let latest = CoreLogic.parsePS(Shell.output("/bin/ps", ["-ww", "-p", "\(service.pid)", "-o", "pid=,uid=,ppid=,%cpu=,rss=,command="]))
        guard let existing = latest.first, existing.uid == getuid(), existing.command == service.command else {
            return "Процесс уже завершился или изменился. Обнови список."
        }
        if kill(service.pid, SIGTERM) != 0 { return "macOS не разрешила остановить процесс (код \(errno))." }
        return nil
    }
}
