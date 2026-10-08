import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
let ps = "  552  501    1   14.5  10240 /opt/homebrew/bin/node /Users/test/imvera/node_modules/.bin/vite --port 5173\n  884 501 552  0.0 250000 /usr/bin/python3 -m uvicorn api:app"
let p = CoreLogic.parsePS(ps)
expect(p.count == 2, "PS should parse processes")
expect(p[0].pid == 552 && p[0].memoryBytes == 10485760, "PS units")
expect(p[0].name == "node", "Process name")
expect(p[1].cpu == 0, "CPU value")
let ls = "p552\ncnode\nf17u\nn127.0.0.1:5173\nf18u\nn[::1]:5173\np884\ncPython\nf5u\nn*:8000\n"
let l = CoreLogic.parseLsof(ls)
expect(l.count == 3, "LISTEN addresses")
expect(l[0].port == 5173 && l[2].port == 8000, "Port extraction")
expect(CoreLogic.parseLsof("p1\nn127.0.0.1:5555->127.0.0.1:44\n").isEmpty, "Reject connected sockets")
expect(CoreLogic.projectName(path: "/Users/u/dev/imvera", processName: "node") == "imvera", "Project identification")
expect(CoreLogic.detectKind(process: "postgres", command: "postgres", port: 5432) == .database, "DB category")
expect(CoreLogic.detectKind(process: "node", command: "vite", port: 5173) == .website, "Web category")
expect(CoreLogic.htmlTitle("<html><TITLE> IMVERA &amp; Family </TITLE></html>") == "IMVERA & Family", "HTML title")
expect(CoreLogic.safeCommand("uvicorn --token=abc123 PASSWORD=hi https://user:pass@example.com").contains("abc123") == false, "Secret protection")
expect(CoreLogic.bytes(1073741824) == "1.0 ГБ", "Byte units")

let memSample = "Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free: 100.\nPages inactive: 200.\nPages speculative: 50.\nPages occupied by compressor: 400.\n"
let mem = MacCollector.parseVM(memSample, physical: 16384 * 1000)
expect(mem.used == 16384 * 650, "VM used vs inactive/free/speculative")
expect(mem.compressed == 16384 * 400, "Compressed pages")
expect(MacCollector.parseSwap("total = 4.00G used = 1.50G free = 2.50G") == 1610612736, "Swap parse")
let netSample = "Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll\nen0 1500 <Link#2> 00:aa:bb:cc 123 0 250000 77 0 80000 0\nen0 1500 192.168.1 192.168.1.5 20 0 250000 20 0 80000 0\nen1 1500 <Link#3> 00:cc:dd 14 0 500 20 0 700 0\nlo0 16384 <Link#1> 00 1 0 100000000 1 0 100000000 0\n"
let net = MacCollector.parseNetstat(netSample)
expect(net.received == 250500 && net.sent == 80700, "Network counters count only en* link rows")
print("PASS: 15 CoreLogic + macOS telemetry parsing assertions")
