// VPuNinst. Copyright (c) 2026 Riccardo Nevoso. GPL-3.0-or-later; see LICENSE.
import SwiftUI

struct MainView: View {
    @EnvironmentObject var vpn: Tunnels
    @ObservedObject private var splash = Splash.cover
    @State private var form: FormTarget?
    @State private var removing: Institution?

    /// The institution form, for a new one or an existing one.
    enum FormTarget: Identifiable {
        case add, edit(Institution)
        var id: String { if case .edit(let i) = self { return i.id }; return "" }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 34)
                .padding(.bottom, 22)
            VStack(spacing: 12) {
                if !vpn.helperReady { SetupCard() }
                if vpn.institutions.isEmpty {
                    EmptyCard { form = .add }
                } else {
                    ForEach(vpn.institutions) { i in
                        InstitutionCard(institution: i, edit: { form = .edit(i) }, remove: { removing = i })
                    }
                    addButton
                }
                if let p = vpn.problem { ProblemNote(text: p) }
                options
                    .padding(.top, 2)
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 18)
            signature
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.ivory)
        .preferredColorScheme(.light)
        .sheet(item: $form) { t in
            InstitutionForm(original: { if case .edit(let i) = t { return i }; return nil }())
                .environmentObject(vpn)
        }
        .background {
            // A sheet of its own view: SwiftUI shows one sheet per view.
            Color.clear
                .sheet(isPresented: Binding(get: { vpn.signIn != nil && !splash.covering },
                                            set: { if !$0 { vpn.cancelSignIn() } })) {
                    LoginSheet().environmentObject(vpn)
                }
        }
        .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { i in
            Button("Remove", role: .destructive) {
                if let e = vpn.remove(i), !e.isEmpty { vpn.problem = e }
            }
        } message: { _ in
            Text("Its tunnel is disconnected, and its saved password and sign-in cookies are deleted. Removing it takes your administrator password.")
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            FlakeMark()
                .frame(width: 60, height: 60)
                .accessibilityHidden(true)
            Text(Brand.name).house(24, .bold)
            Text(summary).house(11.5, .regular, Theme.inkSoft)
        }
    }

    private var summary: String {
        let n = vpn.institutions.count
        let up = vpn.institutions.filter { vpn[$0.id].isUp }.count
        if n == 0 { return "Your institutions’ VPNs" }
        return up == 0 ? (n == 1 ? "1 institution" : "\(n) institutions") : "\(up) of \(n) connected"
    }

    private var addButton: some View {
        Button { form = .add } label: {
            Label { Text("Add institution…").house(13, .medium, Theme.caramel) } icon: {
                Image(systemName: "plus").foregroundStyle(Theme.caramel)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.caramel.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .disabled(!vpn.helperReady)
        .opacity(vpn.helperReady ? 1 : 0.45)
    }

    private var options: some View {
        VStack(spacing: 0) {
            OptionRow(title: "Keep connected",
                      detail: "Sign in again when a session ends",
                      isOn: $vpn.keepConnected)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            OptionRow(title: "Remember passwords",
                      detail: "Kept in your keychain; filled only on the page they were typed on",
                      isOn: $vpn.rememberPassword)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            OptionRow(title: "Show latency",
                      detail: "Pings each institution’s DNS server every 20 s while connected",
                      isOn: $vpn.showLatency)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            OptionRow(title: "Open at login",
                      detail: "Watch the tunnels from the menu bar",
                      isOn: Binding(get: { vpn.openAtLogin }, set: { vpn.setOpenAtLogin($0) }))
        }
        .padding(.horizontal, 14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var signature: some View {
        VStack(spacing: 3) {
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.bottom, 12)
            Text("Riccardo Nevoso").house(13, .medium)
            Text("\(Brand.name) \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .house(10.5, .regular, Theme.inkSoft)
            Text("Independent · not affiliated with any institution · no warranty")
                .house(10.5, .regular, Theme.inkSoft)
        }
        .padding(.bottom, 16)
    }
}

struct InstitutionCard: View {
    @EnvironmentObject var vpn: Tunnels
    let institution: Institution
    let edit: () -> Void
    let remove: () -> Void

    private var s: Tunnels.Status { vpn[institution.id] }
    private var active: Bool { s.isUp || s.state == .reconnecting }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                StatusRing(up: s.isUp, working: s.isWorking)
                VStack(alignment: .leading, spacing: 3) {
                    Text(institution.name).house(15, .bold).lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(detail).house(11.5, .regular, Theme.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .help(s.interface.map { "Tunnel interface \($0)" } ?? institution.server)
                Spacer(minLength: 6)
                button
                    .fixedSize()
                Menu {
                    Button("Edit…", action: edit)
                    Button("Remove…", role: .destructive, action: remove)
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(Theme.inkSoft)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!vpn.helperReady)
                .accessibilityLabel("More for \(institution.name)")
            }
            ForEach(notes, id: \.self) { n in
                Text(n).house(11, .regular, Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let p = s.problem { ProblemNote(text: p) }
        }
        .padding(14)
        .background(s.isUp ? Theme.caramelTint : Theme.card,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(s.isUp ? Theme.caramel.opacity(0.35) : .clear, lineWidth: 1))
        .contextMenu {
            Button("Edit…", action: edit)
            Button("Remove…", role: .destructive, action: remove)
        }
    }

    private var button: some View {
        Button {
            active ? vpn.disconnect(institution.id) : vpn.connect(institution.id)
        } label: {
            Text(active ? "Disconnect" : "Connect")
                .house(12.5, .bold, active ? Theme.caramel : Theme.ivory)
                .padding(.horizontal, 12)
                .frame(height: 28)
                // The outline as two fills, caramel under ivory: a stroked
                // capsule left marks beside its ends.
                .background {
                    Capsule().fill(Theme.caramel)
                    if active { Capsule().fill(Theme.ivory).padding(1.25) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .disabled(!vpn.helperReady || [.checking, .signingIn, .connecting, .disconnecting].contains(s.state))
        .opacity(vpn.helperReady ? 1 : 0.45)
    }

    private var detail: String {
        switch s.state {
        case .checking: return "Checking…"
        case .disconnected: return "Not connected · \(institution.host)"
        case .signingIn:
            if vpn.signIn?.institution.id == institution.id { return "Finish the sign-in" }
            return "Waiting for the gateway"
        case .connecting: return "Starting the tunnel…"
        case .connected:
            guard let since = s.since else { return "Connected" }
            let mins = Int(Date().timeIntervalSince(since) / 60)
            let dur = mins < 60 ? "\(mins) min" : "\(mins / 60) h \(mins % 60) min"
            let rtt = s.latency.map { " · \(Int($0.rounded())) ms" } ?? ""
            return "Since \(since.formatted(date: .omitted, time: .shortened)) · \(dur)\(rtt)"
        case .reconnecting: return "The network changed; picking the tunnel back up"
        case .disconnecting: return "Disconnecting…"
        }
    }

    /// What this tunnel doesn't reach, or reaches more of than its own.
    private var notes: [String] {
        guard s.isUp else { return [] }
        var n: [String] = []
        if !s.clash.isEmpty {
            n.append("Another tunnel already holds \(s.clash.joined(separator: ", ")), so those addresses stay with it.")
        }
        if !s.overlaps.isEmpty {
            n.append("Shares addresses with \(s.overlaps.joined(separator: " and ")): each goes to the tunnel with the narrower range.")
        }
        if !s.taken.isEmpty {
            n.append("Another tunnel already answers for \(s.taken.joined(separator: ", ")), so those names stay with it.")
        }
        if s.noDomain {
            n.append("The gateway named no DNS domain, so its DNS isn’t used. Add the institution’s domains with Edit.")
        }
        if s.full { n.append("Carries all your traffic, not only the institution’s.") }
        return n
    }
}

struct StatusRing: View {
    let up: Bool
    let working: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().strokeBorder(up ? Theme.caramel : Theme.neutral, lineWidth: 2)
            if up { Circle().fill(Theme.caramel).padding(5) }
            if working && !reduceMotion {
                Circle().strokeBorder(Theme.caramel, lineWidth: 2)
                    .scaleEffect(pulse ? 1.6 : 1).opacity(pulse ? 0 : 0.8)
                    .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: pulse)
            }
        }
        .frame(width: 20, height: 20)
        .onAppear { pulse = true }
        .accessibilityHidden(true)
    }
}

struct SetupCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label { Text("One-time setup needed").house(14, .bold) } icon: {
                Image(systemName: "touchid").foregroundStyle(Theme.caramel)
            }
            Text("The helper or its sudoers rule isn’t installed yet. The \(Brand.name) installer sets both up; built from source, the README has the commands to run.")
                .house(12, .regular, Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.caramelTint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct EmptyCard: View {
    @EnvironmentObject var vpn: Tunnels
    let add: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("No institutions yet").house(14, .bold)
                Text("Add the VPN of a university, a research institute or a hospital you belong to. Its instructions give the server address and the kind of VPN.")
                    .house(12, .regular, Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: add) {
                Text("Add institution…")
                    .house(15, .bold, Theme.ivory)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(Theme.caramel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
            .disabled(!vpn.helperReady)
            .opacity(vpn.helperReady ? 1 : 0.45)
            .keyboardShortcut(.defaultAction)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ProblemNote: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.ink)
            Text(text).house(12, .regular).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.ivory.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct OptionRow: View {
    let title: String, detail: String
    @Binding var isOn: Bool
    // On macOS a switch sits right after its label, so each one would land
    // wherever its text ends. Text and switch are laid out here instead, the
    // switch pinned to the trailing edge; the label stays for VoiceOver.
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).house(13.5, .medium)
                Text(detail).house(11.5, .regular, Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.caramel)
                .focusEffectDisabled()
        }
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}

/// Adds an institution, or changes one. What it asks for is what the
/// institution's own VPN instructions give: the server and the kind of VPN.
struct InstitutionForm: View {
    @EnvironmentObject var vpn: Tunnels
    @Environment(\.dismiss) private var dismiss
    let original: Institution?

    @State private var name = ""
    @State private var kind: Vendor = .gp
    @State private var server = ""
    @State private var option = ""
    @State private var domains = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(original == nil ? "Add an institution" : "Edit \(original!.name)").house(17, .bold)
            field("Name", $name, prompt: "Shown in the window and the menu")
            VStack(alignment: .leading, spacing: 5) {
                Text("VPN").house(12, .medium)
                Picker("VPN", selection: $kind) {
                    ForEach(Vendor.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .onChange(of: kind) { _, k in option = k == .gp ? "portal" : "" }
            }
            field("Server", $server, prompt: "vpn.example.edu")
            if let o = kind.option {
                VStack(alignment: .leading, spacing: 5) {
                    if kind == .gp {
                        Text(o.label).house(12, .medium)
                        Picker(o.label, selection: $option) {
                            Text("Portal").tag("portal")
                            Text("Gateway").tag("gateway")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .tint(Theme.caramel)
                    } else {
                        field(o.label, $option, prompt: "Optional")
                    }
                    Text(o.help).house(11, .regular, Theme.inkSoft).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                field("Internal domains", $domains, prompt: "Optional, e.g. example.edu, intra.example.edu")
                Text("Names under these domains are looked up through the institution’s own DNS. The VPN usually sends its own; add any it leaves out.")
                    .house(11, .regular, Theme.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
            if !kind.tested {
                Text("Not yet tried against a real \(kind.title) gateway. If the sign-in or the tunnel fails, the app’s log says where.")
                    .house(11, .regular, Theme.inkSoft).fixedSize(horizontal: false, vertical: true)
            }
            if let error { ProblemNote(text: error) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(original == nil ? "Add…" : "Save…") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(invalid != nil)
                    .help(invalid ?? "Takes your administrator password")
            }
        }
        .padding(22)
        .frame(width: 400)
        .background(Theme.ivory)
        .onAppear(perform: load)
    }

    private func field(_ label: String, _ text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).house(12, .medium)
            TextField(label, text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }
    }

    private func load() {
        guard let i = original else { option = "portal"; return }
        name = i.name
        kind = i.vpn
        server = i.server
        option = i.option ?? (i.vpn == .gp ? "portal" : "")
        domains = i.domains.joined(separator: ", ")
    }

    // What the helper is given: no scheme, no trailing slash, domains as a list.
    private var cleanServer: String {
        var s = server.trimmingCharacters(in: .whitespaces)
        for p in ["https://", "http://"] where s.lowercased().hasPrefix(p) { s.removeFirst(p.count) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
    private var cleanDomains: [String] {
        domains.split(whereSeparator: { $0 == "," || $0 == " " }).map { $0.lowercased() }
            .map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
    }
    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanOption: String? {
        let o = option.trimmingCharacters(in: .whitespaces)
        return o.isEmpty || kind.option == nil ? nil : o
    }

    private var invalid: String? {
        if !Check.name(cleanName) { return "The name should be 1 to 64 characters." }
        if !Check.server(cleanServer) { return "The server should be a host name, with a port or a path if the instructions give one." }
        if let o = cleanOption, !Check.option(o) { return "The \(kind.option?.label.lowercased() ?? "option") can hold letters, digits, dots, dashes and underscores." }
        if !cleanDomains.isEmpty && !Check.domains(cleanDomains.joined(separator: ",")) { return "Each domain should look like example.edu." }
        return nil
    }

    private func save() {
        let taken = Set(vpn.institutions.map(\.id))
        // A portal's gateways stay allowed only while it is the same portal.
        let same = original.map { $0.vpn == kind && $0.server == cleanServer && $0.option == cleanOption } ?? false
        let i = Institution(id: original?.id ?? Institution.newID(for: cleanName, taken: taken), vpn: kind,
                            server: cleanServer, option: cleanOption, domains: cleanDomains, name: cleanName,
                            gateways: same ? original?.gateways ?? [] : [])
        switch vpn.save(i, isNew: original == nil) {
        case nil: dismiss()
        case "": break
        case let e?: error = e
        }
    }
}

struct LoginSheet: View {
    @EnvironmentObject var vpn: Tunnels
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to \(vpn.signIn?.institution.name ?? "")").house(15, .bold)
                Spacer()
                Button("Cancel") { vpn.cancelSignIn() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(Theme.ivory)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if let r = vpn.signIn, let page = vpn.page(for: r) {
                SignInWebView(page: page)
                    // A new sign-in is a new page, not this one updated.
                    .id(r.id)
            }
        }
        .frame(width: 520, height: 640)
    }
}

struct MenuContent: View {
    @EnvironmentObject var vpn: Tunnels
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let up = vpn.institutions.filter { vpn[$0.id].isUp }.count
        Text(up == 0 ? "\(Brand.name) — Not connected" : "\(Brand.name) — \(up) connected")
        if !vpn.institutions.isEmpty { Divider() }
        ForEach(vpn.institutions) { i in
            let s = vpn[i.id]
            if s.isUp || s.state == .reconnecting {
                Button("Disconnect \(i.name)") { vpn.disconnect(i.id) }
            } else {
                Button("Connect \(i.name)") { openWindow(id: "main"); vpn.connect(i.id) }
                    .disabled(!vpn.helperReady || s.isWorking)
            }
        }
        Divider()
        Button("Open \(Brand.name)…") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        // Only once every tunnel is down: quitting would leave tunnels nobody watches.
        if vpn.allIdle {
            Divider()
            Button("Quit \(Brand.name)") { NSApp.terminate(nil) }
        }
    }
}
