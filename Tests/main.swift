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

let memSample = "Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free: 100.\nPages active: 150.\nPages inactive: 200.\nPages speculative: 50.\nPages wired down: 100.\nPages occupied by compressor: 400.\n"
let mem = MacCollector.parseVM(memSample, physical: 16384 * 1000)
expect(mem.used == 16384 * 650, "VM used = active+wired+compressed")
expect(mem.compressed == 16384 * 400, "Compressed pages")
let times = CoreLogic.parsePSTime("  552 266:46.30\n  884 3:08.80\n  999 1:02:03\n")
expect(abs((times[552] ?? -1) - 16006.3) < 0.01, "TIME minutes:seconds")
expect(abs((times[884] ?? -1) - 188.8) < 0.01, "TIME short process")
expect(abs((times[999] ?? -1) - 3723.0) < 0.01, "TIME with hours")
let d = CoreLogic.deltaCPU(current: [1: (10.0, "/bin/a"), 2: (5.0, "/bin/b")], previous: [1: (6.0, "/bin/a"), 2: (4.0, "/bin/CHANGED")], wall: 2.0, cores: 4)
expect(d[1] == 200.0, "CPU delta per core")
expect(d[2] == nil, "Reused PID with new command is skipped")
let sr = [ProcessInfoRow(pid: 3, uid: 501, parentPID: 1, cpu: 1, memoryBytes: 300, command: "/bin/ccc"),
          ProcessInfoRow(pid: 1, uid: 501, parentPID: 1, cpu: 9, memoryBytes: 100, command: "/bin/aaa"),
          ProcessInfoRow(pid: 2, uid: 501, parentPID: 1, cpu: 5, memoryBytes: 200, command: "/bin/bbb")]
expect(CoreLogic.sortProcesses(sr, by: .ram, ascending: false).map(\.pid) == [3, 2, 1], "Sort RAM desc")
expect(CoreLogic.sortProcesses(sr, by: .ram, ascending: true).map(\.pid) == [1, 2, 3], "Sort RAM asc")
expect(CoreLogic.sortProcesses(sr, by: .name, ascending: true).map(\.pid) == [1, 2, 3], "Sort name asc")
let tm = CoreLogic.parseTopMem("PID MEM\n59115  7063M\n403    824M \n12 4096K\n7 1.5G\nProcesses: 4 total\n")
expect(tm[59115] == 7063 * 1048576, "Top MEM megabytes")
expect(tm[403] == 824 * 1048576, "Top MEM trailing space")
expect(tm[12] == 4096 * 1024, "Top MEM kilobytes")
expect(tm[7] == 1610612736, "Top MEM fractional gigabytes")
func prow(_ pid: Int32, _ ppid: Int32, _ name: String) -> ProcessInfoRow {
    ProcessInfoRow(pid: pid, uid: 501, parentPID: ppid, cpu: 0, memoryBytes: 0, command: "/bin/\(name)")
}
let troot = [prow(1, 0, "a"), prow(2, 1, "b"), prow(3, 2, "c"), prow(4, 1, "d"), prow(5, 0, "e")]
expect(Set(CoreLogic.processTree(rootPID: 1, rows: troot).map(\.pid)) == [1, 2, 3, 4], "Process tree")
expect(Set(CoreLogic.processTree(rootPID: 2, rows: troot).map(\.pid)) == [2, 3], "Subtree")
expect(CoreLogic.processTree(rootPID: 99, rows: troot).isEmpty, "Missing root")
expect(MacCollector.canKill(pid: 1, uid: 501) == false, "PID 1 protected")
expect(MacCollector.canKill(pid: ProcessInfo.processInfo.processIdentifier, uid: 501) == false, "Self protected")
expect(MacCollector.canKill(pid: 99991, uid: 0) == false, "Foreign UID protected")
expect(MacCollector.canKill(pid: 99991, uid: getuid()) == true, "Own process killable")
expect(MacCollector.parseSwap("total = 4.00G used = 1.50G free = 2.50G") == 1610612736, "Swap parse")
let netSample = "Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll\nen0 1500 <Link#2> 00:aa:bb:cc 123 0 250000 77 0 80000 0\nen0 1500 192.168.1 192.168.1.5 20 0 250000 20 0 80000 0\nen1 1500 <Link#3> 00:cc:dd 14 0 500 20 0 700 0\nutun0 1380 <Link#5> x 10 0 1000 5 0 2000 0\nlo0 16384 <Link#1> 00 1 0 100000000 1 0 100000000 0\n"
let net = MacCollector.parseNetstat(netSample)
expect(net.received == 251500 && net.sent == 82700, "Network counts link rows except lo0")
print("PASS: 36 CoreLogic + macOS telemetry parsing assertions")
