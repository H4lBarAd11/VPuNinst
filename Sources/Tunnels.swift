// VPuNinst. Copyright (c) 2026 Riccardo Nevoso. GPL-3.0-or-later; see LICENSE.
import AppKit
import LocalAuthentication
import Network
import ServiceManagement
import SwiftUI
import WebKit

/// Every institution's tunnel: what the Mac shows of it, what the user asked
/// for, and the sign-ins in between. Tunnels run side by side; sign-ins take
/// turns in the one sheet.
@MainActor
final class Tunnels: ObservableObject {
    enum State: Equatable {
        case checking, disconnected, signingIn, connecting, connected, reconnecting, disconnecting
    }

    struct Status: Equatable {
        var state: State = .checking
        var since: Date?
        var interface: String?
        /// Smoothed round-trip through the tunnel, in milliseconds, while it
        /// is up. nil until the first reply, and again once replies stop.
        var latency: Double?
        var problem: String?
        /// Ranges this institution's gateway sent that another tunnel holds.
        var clash: [String] = []
        /// Institutions whose tunnels share addresses with this one, the more
        /// specific range winning.
        var overlaps: [String] = []
        /// Domains the gateway named that another tunnel already answers for.
        var taken: [String] = []
        /// The tunnel carries all traffic, not only the institution's.
        var full = false
        /// The gateway sent DNS servers but no domain to use them for.
        var noDomain = false

        var isUp: Bool { state == .connected }
        var isWorking: Bool { [.checking, .signingIn, .connecting, .reconnecting, .disconnecting].contains(state) }
    }

    @Published private(set) var institutions = Institution.load()
    @Published private(set) var status: [String: Status] = [:]
    /// The sign-in on show, and those waiting their turn.
    @Published private(set) var signIn: SignInRequest?
    private var queue: [SignInRequest] = []
    @Published private(set) var helperReady = Helper.isInstalled && Helper.passwordless
    @Published var keepConnected: Bool {
        didSet { UserDefaults.standard.set(keepConnected, forKey: "keepConnected") }
    }
    @Published private(set) var openAtLogin = SMAppService.mainApp.status == .enabled
    /// Measure the round-trip through each tunnel. Off by default: it is the
    /// one thing here that puts a packet on the wire, so it is asked for
    /// rather than assumed. Turning it off stops the echoes at once.
    @Published var showLatency: Bool {
        didSet {
            UserDefaults.standard.set(showLatency, forKey: "showLatency")
            if !showLatency { for id in status.keys { forgetLatency(id) } }
        }
    }
    /// Keep each sign-in in the keychain and fill its form with it. Turning
    /// it off deletes what was saved.
    @Published var rememberPassword: Bool {
        didSet {
            UserDefaults.standard.set(rememberPassword, forKey: "rememberPassword")
            // Off the main thread: the keychain may ask first (see SignInWebView).
            let ids = institutions.map(\.id)
            if !rememberPassword { Task.detached(priority: .utility) { ids.forEach(SavedLogin.forget) } }
        }
    }
    /// A problem that belongs to no one institution.
    @Published var problem: String?

    /// Institutions the user asked to be connected to, until they disconnect.
    /// Only for those does a drop count as something to recover from.
    private var wanted = Set(UserDefaults.standard.stringArray(forKey: "wanted") ?? []) {
        didSet { UserDefaults.standard.set(wanted.sorted(), forKey: "wanted") }
    }
    /// Institutions with a helper call in flight: the watcher leaves them be.
    private var busy = Set<String>()
    private var timer: Timer?
    private let path = NWPathMonitor()
    /// The look at the Mac in progress, if any. One can take a while, and the
    /// timer, a wake and a network change each ask for one meanwhile; they
    /// wait for it instead of starting their own.
    private var looking: Task<Void, Never>?
    private var lastPing: [String: Date] = [:]
    private var pingMisses: [String: Int] = [:]
    /// Whether the installed openconnect has been compared with the app's.
    private var checkedOpenconnect = false
    /// When the watcher last asked repair to take tunnels' DNS servers out of
    /// a network's settings. Should that fail, it asks again once a minute,
    /// not on every look.
    private var lastDNSRepair = Date.distantPast

