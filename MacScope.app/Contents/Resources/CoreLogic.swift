import Foundation

struct ProcessInfoRow: Identifiable, Hashable {
    let pid: Int32
    let uid: UInt32
    let parentPID: Int32
    let cpu: Double
    let memoryBytes: Int64
    let command: String
    var id: Int32 { pid }
    var name: String {
        let first = command.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? "Процесс"
        return (first as NSString).lastPathComponent
    }
}

struct PortListener: Hashable {
    let pid: Int32
    let address: String
    let port: Int
}

enum ServiceKind: String {
    case website = "Сайт / API"
    case database = "База данных"
    case infrastructure = "Служба"
    case other = "TCP-сервис"
}

struct LocalService: Identifiable, Hashable {
    let pid: Int32
    let port: Int
    let address: String
    let processName: String
    let project: String
    let kind: ServiceKind
    let command: String
    let workingDirectory: String
    let cpu: Double
    let memoryBytes: Int64
    let userOwned: Bool
    var id: String { "\(pid):\(port)" }
    var defaultName: String { project.isEmpty ? processName : project }
    var pageURL: URL? {
        let host: String
        if address == "*" || address == "0.0.0.0" || address == "::" { host = "127.0.0.1" }
        else if address.contains(":") { host = "[\(address)]" }
        else { host = address }
        return URL(string: "http://\(host):\(port)/")
    }
}

struct SiteProbe: Equatable {
    let httpStatus: Int?
    let title: String?
    let detail: String
    var isHTTP: Bool { httpStatus != nil }
}

struct ResourceSnapshot {
    var processes: [ProcessInfoRow] = []
    var services: [LocalService] = []
    var cpuPercent: Double = 0
    var totalRAM: Int64 = 0
    var usedRAM: Int64 = 0
    var compressedRAM: Int64 = 0
    var swapRAM: Int64 = 0
    var diskTotal: Int64 = 0
    var diskFree: Int64 = 0
    var networkReceived: Int64 = 0
    var networkSent: Int64 = 0
    var timestamp: Date = Date()
    var error: String? = nil
}

enum CoreLogic {
    static func parsePS(_ raw: String) -> [ProcessInfoRow] {
        raw.split(separator: "\n").compactMap { line in
            let parts = line.split(maxSplits: 5, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard parts.count == 6,
                  let pid = Int32(parts[0]),
                  let uid = UInt32(parts[1]),
                  let ppid = Int32(parts[2]),
                  let cpu = Double(parts[3].replacingOccurrences(of: ",", with: ".")),
                  let rssKB = Int64(parts[4]) else { return nil }
            return ProcessInfoRow(pid: pid, uid: uid, parentPID: ppid,
                                  cpu: max(0, cpu), memoryBytes: max(0, rssKB) * 1024,
                                  command: String(parts[5]))
        }
    }

    static func parseLsof(_ raw: String) -> [PortListener] {
        var pid: Int32? = nil
        var found: Set<PortListener> = []
        for lineSub in raw.split(separator: "\n") {
            let line = String(lineSub)
            guard let prefix = line.first else { continue }
            switch prefix {
            case "p": pid = Int32(line.dropFirst())
            case "n":
                guard let current = pid, let listener = listener(pid: current, raw: String(line.dropFirst())) else { continue }
                found.insert(listener)
            default: break
            }
        }
        return found.sorted { $0.port == $1.port ? $0.pid < $1.pid : $0.port < $1.port }
    }

    static func listener(pid: Int32, raw: String) -> PortListener? {
        // lsof with -nP produces *:5173, 127.0.0.1:8000, or [::1]:8000.
        guard let i = raw.lastIndex(of: ":"),
              let port = Int(raw[raw.index(after: i)...]), (1...65535).contains(port) else { return nil }
        let host = String(raw[..<i]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty, !host.contains("->") else { return nil }
        return PortListener(pid: pid, address: host, port: port)
    }

    static func detectKind(process: String, command: String, port: Int) -> ServiceKind {
        let s = "\(process) \(command)".lowercased()
        if ["postgres", "redis-server", "mysqld", "mongod", "mariadb", "memcached", "clickhouse"].contains(where: s.contains) { return .database }
        if ["vite", "next", "nuxt", "uvicorn", "gunicorn", "flask", "fastapi", "http-server", "webpack", "httpd", "nginx", "caddy", "jupyter", "node", "bun ", "deno", "python -m http.server"].contains(where: s.contains) { return .website }
        if [80, 443, 3000, 3001, 4173, 5000, 5173, 8000, 8001, 8080, 8081, 8888].contains(port) { return .website }
        if ["docker", "ollama", "ssh", "cupsd", "syncthing", "adb", "containerd"].contains(where: s.contains) { return .infrastructure }
        return .other
    }

    static func projectName(path: String, processName: String) -> String {
        guard !path.isEmpty else { return "" }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 4 else { return "" }
        let name = parts.last ?? ""
        if ["", "MacOS", "bin", "sbin", "Resources", "Contents", "Applications", "Library", "Frameworks", "usr", "var", "private"].contains(name) { return "" }
        if name.hasPrefix(".") && name != ".vite" { return "" }
        return name
    }

    static func bytes(_ size: Int64, digits: Int = 1) -> String {
        if size < 1024 { return "\(size) Б" }
        let units = ["КБ", "МБ", "ГБ", "ТБ", "ПБ"]
        var value = Double(size)
        var i = -1
        repeat { value /= 1024; i += 1 } while value >= 1024 && i < units.count - 1
        return String(format: "%.*f %@", digits, value, units[i])
    }

    static func safeCommand(_ raw: String) -> String {
        // Never leak common secrets from the command line in the app UI.
        var value = raw
        let patterns = [
            #"(?i)(--(?:api[-_]?key|token|password|secret|auth|credential)(?:\s+|=))(\S+)"#,
            #"(?i)((?:API_KEY|TOKEN|PASSWORD|SECRET|AUTH_TOKEN)=)(\S+)"#,
            #"(?i)(://[^:/\s]+:)([^@\s]+)(@)"#
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = value as NSString
            let range = NSRange(location: 0, length: ns.length)
            let matches = re.matches(in: value, range: range)
            for m in matches.reversed() {
                let r = m.range(at: 2)
                if r.location != NSNotFound, let swiftRange = Range(r, in: value) {
                    value.replaceSubrange(swiftRange, with: "••••••")
                }
            }
        }
        return value
    }

    static func htmlTitle(_ body: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"<title(?:\s[^>]*)?>(.*?)</title\s*>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let range = Range(match.range(at: 1), in: body) else { return nil }
        let title = body[range].replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : String(title.prefix(100))
    }
}
