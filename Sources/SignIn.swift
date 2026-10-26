// VPuNinst. Copyright (c) 2026 Riccardo Nevoso. GPL-3.0-or-later; see LICENSE.
import SwiftUI
import WebKit

/// What openconnect is handed once the sign-in is done.
struct Credential {
    /// Palo Alto's prelogin-cookie or portal-userauthcookie; "cookie" for the rest.
    let kind: String
    /// In the exact shape the helper checks for each protocol.
    let cookie: String
    /// Palo Alto names the account in its reply; the others need none.
    let username: String?
}

/// One institution's sign-in: what the web view loads first, and how it
/// knows the sign-in is done. The page in between is the institution's own.
struct SignInRequest: Identifiable {
    let id = UUID()
    let institution: Institution
    let html: String?
    let url: URL?
    let finish: Finish
    /// Palo Alto: the portal's gateway this sign-in is for, whose reply ends
    /// it; nil for the institution's own server.
    var gateway: String? = nil
    /// Palo Alto: the region the server places this Mac in, which ranks a
    /// portal's gateways.
    var region: String? = nil

    enum Finish {
        /// The gateway's reply carries the cookie and the username, as response
        /// headers or as tags in the page.
        case paloAlto(portal: Bool)
        /// A token cookie, read when the page reaches the final URL, then
        /// exchanged for the session (see `SignIn.ciscoSession`).
        case cisco(Cisco)
        /// A session cookie the gateway sets on its own host.
        case cookies
    }

    struct Cisco {
        let endpoint: URL
        let final: String
        let tokenCookie: String
        let errorCookie: String?
        /// Sent back exactly as the gateway sent it.
        let opaque: String
        /// Holds the cookies of the first exchange for the second.
        let session: URLSession
    }
}

/// How each protocol starts a sign-in, and how the app knows it is done.
enum SignIn {
    enum Failure: LocalizedError {
        case address, unreachable(String), noSSO(String), refused(String)
        var errorDescription: String? {
            switch self {
            case .address: return "The server address isn’t usable."
            case .unreachable(let m): return "Couldn’t reach the VPN gateway. \(m)"
            case .noSSO(let what): return "The gateway replied without a sign-in page (\(what)). Its sign-in method may not be a web one, or the VPN type may be wrong."
            case .refused(let m): return "The gateway refused the sign-in: \(m)"
            }
        }
    }

    /// Cisco's gateways are asked for a session under the agent name they look
    /// for; the helper sets up the tunnel with the same one.
    static let ciscoAgent = "AnyConnect-compatible OpenConnect VPN Agent"

    static func start(_ i: Institution) async throws -> SignInRequest {
        guard let base = i.baseURL, let host = base.host else { throw Failure.address }
        let origin = "https://\(host)\(base.port.map { ":\($0)" } ?? "")"
        switch i.vpn {
        case .gp:
            return try await paloAlto(i, origin: origin)
        case .anyconnect:
            return try await cisco(i, groupAccess: base)
        case .fortinet:
            var c = URLComponents(string: "\(origin)/remote/saml/start")
            if let realm = i.option { c?.queryItems = [URLQueryItem(name: "realm", value: realm)] }
            guard let u = c?.url else { throw Failure.address }
            return SignInRequest(institution: i, html: nil, url: u, finish: .cookies)
        case .nc, .pulse, .f5:
            return SignInRequest(institution: i, html: nil, url: base, finish: .cookies)
        }
    }

    // MARK: Palo Alto

    private static func paloAlto(_ i: Institution, origin: String) async throws -> SignInRequest {
        try await paloAlto(i, origin: origin, portal: i.option == "portal", gateway: nil)
    }

    /// The sign-in of a gateway a portal sends the tunnel to, when the portal
    /// hands out no cookie for it. It goes through the same identity
    /// provider, which usually still knows you, so the page ends by itself.
    static func gateway(_ i: Institution, _ gateway: String) async throws -> SignInRequest {
        try await paloAlto(i, origin: "https://\(gateway)", portal: false, gateway: gateway)
    }