    init() {
        keepConnected = UserDefaults.standard.object(forKey: "keepConnected") as? Bool ?? true
        rememberPassword = UserDefaults.standard.object(forKey: "rememberPassword") as? Bool ?? true
        showLatency = UserDefaults.standard.bool(forKey: "showLatency")
        timer = .scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                await self?.tick()
            }
        }
        // A network coming back is the moment a wanted-but-dropped tunnel can
        // be retried; an earlier attempt may have failed for want of one.
        path.pathUpdateHandler = { [weak self] p in
            let online = p.status == .satisfied
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                await self.tick()
                guard online, self.keepConnected else { return }
                for id in self.wanted where self[id].state == .disconnected { self.connect(id, auto: true) }
            }
        }
        path.start(queue: .global(qos: .utility))
        Task { await tick() }
    }

    subscript(id: String) -> Status { status[id] ?? Status() }

    var anyUp: Bool { status.values.contains { $0.isUp } }
    var anyActive: Bool { status.values.contains { $0.isUp || $0.state == .reconnecting } }
    var allIdle: Bool { status.values.allSatisfy { $0.state == .disconnected } }

    private func update(_ id: String, _ change: (inout Status) -> Void) {
        var s = self[id]
        change(&s)
        if status[id] != s { status[id] = s }
    }

    // MARK: - Watching

    /// What the Mac looks like right now, and what to do about it. openconnect
    /// itself rides out Wi-Fi changes and sleep (--reconnect-timeout); this
    /// covers what it can't: settings a dead tunnel left behind, and a
    /// session that ended.
    func tick() async {
        let t = looking ?? Task { await examine() }
        looking = t
        await t.value
        if looking == t { looking = nil }
    }

    private func examine() async {
        // The sudoers probe spawns sudo; once it has passed, only watch the helper file.
        helperReady = helperReady ? Helper.isInstalled : Helper.isInstalled && Helper.passwordless
        if helperReady && !checkedOpenconnect {
            checkedOpenconnect = true
            if let m = await Task.detached(operation: { Probe.openconnectMismatch() }).value { problem = m }
        }
        let list = await Task.detached { Institution.load() }.value
        if list != institutions { institutions = list }
        for id in Set(status.keys).subtracting(list.map(\.id)) { status[id] = nil }
        wanted.formIntersection(list.map(\.id))

        let ids = list.map(\.id)
        let seen = await Task.detached { Dictionary(uniqueKeysWithValues: ids.map { ($0, Probe.tunnel($0)) }) }.value
        var dropped: [String] = []
        for i in list {
            let id = i.id, t = seen[id] ?? Probe.Tunnel()
            // Mid-sign-in or mid-call, the action in progress owns the state;
            // a tunnel being started is only ever promoted to up.
            let current = self[id].state
            if busy.contains(id) || [.signingIn, .disconnecting].contains(current) { continue }
            if current == .connecting && !t.isUp { continue }
            if t.isUp {
                let first = self[id].state != .connected
                let start = first ? await Task.detached { t.pid.flatMap(Probe.startDate) }.value : nil
                let shared = list.filter { o in
                    o.id != id && seen[o.id]?.isUp == true && Probe.overlap(t.list("ROUTES"), seen[o.id]?.list("ROUTES") ?? [])
                }.map(\.name)
                update(id) { s in
                    if first { s.since = start ?? Date(); s.problem = nil }
                    s.state = .connected
                    s.interface = t.interface
                    s.clash = t.list("CLASH")
                    s.overlaps = shared
                    s.taken = t.list("TAKEN")
                    s.full = t.state?["FULL"] == "1"
                    s.noDomain = !t.list("DNS").isEmpty && t.list("DOMAINS").isEmpty && !s.full
                }
                await measureLatency(id, server: t.list("DNS").first)
            } else if t.pid != nil {
                // Usually a different path on the way back up, so the last
                // round-trip no longer describes the link being measured.
                forgetLatency(id)
                update(id) { $0.state = .reconnecting }
            } else {
                let was = self[id].state
                if [.connected, .reconnecting].contains(was) || (was == .checking && wanted.contains(id)) {
                    dropped.append(id)
                }
                forgetLatency(id)
                update(id) { s in
                    s.state = .disconnected; s.since = nil; s.interface = nil
                    s.clash = []; s.overlaps = []; s.taken = []; s.full = false; s.noDomain = false
                }
            }
        }

        let stale = await Task.detached { Probe.leftovers() }.value
        // Looked at every time, with or without a tunnel: a network's saved
        // DNS outlives restarts, and anything can change it.
        let stranded = await Task.detached { Probe.strandedDNS() }.value
        let dnsDue = !stranded.isEmpty && Date().timeIntervalSince(lastDNSRepair) > 60
        if !stale.isEmpty || dnsDue, helperReady, busy.isEmpty {
            if dnsDue { lastDNSRepair = Date() }
            await repair()
        }
        for id in dropped where wanted.contains(id) && keepConnected && self[id].state == .disconnected {
            let name = list.first { $0.id == id }?.name ?? id
            update(id) { $0.problem = "The \(name) session ended. Signing in again to reconnect." }
            connect(id, auto: true)
        }
    }

    private func forgetLatency(_ id: String) {
        if self[id].latency != nil { update(id) { $0.latency = nil } }
        lastPing[id] = nil
        pingMisses[id] = 0
    }

    /// At most one echo every 20 seconds per tunnel, timed rather than
    /// counted: tick() also runs on wake and on every network path change, so
    /// counting ticks would ping a good deal more often than the switch
    /// promises. A single echo swings by tens of milliseconds, which reads as
    /// noise, so the reading is averaged; it is dropped only after two misses
    /// in a row, so one lost packet doesn't blank it.
    private func measureLatency(_ id: String, server: String?) async {
        guard showLatency, let server else { return }
        if let last = lastPing[id], Date().timeIntervalSince(last) < 20 { return }
        lastPing[id] = Date()
        let ms = await Task.detached(operation: { Probe.latency(server) }).value
        // The echo takes up to two seconds, and the main actor is free for
        // all of it: the switch can go off and the tunnel can drop while it
        // is in flight. Without this, that reading goes back on screen and
        // the guard above then stops anything from ever clearing it.
        guard showLatency, self[id].state == .connected else { return }
        if let ms {
            pingMisses[id] = 0
            update(id) { $0.latency = $0.latency.map { $0 * 0.7 + ms * 0.3 } ?? ms }
        } else {
            pingMisses[id, default: 0] += 1
            if pingMisses[id, default: 0] >= 2 { update(id) { $0.latency = nil } }
        }
    }

    // MARK: - Actions

    /// `auto` is a reconnect the app starts itself to keep a tunnel up; it
    /// skips Touch ID, since the sign-in that follows needs you anyway.
    func connect(_ id: String, auto: Bool = false) {
        guard helperReady, let i = institutions.first(where: { $0.id == id }),
              signIn?.institution.id != id, !queue.contains(where: { $0.institution.id == id }) else { return }
        wanted.insert(id)
        update(id) { $0.problem = nil; $0.state = .signingIn }
        Task {
            if !auto, !(await confirm("connect to \(i.name)")) {
                wanted.remove(id)
                update(id) { $0.state = .disconnected }
                return
            }
            // The sign-in starts by looking up the gateway, which a network
            // whose saved DNS only a tunnel answers would fail.
            if !(await Task.detached { Probe.strandedDNS() }.value).isEmpty { await repair() }
            do {
                let r = try await SignIn.start(i)
                // Removed or disconnected while the gateway was asked.
                guard self[id].state == .signingIn else { return }
                queue.append(r)
                showNextSignIn()
            } catch {
                update(id) { $0.state = .disconnected; $0.problem = error.localizedDescription }
            }
        }
    }

    private func showNextSignIn() {
        guard signIn == nil, !queue.isEmpty else { return }
        signIn = queue.removeFirst()
        bringForward()
    }

    /// The sheet was closed without signing in.
    func cancelSignIn() {
        guard let r = signIn else { return }
        signIn = nil
        wanted.remove(r.institution.id)
        update(r.institution.id) { $0.state = .disconnected }
        showNextSignIn()
    }

    func signInFailed(_ r: SignInRequest, _ message: String) {
        guard signIn?.id == r.id else { return }
        signIn = nil
        wanted.remove(r.institution.id)
        update(r.institution.id) { $0.state = .disconnected; $0.problem = message }
        showNextSignIn()
    }

    func signedIn(_ r: SignInRequest, _ c: Credential) {
        guard signIn?.id == r.id else { return }
        signIn = nil
        showNextSignIn()
        let id = r.institution.id
        let user = c.username.flatMap { $0.isEmpty ? nil : $0 } ?? "-"
        if r.institution.vpn == .gp && user == "-" {
            update(id) { $0.state = .disconnected; $0.problem = "The sign-in didn’t say which account it was for. Try again." }
            return
        }
        AppLog.write("signed in to \(id)\(r.gateway.map { " at \($0)" } ?? ""): kind=\(c.kind) user=\(user) cookie=\(c.cookie.count) chars")
        if r.institution.vpn == .gp, r.institution.option == "portal", r.gateway == nil {
            Task { await throughPortal(r, c, user: user) }
        } else {
            tunnel(id, user: user, c, gateway: r.gateway)
        }
    }

    /// A portal's sign-in says which gateway the tunnel goes to: the best one
    /// it lists, signed in with the cookie the portal hands out for it or,
    /// without one, with a sign-in of the gateway's own.
    private func throughPortal(_ r: SignInRequest, _ c: Credential, user: String) async {
        let i = r.institution, id = i.id
        func fail(_ m: String) {
            wanted.remove(id)
            update(id) { $0.state = .disconnected; $0.problem = m }
        }
        do {
            let p = try await SignIn.portal(r, c, user: user)
            guard self[id].state == .signingIn else { return }
            guard let g = p.gateways.first else { return fail("The portal named no gateway to connect to.") }
            AppLog.write("\(id)'s portal names \(p.gateways.joined(separator: ", ")), cookie=\(p.cookie == nil ? "none" : "yes")")
            guard allow(g, for: i) else {
                return fail("The portal sends the tunnel to \(g), which \(Brand.name) connects to only once you allow it.")
            }
            if let cookie = p.cookie {
                return tunnel(id, user: user, Credential(kind: "portal-userauthcookie", cookie: cookie, username: user), gateway: g)
            }
            let next = try await SignIn.gateway(i, g)
            guard self[id].state == .signingIn else { return }
            queue.append(next)
            showNextSignIn()
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// A gateway on the portal's own server is on the helper's list already;
    /// one on another server is added to the portal's entry, with the
    /// administrator's password, the first time the portal names it.
    private func allow(_ gateway: String, for i: Institution) -> Bool {
        if i.allows(gateway) { return true }
        var more = i
        more.gateways.append(gateway)
        let prompt = "\(i.name)’s portal sends the tunnel to \(gateway). \(Brand.name) wants to add it to the VPNs it may connect to."
        guard Helper.admin(more.addArguments, prompt: prompt) == nil else { return false }
        institutions = Institution.load()
        return true
    }

    private func tunnel(_ id: String, user: String, _ c: Credential, gateway: String?) {
        update(id) { $0.state = .connecting }
        busy.insert(id)
        Task {
            let r = await Task.detached {
                Helper.call(["connect", id, user, c.kind] + (gateway.map { [$0] } ?? []), stdin: c.cookie)
            }.value
            busy.remove(id)
            if r.status == 0 {
                for _ in 0..<20 where self[id].state == .connecting {
                    await tick()
                    if self[id].state == .connected { return }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            wanted.remove(id)
            update(id) { s in
                s.state = .disconnected
                s.problem = explain(r, id: id, fallback: "The tunnel didn’t come up. Usually the sign-in expired before it was used — try again.")
            }
        }
    }

    func disconnect(_ id: String) {
        guard let i = institutions.first(where: { $0.id == id }) else { return }
        Task {
            guard await confirm("disconnect from \(i.name)") else { return }
            wanted.remove(id)
            busy.insert(id)
            update(id) { $0.state = .disconnecting }
            let r = await Task.detached { Helper.call(["disconnect", id]) }.value
            busy.remove(id)
            update(id) { s in
                s.state = .checking
                if r.status != 0 { s.problem = explain(r, id: id, fallback: "Couldn’t stop the tunnel.") }
            }
            await tick()
        }
    }

    func repair() async {
        let r = await Task.detached { Helper.call(["repair"]) }.value
        // Each network whose DNS settings lost a tunnel's servers is named,
        // with the institutions those servers belong to.
        let lines: [[Substring]] = r.out.split(separator: Character("\n")).map { line in
            line.split(separator: Character("\t"), omittingEmptySubsequences: false)
        }
        let healed = lines.filter { $0.count == 3 && $0[0] == "dns" }
        let owners: [String: Set<String>] = healed.isEmpty ? [:] : await Task.detached { Probe.tunnelDNS() }.value
        var notes: [String] = healed.map { f in
            let servers = f[2].split(separator: Character(" ")).map(String.init)
            let names = institutions.filter { i in
                servers.contains { owners[i.id]?.contains($0.lowercased()) == true }
            }.map(\.name)
            let only = switch names.count {
            case 0: "a tunnel reaches"
            case 1: "\(names[0])’s tunnel reaches"
            default: "the tunnels of \(ListFormatter.localizedString(byJoining: names)) reach"
            }
            return "Took \(ListFormatter.localizedString(byJoining: servers)) out of \(f[1])’s DNS settings. "
                + "Only \(only) them, so off the tunnel no name could be looked up."
        }
        if r.status != 0 { notes.append(explain(r, id: nil, fallback: "Couldn’t undo what a tunnel left behind.")) }
        if !notes.isEmpty { problem = notes.joined(separator: "\n\n") }
    }

    // MARK: - The list

    /// Adds an institution, or changes one, through the administrator dialog.
    /// nil when it worked, the reason otherwise; "" when the dialog was cancelled.
    func save(_ i: Institution, isNew: Bool) -> String? {
        let prompt = isNew ? "\(Brand.name) wants to add \(i.name) to the VPNs it may connect to."
                           : "\(Brand.name) wants to change the settings of \(i.name)."
        if let e = Helper.admin(i.addArguments, prompt: prompt) { return e }
        institutions = Institution.load()
        Task { await tick() }
        return nil
    }

    func remove(_ i: Institution) -> String? {
        if let e = Helper.admin(["remove", i.id], prompt: "\(Brand.name) wants to remove \(i.name) from the VPNs it may connect to.") {
            return e
        }
        wanted.remove(i.id)
        status[i.id] = nil
        institutions = Institution.load()
        let store = i.dataStoreID
        Task.detached(priority: .utility) { SavedLogin.forget(i.id) }
        Task { try? await WKWebsiteDataStore.remove(forIdentifier: store) }
        return nil
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            problem = "Couldn’t change Open at Login: \(error.localizedDescription)"
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Touch ID, with the Mac password as the system's own fallback (lid
    /// closed). A courtesy check, not a lock: the sudoers rule would let the
    /// helper run without it. What protects root is the helper's fixed verbs,
    /// its root-owned list of servers, and an openconnect only root can change.
    private func confirm(_ reason: String) async -> Bool {
        do {
            return try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch let e as LAError where [.userCancel, .appCancel, .systemCancel].contains(e.code) {
            return false
        } catch {
            problem = "Touch ID didn’t work: \(error.localizedDescription)"
            return false
        }
    }

    /// Says what actually failed: the helper's exit code and stderr first,
    /// openconnect's log only when openconnect ran.
    private func explain(_ r: Shell.Result, id: String?, fallback: String) -> String {
        if r.err.contains("password is required") {
            return "The sudoers rule for the helper isn’t installed. See the README."
        }
        let why: String
        switch r.status {
        case 0: why = fallback
        case 70: why = "The helper’s openconnect, or one of its files, is missing or could be changed by someone other than root. Install VPuNinst again."
        case 64: why = "The helper rejected the request (\(r.err))."
        case 65: why = "The sign-in didn’t return a usable cookie (\(r.err))."
        case 66: why = "The helper doesn’t know this institution. Add it again."
        default:
            why = r.err.isEmpty ? "\(fallback) (exit \(r.status))" : "\(fallback)\n\nexit \(r.status): \(r.err)"
        }
        // The helper's own refusals come before openconnect runs.
        guard let id, ![64, 65, 66, 70, 75].contains(r.status) else { return why }
        let log = Probe.logTail(id, 3)
        return log.isEmpty ? why : "\(why)\n\n\(log)"
    }

    func bringForward() {
        NSApp.activate(ignoringOtherApps: true)
        for w in NSApp.windows where w.identifier?.rawValue.contains("main") == true || w.canBecomeMain {
            w.makeKeyAndOrderFront(nil)
        }
    }
}
