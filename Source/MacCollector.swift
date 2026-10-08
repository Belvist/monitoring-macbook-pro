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
        s.processes.sort { $0.cpu > $1.cpu }

        let rawLsof = Shell.output("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcfn"])
        let listeners = CoreLogic.parseLsof(rawLsof)
        let byPID = Dictionary(uniqueKeysWithValues: s.processes.map { ($0.pid, $0) })
        var cachedCWD: [Int32: String] = [:]
        for l in listeners.prefix(180) {
            guard let process = byPID[l.pid] else { continue }
            let cwd: String
            if let cached = cachedCWD[l.pid] { cwd = cached }
            else {
                let reply = Shell.output("/usr/sbin/lsof", ["-nP", "-a", "-p", String(l.pid), "-d", "cwd", "-Fn"])
                cwd = reply.split(separator: "\n").map(String.init).first(where: { $0.hasPrefix("n/") }).map { String($0.dropFirst()) } ?? ""
                cachedCWD[l.pid] = cwd
            }
            s.services.append(LocalService(pid: l.pid, port: l.port, address: l.address,
                processName: process.name,
                project: CoreLogic.projectName(path: cwd, processName: process.name),
                kind: CoreLogic.detectKind(process: process.name, command: process.command, port: l.port),
                command: process.command, workingDirectory: cwd,
                cpu: process.cpu, memoryBytes: process.memoryBytes,
                userOwned: process.uid == getuid()))
        }
        // Prefer loopback when a process listens on both IPv4 and IPv6 or on all interfaces.
        var dedup: [String: LocalService] = [:]
        for item in s.services {
            let key = item.id
            if let previous = dedup[key] {
                if item.address == "127.0.0.1" || item.address == "::1" { dedup[key] = item }
                else if previous.address == "*" { dedup[key] = item }
            } else { dedup[key] = item }
        }
        s.services = dedup.values.sorted { $0.port < $1.port }

        let count = max(1, ProcessInfo.processInfo.activeProcessorCount)
        s.cpuPercent = min(100, s.processes.reduce(0) { $0 + $1.cpu } / Double(count))
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
        let free = (counters["Pages free"] ?? 0) + (counters["Pages inactive"] ?? 0) + (counters["Pages speculative"] ?? 0)
        let compressed = (counters["Pages occupied by compressor"] ?? 0) * size
        guard !raw.isEmpty, physical > 0 else { return (0, 0) }
        return (max(0, min(physical, physical - free * size)), compressed)
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
            guard cells.count > max(rx, tx), let device = cells.first,
                  device.hasPrefix("en"), device.dropFirst(2).allSatisfy({ $0.isNumber }),
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

    static func probeWebsite(service: LocalService) -> SiteProbe {
        guard (1...65535).contains(service.port), let url = service.pageURL else {
            return SiteProbe(httpStatus: nil, title: nil, detail: "Неверный порт")
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.9
        config.timeoutIntervalForResource = 1.1
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("MacScope/1.0", forHTTPHeaderField: "User-Agent")
        let box = ProbeResultBox()
        let done = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            guard let response = response as? HTTPURLResponse else { return }
            let body = String(data: (data ?? Data()).prefix(128_000), encoding: .utf8) ?? ""
            let title = CoreLogic.htmlTitle(body)
            box.set(SiteProbe(httpStatus: response.statusCode, title: title, detail: "HTTP \(response.statusCode)"))
        }
        task.resume()
        let finished = done.wait(timeout: .now() + 1.3) == .success
        if !finished { task.cancel() }
        session.invalidateAndCancel()
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
