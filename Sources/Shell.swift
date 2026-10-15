// VPuNinst. Copyright (c) 2026 Riccardo Nevoso. GPL-3.0-or-later; see LICENSE.
import AppKit
import Foundation
import SystemConfiguration

enum Shell {
    struct Result { let status: Int32; let out: String; let err: String }

    /// Runs a command without a shell. Blocking — call off the main actor.
    @discardableResult
    static func run(_ path: String, _ args: [String], stdin: String? = nil,
                    env: [String: String] = [:]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var e = ProcessInfo.processInfo.environment
        env.forEach { e[$0.key] = $0.value }
        p.environment = e
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = stdin == nil ? FileHandle.nullDevice : inp
        do { try p.run() } catch { return Result(status: -1, out: "", err: error.localizedDescription) }
        if let s = stdin {
            inp.fileHandleForWriting.write(Data((s + "\n").utf8))
            try? inp.fileHandleForWriting.close()
        }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let r = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus,
                      out: String(decoding: o, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                      err: String(decoding: r, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// The root half. Its three everyday verbs run with `sudo -n`: the sudoers
/// rule lets them through without a password, and sudo never prompts. Touch
/// ID is asked for by the app (see Tunnels.confirm), because pam_tid does not
/// prompt for a sudo started by an app. Changing the list of institutions
/// goes through the system's administrator dialog instead (see `admin`).
enum Helper {
    static let path = "/Library/PrivilegedHelperTools/vpuninst-helper"

    static var isInstalled: Bool {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
        return (a[.ownerAccountID] as? NSNumber)?.intValue == 0
    }

    /// Whether the sudoers rule is in place, read from the NOPASSWD lines of
    /// `sudo -n -l`. (`sudo -l <command>` would not do: it answers "allowed"
    /// for anything an admin may run with a password.) A rule that also lets
    /// `add` or `remove` through is treated as not set up: anything running as
    /// the user could then send root's openconnect to a server of its own.
    static var passwordless: Bool {
        let rules = Shell.run("/usr/bin/sudo", ["-n", "-l"]).out
            .split(separator: "\n").filter { $0.contains("NOPASSWD:") }.joined(separator: " ")
        let has = { (verb: String) in rules.contains("\(path) \(verb)") }
        return has("connect") && has("disconnect") && has("repair") && !has("add") && !has("remove")
    }

    static func call(_ args: [String], stdin: String? = nil) -> Shell.Result {
        let r = Shell.run("/usr/bin/sudo", ["-n", path] + args, stdin: stdin)
        // The cookie travels on stdin and is never written here.
        let shape = stdin.map { " stdin=\($0.count) chars" } ?? ""
        AppLog.write("helper \(args.joined(separator: " "))\(shape) → status \(r.status)"
                     + (r.err.isEmpty ? "" : "\n  stderr: \(r.err)")
                     + (r.out.isEmpty ? "" : "\n  stdout: \(r.out)"))
        return r
    }

    /// Runs the helper as root through the system's administrator dialog:
    /// the verbs that change what root will do (add, remove) are kept out of
    /// the sudoers rule. Each argument is single-quoted for the shell, then
    /// escaped for AppleScript's string. On the main actor, as NSAppleScript
    /// wants; the dialog is the interface while it is up. nil when it worked,
    /// the reason otherwise; "" when the dialog was cancelled.
    @MainActor
    static func admin(_ args: [String], prompt: String) -> String? {
        let command = ([path] + args).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        func literal(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let source = "do shell script \(literal(command + " 2>&1")) with prompt \(literal(prompt)) with administrator privileges"
        var error: NSDictionary?
        NSApp.activate(ignoringOtherApps: true)
        _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
        AppLog.write("helper \(args.first ?? "") \(args.dropFirst().first ?? "") as administrator → "
                     + (error.map { "error \($0[NSAppleScript.errorNumber] ?? "?")" } ?? "ok"))
        guard let error else { return nil }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return "" }
        return error[NSAppleScript.errorMessage] as? String ?? "The helper refused."
    }
}

enum AppLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/\(Brand.name).log")

    static func write(_ line: String) {
        let s = "\(Date().formatted(.iso8601)) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(s.utf8))
            try? h.close()
        } else {
            try? s.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// Looks at the Mac. Nothing here sends a packet but `latency`.
enum Probe {
    static let run = "/var/run/vpuninst"

    /// One institution's tunnel as the system has it: openconnect's pid, if
    /// it is running, and what vpuninst-tunnel recorded when it set the tunnel up.
    struct Tunnel {
        var pid: Int32?
        var state: [String: String]?

        var phase: String? { state?["PHASE"] }
        var interface: String? { state?["TUNDEV"].flatMap { $0.isEmpty ? nil : $0 } }
        /// Up, and its interface still exists.
        var isUp: Bool { pid != nil && phase == "up" && interface.map { if_nametoindex($0) != 0 } == true }
        func list(_ key: String) -> [String] { (state?[key] ?? "").split(separator: " ").map(String.init) }
    }

    static func tunnel(_ id: String) -> Tunnel {
        let pid = (try? String(contentsOfFile: "\(run)/\(id).pid", encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .flatMap { isOpenconnect($0) ? $0 : nil }
        let state = (try? String(contentsOfFile: "\(run)/\(id).state", encoding: .utf8)).map { text in
            Dictionary(text.split(separator: "\n").compactMap { line -> (String, String)? in
                guard let eq = line.firstIndex(of: "=") else { return nil }
                return (String(line[..<eq]), String(line[line.index(after: eq)...]))
            }, uniquingKeysWith: { a, _ in a })
        }
        return Tunnel(pid: pid, state: state)
    }

    /// Whether a pid is a running openconnect. The pid file alone isn't
    /// enough: it outlives a crash, and the number can be reused. Nor is the
    /// name, which any program can give itself: it must be running as root.
    static func isOpenconnect(_ pid: Int32) -> Bool {
        guard let info = process(pid), info.kp_eproc.e_ucred.cr_uid == 0 else { return false }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return name == "openconnect"
    }

    static func startDate(pid: Int32) -> Date? {
        guard let info = process(pid) else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
    }

    private static func process(_ pid: Int32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    /// Institutions whose openconnect has stopped but whose settings are still
    /// there: a record in /var/run/vpuninst, or network keys under their name
    /// (the record can go while the keys stay). The helper's repair undoes them.
    static func leftovers() -> [String] {
        var ids = Set<String>()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: run)) ?? []
        for f in files where f.hasSuffix(".state") { ids.insert(String(f.dropLast(6))) }
        if let store = SCDynamicStoreCreate(nil, Brand.name as CFString, nil, nil),
           let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/vpuninst-[a-z0-9-]+/(IPv4|DNS)" as CFString) as? [String] {
            for k in keys {
                let svc = k.split(separator: "/")[3]
                ids.insert(String(svc.dropFirst("vpuninst-".count)))
            }
        }
        return ids.filter { tunnel($0).pid == nil }.sorted()
    }

    /// Round-trip through the tunnel, in milliseconds: a single ICMP echo to
    /// the first DNS server the gateway named, which is reachable only through
    /// the tunnel. nil if nothing comes back within two seconds, which is also
    /// what a server that ignores pings gives.
    static func latency(_ host: String) -> Double? {
        let r = Shell.run("/sbin/ping", ["-c", "1", "-t", "2", host])
        guard r.status == 0, let t = r.out.range(of: "time=") else { return nil }
        return Double(r.out[t.upperBound...].prefix { $0.isNumber || $0 == "." })
    }

    /// Whether two tunnels' IPv4 ranges overlap without being identical (an
    /// identical one is never added twice: it is a clash, reported apart).
    static func overlap(_ a: [String], _ b: [String]) -> Bool {
        func parse(_ r: String) -> (UInt32, Int)? {
            let p = r.split(separator: "/")
            guard p.count == 2, let len = Int(p[1]), (0...32).contains(len) else { return nil }
            let o = p[0].split(separator: ".").compactMap { UInt32($0) }
            guard o.count == 4, o.allSatisfy({ $0 < 256 }) else { return nil }
            return (o[0] << 24 | o[1] << 16 | o[2] << 8 | o[3], len)
        }
        func inside(_ x: (UInt32, Int), _ y: (UInt32, Int)) -> Bool {
            x.1 >= y.1 && (y.1 == 0 || x.0 >> (32 - y.1) == y.0 >> (32 - y.1))
        }
        let ra = a.compactMap(parse), rb = b.compactMap(parse)
        return ra.contains { x in rb.contains { y in x != y && (inside(x, y) || inside(y, x)) } }
    }

    /// What to say when the openconnect installed for the helper isn't the
    /// one this app comes with, as when a build from source skipped copying
    /// the new one; nil when they match, or either can't be read. The app's
    /// is named in its Licenses/SOURCES.txt, the installed one says its own.
    static func openconnectMismatch() -> String? {
        func versions(_ s: String, _ pattern: String) -> (String, String)? {
            guard let r = try? Regex(pattern), let m = s.firstMatch(of: r), m.count == 3,
                  let a = m[1].substring, let b = m[2].substring else { return nil }
            return (String(a), String(b))
        }
        guard let url = Bundle.main.url(forResource: "SOURCES", withExtension: "txt", subdirectory: "Licenses"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              let want = versions(text, #"openconnect ([0-9.]+), built with OpenSSL ([0-9.]+)"#) else { return nil }
        let r = Shell.run("/Library/PrivilegedHelperTools/vpuninst/openconnect", ["--version"])
        guard let have = versions(r.out + "\n" + r.err, #"version v([0-9.]+)[\s\S]*?Using OpenSSL ([0-9.]+)"#),
              have != want else { return nil }
        return "The openconnect installed for the helper is \(have.0) with OpenSSL \(have.1), not the \(want.0) with OpenSSL \(want.1) this VPuNinst comes with. Install VPuNinst again; built from source, repeat step 2 in the README."
    }

    static func logTail(_ id: String, _ n: Int = 6) -> String {
        let s = (try? String(contentsOfFile: "/var/log/vpuninst-\(id).log", encoding: .utf8)) ?? ""
        return s.split(separator: "\n").suffix(n).joined(separator: "\n")
    }
}
