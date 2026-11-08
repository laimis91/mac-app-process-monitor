// Test main for AppMonitor/ProcessTree.swift (scripts/grouping-test.sh): process ownership in several visit orders, the
// "Quit" fallback rule, and pid identity checks on this test's own child process.

import Foundation
import Darwin

var failures = 0
func check(_ ok: Bool, _ what: String) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what)"); failures += 1 }
}

func proc(_ pid: Int32, _ ppid: Int32, _ exe: String) -> RawProc {
    RawProc(pid: pid, ppid: ppid, cpu: 0, rssKB: 0, exe: exe)
}

let vscode = "/Applications/Visual Studio Code.app"
let terminal = "/System/Applications/Utilities/Terminal.app"
let chrome = "/Applications/Google Chrome.app"
let list: [RawProc] = [
    proc(1, 0, "/sbin/launchd"),
    // A tmux server started by launchd, with an app's command-line tool running inside it.
    proc(100, 1, "/opt/homebrew/bin/tmux"),
    proc(101, 100, "/bin/zsh"),
    proc(102, 101, vscode + "/Contents/Resources/app/bin/code"),
    proc(103, 102, "/usr/local/bin/node"),
    proc(104, 100, "/bin/zsh"),
    // An app's descendants, including another app started from it, belong to the outer app.
    proc(200, 1, terminal + "/Contents/MacOS/Terminal"),
    proc(201, 200, "/usr/bin/login"),
    proc(202, 201, "/bin/zsh"),
    proc(203, 202, vscode + "/Contents/MacOS/Electron"),
    proc(204, 203, "/usr/bin/git"),
    // A helper app nested inside its app's bundle.
    proc(300, 1, chrome + "/Contents/MacOS/Google Chrome"),
    proc(301, 300, chrome + "/Contents/Frameworks/Helper.app/Contents/MacOS/Google Chrome Helper"),
    // A parent that is not in the snapshot: the process is its own top.
    proc(400, 9999, "/usr/bin/foo"),
    proc(401, 400, "/usr/bin/bar"),
]
var procs: [Int32: RawProc] = [:]
for p in list { procs[p.pid] = p }

let app = { (k: String) in ProcOwner(key: k, isApp: true) }
let tool = { (k: String) in ProcOwner(key: k, isApp: false) }
let expected: [Int32: ProcOwner] = [
    1: tool("launchd"),
    100: tool("tmux"), 101: tool("tmux"), 102: app(vscode), 103: app(vscode), 104: tool("tmux"),
    200: app(terminal), 201: app(terminal), 202: app(terminal), 203: app(terminal), 204: app(terminal),
    300: app(chrome), 301: app(chrome),
    400: tool("foo"), 401: tool("foo"),
]

let pids = procs.keys.sorted()
var rng = SystemRandomNumberGenerator()
let orders: [(String, [Int32])] = [
    ("parents first", pids),
    ("children first", pids.reversed()),
    ("tmux chain bottom-up", [103, 102, 101, 100] + pids),
    ("shuffled", pids.shuffled(using: &rng)),
    ("dictionary order", Array(procs.keys)),
]
for (name, order) in orders {
    let got = processOwners(procs, order: order)
    let wrong = expected.filter { got[$0.key] != $0.value }.keys.sorted()
    check(wrong.isEmpty, "owners, \(name)\(wrong.isEmpty ? "" : ": wrong for \(wrong.map { "\($0) -> \(String(describing: got[$0]))" })")")
}
check(processOwners(procs)[100] == tool("tmux"), "a tmux server above an app's tool is not owned by that app")

// Parent cycles (a reused pid can make one) end, and every process still gets an owner.
let cyc: [Int32: RawProc] = [500: proc(500, 501, "/usr/bin/a"), 501: proc(501, 500, "/usr/bin/b"),
                             600: proc(600, 600, "/usr/bin/self"), 601: proc(601, 600, "/usr/bin/kid")]
for order in [[500, 501, 600, 601], [601, 600, 501, 500]] as [[Int32]] {
    let got = processOwners(cyc, order: order)
    check(got.count == 4 && got[600] == tool("self") && got[601] == tool("self"), "cycle guard, order \(order)")
}

// "Quit <app>" may fall back to a signal only for a process inside that app's bundle.
check(quitSignalAllowed(exe: vscode + "/Contents/MacOS/Electron", appBundle: vscode, groupKey: "Visual Studio Code"), "quit: exe inside the bundle")
check(!quitSignalAllowed(exe: "/opt/homebrew/bin/tmux", appBundle: vscode, groupKey: "Visual Studio Code"), "quit: exe outside the bundle refused")
check(!quitSignalAllowed(exe: "/Applications/Visual Studio Code.app2/x", appBundle: vscode, groupKey: "x"), "quit: lookalike bundle path refused")
check(!quitSignalAllowed(exe: nil, appBundle: vscode, groupKey: "Visual Studio Code"), "quit: unknown exe refused")
check(quitSignalAllowed(exe: "/opt/homebrew/bin/tmux", appBundle: nil, groupKey: "tmux"), "quit: non-app group's own exe")
check(!quitSignalAllowed(exe: "/bin/zsh", appBundle: nil, groupKey: "tmux"), "quit: non-app group, other exe refused")

// Identity: our own child keeps its identity while it runs and loses it once it is gone.
let child = Process()
child.executableURL = URL(fileURLWithPath: "/bin/sleep")
child.arguments = ["30"]
try child.run()
let cpid = child.processIdentifier
let id = procIdentity(cpid)
check(id?.ppid == getpid(), "identity: child's parent is this test")
check(stillSameProcess(cpid, id), "identity: unchanged child matches")
if let id {
    check(!stillSameProcess(cpid, ProcIdentity(ppid: id.ppid, startSec: id.startSec, startUsec: id.startUsec + 1)), "identity: other start time refused")
    check(!stillSameProcess(cpid, ProcIdentity(ppid: id.ppid + 1, startSec: id.startSec, startUsec: id.startUsec)), "identity: other parent refused")
}
check(!stillSameProcess(cpid, nil), "identity: no sampled identity refused")
check(executablePath(cpid) == "/bin/sleep", "executablePath of the child")
child.terminate()
child.waitUntilExit()
check(!stillSameProcess(cpid, id), "identity: exited child refused")
print("info: launchd identity readable without root: \(procIdentity(1) != nil)")

if failures > 0 { print("grouping-test: \(failures) FAILED"); exit(1) }
print("grouping-test: all passed")