    /// prelogin.esp hands back the identity provider's request: a page to
    /// post, or an address to load.
    private static func paloAlto(_ i: Institution, origin: String, portal: Bool,
                                 gateway: String?) async throws -> SignInRequest {
        let path = portal ? "global-protect" : "ssl-vpn"
        var req = URLRequest(url: URL(string: "\(origin)/\(path)/prelogin.esp?tmp=tmp&clientVer=4100&clientos=Mac")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        // The agent name a portal expects from a VPN client. A portal serves
        // browsers too, and a sign-in it takes for a browser's ends on its
        // download page instead of handing back the cookie.
        req.setValue("PAN GlobalProtect", forHTTPHeaderField: "User-Agent")
        let xml = try await fetch(req)
        guard let b64 = tag("saml-request", in: xml),
              let decoded = Data(base64Encoded: b64.trimmingCharacters(in: .whitespacesAndNewlines),
                                 options: .ignoreUnknownCharacters) else { throw Failure.noSSO("no SAML request") }
        let body = String(decoding: decoded, as: UTF8.self)
        let region = tag("region", in: xml)
        if tag("saml-auth-method", in: xml)?.uppercased() == "REDIRECT", let u = URL(string: body) {
            return SignInRequest(institution: i, html: nil, url: u, finish: .paloAlto(portal: portal),
                                 gateway: gateway, region: region)
        }
        return SignInRequest(institution: i, html: body, url: URL(string: "\(origin)/"), finish: .paloAlto(portal: portal),
                             gateway: gateway, region: region)
    }

    /// What a portal says once signed in: its gateways, best first, and the
    /// cookie they take in place of a sign-in of their own, if it hands one out.
    struct Portal {
        let gateways: [String]
        let cookie: String?
    }

    /// Asks the portal for its settings, as a VPN client does right after
    /// signing in to it.
    static func portal(_ r: SignInRequest, _ c: Credential, user: String) async throws -> Portal {
        guard let base = r.institution.baseURL, let host = base.host else { throw Failure.address }
        let origin = "https://\(host)\(base.port.map { ":\($0)" } ?? "")"
        var req = URLRequest(url: URL(string: "\(origin)/global-protect/getconfig.esp")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("PAN GlobalProtect", forHTTPHeaderField: "User-Agent")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = [("jnlpReady", "jnlpReady"), ("ok", "Login"), ("direct", "yes"), ("clientVer", "4100"),
                      ("prot", "https:"), ("internal", "no"), ("ipv6-support", "yes"), ("clientos", "Mac"),
                      ("os-version", "mac-intel"), ("server", host), ("computer", ProcessInfo.processInfo.hostName),
                      ("user", user), (c.kind, c.cookie)]
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        req.httpBody = Data(fields.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
        let xml = try await fetch(req)
        guard let p = parsePortal(xml, region: r.region) else {
            throw Failure.refused(tag("error", in: xml) ?? "the portal didn’t send its settings")
        }
        return p
    }

    /// The portal's reply: `policy`, with the gateways under
    /// gateways/external/list, each ranked by its priority for this region or
    /// for any, lowest first, and in the portal's own order otherwise.
    static func parsePortal(_ xml: String, region: String?) -> Portal? {
        guard let doc = try? XMLDocument(xmlString: xml), let policy = doc.rootElement(), policy.name == "policy"
        else { return nil }
        let entries = (try? policy.nodes(forXPath: "gateways/external/list/entry")) as? [XMLElement] ?? []
        let ranked = entries.enumerated().compactMap { n, e -> (priority: Int, n: Int, name: String)? in
            guard let name = e.attribute(forName: "name")?.stringValue, Check.gateway(name) else { return nil }
            let rules = (try? e.nodes(forXPath: "priority-rule/entry")) as? [XMLElement] ?? []
            let priority = rules.filter {
                let r = $0.attribute(forName: "name")?.stringValue
                return r == "Any" || (region != nil && r == region)
            }.compactMap { $0.elements(forName: "priority").first?.stringValue
                .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } }.min() ?? Int.max
            return (priority, n, name)
        }.sorted { ($0.priority, $0.n) < ($1.priority, $1.n) }
        return Portal(gateways: ranked.map(\.name), cookie: tag("portal-userauthcookie", in: xml))
    }

    static func tag(_ name: String, in s: String) -> String? {
        guard let a = s.range(of: "<\(name)>"), let b = s.range(of: "</\(name)>", range: a.upperBound..<s.endIndex)
        else { return nil }
        let v = String(s[a.upperBound..<b.lowerBound])
        return v.isEmpty || v == "empty" ? nil : v
    }

    // MARK: Cisco

    /// The XML exchange a Cisco gateway signs in with, offering only single
    /// sign-on v2: offered the external-browser kind too, a gateway sends the
    /// token to a local port instead of leaving it in a cookie.
    private static func cisco(_ i: Institution, groupAccess: URL) async throws -> SignInRequest {
        let session = URLSession(configuration: .ephemeral)
        let group = i.option.map { "<group-select>\(escape($0))</group-select>" } ?? ""
        let body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <config-auth client="vpn" type="init" aggregate-auth-version="2"><version who="vpn">v9.21</version>\
        <device-id>mac-intel</device-id><capabilities><auth-method>single-sign-on-v2</auth-method></capabilities>\
        <group-access>\(escape(groupAccess.absoluteString))</group-access>\(group)</config-auth>
        """
        let doc = try await ciscoPost(groupAccess, body, session)
        guard let login = text("//sso-v2-login", doc).flatMap(URL.init(string:)),
              let final = text("//sso-v2-login-final", doc),
              let token = text("//sso-v2-token-cookie-name", doc),
              let opaque = (try? doc.nodes(forXPath: "//opaque").first as? XMLElement)?.xmlString
        else {
            throw Failure.noSSO(text("//error", doc) ?? "no single sign-on offered")
        }
        let c = SignInRequest.Cisco(endpoint: groupAccess, final: final, tokenCookie: token,
                                    errorCookie: text("//sso-v2-error-cookie-name", doc), opaque: opaque, session: session)
        return SignInRequest(institution: i, html: nil, url: login, finish: .cisco(c))
    }

    /// The token, traded for the session cookie openconnect connects with.
    static func ciscoSession(_ c: SignInRequest.Cisco, token: String) async throws -> String {
        let body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <config-auth client="vpn" type="auth-reply" aggregate-auth-version="2"><version who="vpn">v9.21</version>\
        <device-id>mac-intel</device-id><session-token/><session-id/>\(c.opaque)\
        <auth><sso-token>\(escape(token))</sso-token></auth></config-auth>
        """
        let doc = try await ciscoPost(c.endpoint, body, c.session)
        guard let s = text("//session-token", doc) else {
            throw Failure.refused(text("//error", doc) ?? "no session in its reply")
        }
        // openconnect splits a cookie at its first '=', and a bare token can end in one.
        return "webvpn=\(s)"
    }

    private static func ciscoPost(_ url: URL, _ body: String, _ session: URLSession) async throws -> XMLDocument {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.httpBody = Data(body.utf8)
        for (k, v) in ["Content-Type": "application/xml; charset=utf-8", "X-Aggregate-Auth": "1",
                       "X-Transcend-Version": "1", "Accept": "*/*", "Accept-Encoding": "identity",
                       "User-Agent": ciscoAgent] {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let xml = try await fetch(req, session)
        guard let doc = try? XMLDocument(xmlString: xml) else { throw Failure.noSSO("a reply that isn’t XML") }
        return doc
    }

    private static func text(_ path: String, _ doc: XMLDocument) -> String? {
        guard let s = (try? doc.nodes(forXPath: path))?.first?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func fetch(_ req: URLRequest, _ session: URLSession = .shared) async throws -> String {
        do { return String(decoding: try await session.data(for: req).0, as: UTF8.self) }
        catch { throw Failure.unreachable(error.localizedDescription) }
    }

    // MARK: Cookies

    /// The session cookie each of the remaining protocols signs in with, once
    /// it is really there. The traps: MRHSession is set over and over before
    /// F5's sign-in ends, so F5_ST must be there too; Fortinet sets SVPNCOOKIE
    /// before its page about other open sessions, so the portal must have
    /// loaded; Juniper and Ivanti set other DS cookies first, and only DSID
    /// counts.
    static func sessionCookie(_ vpn: Vendor, host: String, page: URL?, cookies: [HTTPCookie]) -> String? {
        func value(_ name: String) -> String? { cookie(name, host: host, in: cookies) }
        switch vpn {
        case .fortinet:
            guard let v = value("SVPNCOOKIE"), let page, page.host?.lowercased() == host.lowercased(),
                  page.path.range(of: "^/sslvpn/portal(/|\\.html|$)", options: .regularExpression) != nil else { return nil }
            return "SVPNCOOKIE=\(v)"
        case .nc: return value("DSID").map { "DSID=\($0)" }
        // Ivanti's own protocol takes the bare value.
        case .pulse: return value("DSID")
        case .f5:
            guard let m = value("MRHSession"), let s = value("F5_ST") else { return nil }
            return "MRHSession=\(m); F5_ST=\(s)"
        case .gp, .anyconnect: return nil
        }
    }

    /// A cookie the gateway set for its own host. Not one set for a parent
    /// domain: any other host under it, a page in the sign-in among them,
    /// could have set that one, and hand the app a session of its choosing.
    static func cookie(_ name: String, host: String, in cookies: [HTTPCookie]) -> String? {
        let h = host.lowercased()
        return cookies.first { c in
            let d = c.domain.lowercased()
            return c.name == name && !c.value.isEmpty && (d == h || d == "." + h)
        }?.value
    }
}

/// The sheet's view of a sign-in's page.
struct SignInWebView: NSViewRepresentable {
    let page: Page

    /// The capture and fill scripts run in a world of their own: they see the
    /// page, but the page's own scripts can't see them, or post to them.
    private static let world = WKContentWorld.world(name: "vpuninst")

    /// Reports the username and password when a form with a password field is
    /// submitted. Swift decides whether to keep them (see userContentController).
    private static let capture = """
    document.addEventListener('submit', function (e) {
      var f = e.target, p = f.querySelector('input[type=password]');
      if (!p || !p.value) return;
      var u = f.querySelector('input[type=email], input[autocomplete=username], input[name*=user i], input[type=text]');
      window.webkit.messageHandlers.vpuninstLogin.postMessage({ u: u ? u.value : '', p: p.value });
    }, true);
    """

    /// Each institution's data store, made once and kept while the app runs.
    /// WebKit keeps a store's session cookies only while something holds the
    /// store, and an identity provider's session is usually one of them: with
    /// a store per sheet, the sign-in at the gateway a portal sends the tunnel
    /// to would ask for the password again, seconds after the portal's.
    private static var stores: [UUID: WKWebsiteDataStore] = [:]

    static func store(_ i: Institution) -> WKWebsiteDataStore {
        let id = i.dataStoreID
        if let s = stores[id] { return s }
        let s = WKWebsiteDataStore(forIdentifier: id)
        stores[id] = s
        return s
    }

    /// Lets go of an institution's store; WebKit deletes only one not in use.
    static func release(_ i: Institution) { stores[i.dataStoreID] = nil }

    /// Deletes what an institution's sign-in pages kept, cookies held only
    /// in memory included, so the next sign-in starts at the first page.
    static func forget(_ i: Institution) async {
        await store(i).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    func makeNSView(context: Context) -> WKWebView { page.view }

    func updateNSView(_ v: WKWebView, context: Context) {}

    /// A sign-in's page: the web view and what watches it, from the first
    /// load to the credential. It outlives the sheet's view of it, so a
    /// sign-in can load out of sight and be shown as it stands once it waits
    /// for you.
    @MainActor
    final class Page: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let request: SignInRequest
        let view: WKWebView
        let remember: Bool
        let done: (Credential) -> Void
        let failed: (String) -> Void
        var finished = false
        /// Set while the page loads out of sight: called, once, when it waits
        /// for you.
        private var needsYou: (() -> Void)?
        private var waiting: Task<Void, Never>?
        /// Submitted once per sign-in: if the form comes back (a changed
        /// password), it is filled but left for you, so it can't loop.
        var submitted = false
        /// Cisco's token, from the moment its cookie appears.
        var token: String?
        /// The saved sign-in, read once per sign-in and off the main thread.
        /// After a rebuild the keychain asks before handing it over, and read
        /// on the main thread that froze the whole app until the dialog was
        /// answered. Read once, a sign-in that loads several pages asks once.
        private var saved: Task<SavedLogin.Login?, Never>?

        private var institution: Institution { request.institution }

        /// How long a sign-in out of sight may go on before it is shown
        /// anyway. One that ends by itself takes a second or two.
        private static let patience: Duration = .seconds(6)

        /// With `needsYou`, the page loads out of sight until it waits for you.
        init(request: SignInRequest, remember: Bool, done: @escaping (Credential) -> Void,
             failed: @escaping (String) -> Void, needsYou: (() -> Void)? = nil) {
            self.request = request
            self.remember = remember
            self.done = done
            self.failed = failed
            self.needsYou = needsYou
            let cfg = WKWebViewConfiguration()
            cfg.websiteDataStore = SignInWebView.store(request.institution)
            if remember {
                cfg.userContentController.addUserScript(WKUserScript(
                    source: SignInWebView.capture, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: SignInWebView.world))
            }
            // The sheet's size, so a page out of sight is laid out as it would be shown.
            view = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 595), configuration: cfg)
            super.init()
            if remember {
                view.configuration.userContentController.add(self, contentWorld: SignInWebView.world, name: "vpuninstLogin")
            }
            view.navigationDelegate = self
            if let html = request.html {
                view.loadHTMLString(html, baseURL: request.url)
            } else if let u = request.url {
                view.load(URLRequest(url: u))
            }
            if needsYou != nil {
                waiting = Task { [weak self] in
                    guard (try? await Task.sleep(for: Self.patience)) != nil else { return }
                    self?.reveal()
                }
            }
        }

        /// Ends the page: nothing more is reported, and the message handler,
        /// which the content controller holds strongly, is let go.
        func close() {
            if !finished { trace("closed") }
            finished = true
            needsYou = nil
            waiting?.cancel()
            view.navigationDelegate = nil
            view.configuration.userContentController.removeAllScriptMessageHandlers()
        }

        /// Shows a page that was loading out of sight, once.
        private func reveal() {
            guard !finished, let n = needsYou else { return }
            trace("waits for you at \(Self.place(view.url))")
            needsYou = nil
            waiting?.cancel()
            n()
        }

        /// A page out of sight is shown once it stays put with something on it
        /// to fill in or press. Half a second on, a page that sends itself
        /// onwards, as those between a sign-in's two ends do, is loading the next.
        private func lookForYou(_ w: WKWebView) {
            let page = w.url
            Task { [weak self, weak w] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, let w, self.needsYou != nil, !w.isLoading, w.url == page else { return }
                let js = """
                Array.prototype.some.call(document.querySelectorAll('input:not([type=hidden]), select, textarea, button'),
                  function (e) { return e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden'; })
                """
                w.evaluateJavaScript(js, in: nil, in: SignInWebView.world) { [weak self] res in
                    if case .success(let v) = res, (v as? Bool) == true { self?.reveal() }
                }
            }
        }

        private func savedLogin() async -> SavedLogin.Login? {
            let id = institution.id
            let t = saved ?? Task.detached(priority: .userInitiated) { SavedLogin.load(id) }
            saved = t
            return await t.value
        }

        /// A password is kept for the https host it was typed on, the one
        /// WebKit reports for the frame, not one the page could claim, and
        /// only from the page itself, never a frame inside it.
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            let origin = m.frameInfo.securityOrigin
            guard remember, m.frameInfo.isMainFrame, origin.protocol == "https", !origin.host.isEmpty,
                  let body = m.body as? [String: String],
                  let u = body["u"], !u.isEmpty, let p = body["p"], !p.isEmpty else { return }
            let login = SavedLogin.Login(username: u, password: p, host: origin.host)
            let id = institution.id, name = institution.name
            Task { @MainActor in
                if let old = await savedLogin(), old == login { return }
                saved = Task { login }
                await Task.detached(priority: .utility) { SavedLogin.save(login, for: id, name: name) }.value
            }
        }

        /// Only a page that asks for a password reads the saved one: after a
        /// rebuild the keychain asks first, and a sign-in that ends by itself,
        /// out of sight, shouldn't make it ask.
        private func fill(_ w: WKWebView) {
            guard remember, let page = w.url, page.scheme == "https" else { return }
            let asks = "document.querySelector('input[type=password]') !== null"
            w.evaluateJavaScript(asks, in: nil, in: SignInWebView.world) { [weak self, weak w] res in
                guard case .success(let v) = res, (v as? Bool) == true else { return }
                Task { @MainActor in
                    // The page may have moved on while the keychain was asked.
                    guard let self, let l = await self.savedLogin(), let w, w.url == page, page.host == l.host else { return }
                    self.fill(w, with: l)
                }
            }
        }

        /// Fills the form with JSON-encoded values, so nothing in the password
        /// can break out of the string, and checks the page's host again itself.
        private func fill(_ w: WKWebView, with l: SavedLogin.Login) {
            guard let data = try? JSONSerialization.data(withJSONObject: [l.username, l.password, l.host]),
                  let args = String(data: data, encoding: .utf8) else { return }
            let submit = !submitted
            let js = """
            (function (a, submit) {
              if (location.protocol !== 'https:' || location.hostname !== a[2]) return false;
              var p = document.querySelector('input[type=password]');
              if (!p) return false;
              var f = p.form || document;
              var u = f.querySelector('input[type=email], input[autocomplete=username], input[name*=user i], input[type=text]');
              function set(el, v) {
                Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, v);
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
              }
              if (u && !u.value) set(u, a[0]);
              set(p, a[1]);
              if (submit && p.form) {
                var b = p.form.querySelector('[type=submit]');
                if (b) b.click(); else p.form.requestSubmit ? p.form.requestSubmit() : p.form.submit();
              }
              return true;
            })(\(args), \(submit));
            """
            w.evaluateJavaScript(js, in: nil, in: SignInWebView.world) { [weak self] res in
                guard case .success(let v) = res, (v as? Bool) == true else { return }
                self?.trace(submit ? "filled in the saved sign-in and sent it" : "filled in the saved sign-in")
                if submit { self?.submitted = true }
            }
        }

        /// The cookies the last page's host held, by name, as last logged.
        private var cookieNames: [String]?

        /// A sign-in's steps go to the log, so that one that fails can be
        /// followed afterwards: each page's address without its query, but
        /// for the step a sign-in flow numbers there, its title, and the
        /// names of its host's cookies when they change. Never a value.
        private func trace(_ what: String) {
            let to = request.gateway.map { " at \($0)" } ?? ""
            let hidden = needsYou != nil ? ", out of sight" : ""
            AppLog.write("sign-in \(request.id.uuidString.prefix(4)) to \(institution.id)\(to)\(hidden): \(what)")
        }

        private static func place(_ u: URL?) -> String {
            guard let u, let c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return "-" }
            let step = c.queryItems?.first { $0.name == "execution" }?.value.map { "?execution=\($0)" } ?? ""
            return "\(c.host ?? "-")\(c.path)\(step)"
        }

        private func traceLoaded(_ w: WKWebView) {
            let page = w.url, title = w.title ?? ""
            w.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }
                let host = page?.host?.lowercased() ?? ""
                let names = cookies.filter { c in
                    let d = c.domain.lowercased().drop { $0 == "." }
                    return host == d || host.hasSuffix("." + d)
                }.map(\.name).sorted()
                let changed = names != self.cookieNames
                self.cookieNames = names
                self.trace("loaded “\(title)” at \(Self.place(page))" + (changed ? ", cookies: \(names.isEmpty ? "none" : names.joined(separator: " "))" : ""))
            }
        }

        func finish(_ c: Credential) {
            guard !finished else { return }
            finished = true
            done(c)
        }

        func fail(_ m: String) {
            guard !finished else { return }
            finished = true
            failed(m)
        }

        /// Whether a page is the gateway's own: the sign-in is done only when
        /// the gateway says so, not when a page on the way claims it.
        private func isGateway(_ u: URL?) -> Bool {
            let host = request.gateway.map { String($0.prefix { $0 != ":" }) } ?? institution.host
            return u?.scheme == "https" && u?.host?.lowercased() == host.lowercased()
        }

        func webView(_ w: WKWebView, decidePolicyFor r: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if r.isForMainFrame, let h = r.response as? HTTPURLResponse {
                trace("\(h.statusCode) from \(Self.place(h.url))")
            }
            if case .paloAlto(let portal) = request.finish, r.isForMainFrame, isGateway(r.response.url),
               let h = r.response as? HTTPURLResponse {
                let get = { (name: String) in h.value(forHTTPHeaderField: name).flatMap { $0.isEmpty || $0 == "empty" ? nil : $0 } }
                if let c = paloAlto(get, portal: portal) { finish(c) }
            }
            decisionHandler(.allow)
        }

        func webView(_ w: WKWebView, didFinish nav: WKNavigation!) {
            traceLoaded(w)
            fill(w)
            check(w)
            if needsYou != nil { lookForYou(w) }
        }

        // Cisco's final address need not be a page that loads.
        func webView(_ w: WKWebView, didFail nav: WKNavigation!, withError e: Error) {
            trace("failed at \(Self.place(w.url)): \(e.localizedDescription)")
            check(w)
        }
        func webView(_ w: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError e: Error) {
            trace("failed on the way from \(Self.place(w.url)): \(e.localizedDescription)")
            check(w)
        }

        private func paloAlto(_ get: (String) -> String?, portal: Bool) -> Credential? {
            let user = get("saml-username")
            if let c = get("prelogin-cookie") { return Credential(kind: "prelogin-cookie", cookie: c, username: user) }
            if portal, let c = get("portal-userauthcookie") {
                return Credential(kind: "portal-userauthcookie", cookie: c, username: user)
            }
            return nil
        }

        private func check(_ w: WKWebView) {
            guard !finished else { return }
            let page = w.url
            switch request.finish {
            case .paloAlto(let portal):
                guard isGateway(page) else { return }
                w.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] res, _ in
                    guard let self, let html = res as? String,
                          let c = self.paloAlto({ SignIn.tag($0, in: html) }, portal: portal) else { return }
                    self.finish(c)
                }
            case .cisco(let c):
                let host = institution.host
                w.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                    guard let self, !self.finished else { return }
                    if let e = c.errorCookie, let v = SignIn.cookie(e, host: host, in: cookies) {
                        return self.fail("The sign-in failed: \(v.removingPercentEncoding ?? v)")
                    }
                    // Some identity providers set it empty along the way.
                    if let t = SignIn.cookie(c.tokenCookie, host: host, in: cookies) { self.token = t }
                    guard page?.absoluteString == c.final, let token = self.token else { return }
                    self.finished = true
                    Task { @MainActor in
                        do { self.done(Credential(kind: "cookie", cookie: try await SignIn.ciscoSession(c, token: token), username: nil)) }
                        catch { self.failed(error.localizedDescription) }
                    }
                }
            case .cookies:
                let i = institution
                w.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                    guard let self, let c = SignIn.sessionCookie(i.vpn, host: i.host, page: page, cookies: cookies)
                    else { return }
                    self.finish(Credential(kind: "cookie", cookie: c, username: nil))
                }
            }
        }
    }
}
