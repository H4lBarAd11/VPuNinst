// VPuNinst. Copyright (c) 2026 Riccardo Nevoso. GPL-3.0-or-later; see LICENSE.
import CryptoKit
import Foundation

enum Brand {
    static let name = "VPuNinst"
    /// Prefix of everything the app keeps under its own name: keychain items,
    /// the sign-in data stores.
    static let id = "io.github.h4lbarad11.vpuninst"
}

/// The VPN protocols openconnect signs in to through a web page. Array
/// Networks is the one it speaks without: it takes a username and password only.
enum Vendor: String, CaseIterable, Identifiable {
    case gp, anyconnect, fortinet, nc, pulse, f5

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gp: return "Palo Alto Networks"
        case .anyconnect: return "Cisco"
        case .fortinet: return "Fortinet"
        case .nc: return "Juniper"
        case .pulse: return "Ivanti (Pulse)"
        case .f5: return "F5"
        }
    }

    /// Signed in to a real gateway; the others are untried.
    var tested: Bool { self == .gp }

    /// What the option field means, if anything. Palo Alto's is required.
    var option: (label: String, help: String)? {
        switch self {
        case .gp: return ("Connects to", "A portal hands out gateways; a gateway is connected to directly. The institution's instructions usually say which.")
        case .anyconnect: return ("Group", "The connection group, if the institution names one. Optional.")
        case .fortinet: return ("Realm", "The sign-in realm, if the institution names one. Optional.")
        case .nc, .pulse, .f5: return nil
        }
    }
}

/// A VPN the helper may connect to: one line of the root-owned list, written
/// only through the helper with the administrator's password (see
/// helper/vpuninst-helper). The app reads it and nothing else.
struct Institution: Identifiable, Hashable {
    let id: String
    let vpn: Vendor
    /// Host, optional port and optional path, without a scheme.
    let server: String
    let option: String?
    /// Extra DNS domains, on top of those the gateway names itself.
    let domains: [String]
    let name: String
    /// A Palo Alto portal's gateways on other servers that the helper may
    /// connect to; its own server needs no entry here.
    var gateways: [String] = []

    static let listPath = "/Library/PrivilegedHelperTools/vpuninst-institutions"

    var host: String {
        String(server.prefix { $0 != "/" && $0 != ":" })
    }
    var baseURL: URL? { URL(string: "https://\(server)") }

    /// The helper's own record of the list. An unreadable or missing file is
    /// an empty list, and a line the helper wouldn't accept is skipped.
    static func load() -> [Institution] {
        guard let text = try? String(contentsOfFile: listPath, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 6 || f.count == 7, Check.id(f[0]), let vpn = Vendor(rawValue: f[1]), Check.server(f[2]),
                  Check.option(f[3]), Check.domains(f[4]) else { return nil }
            let gateways = f.count == 7 && f[6] != "-" ? f[6].split(separator: ",").map(String.init) : []
            guard gateways.allSatisfy(Check.gateway) else { return nil }
            return Institution(id: f[0], vpn: vpn, server: f[2], option: f[3] == "-" ? nil : f[3],
                               domains: f[4] == "-" ? [] : f[4].split(separator: ",").map(String.init),
                               name: f[5], gateways: gateways)
        }
    }

    /// The helper's arguments for `add`.
    var addArguments: [String] {
        ["add", id, vpn.rawValue, server, option ?? "-", domains.isEmpty ? "-" : domains.joined(separator: ","), name,
         gateways.isEmpty ? "-" : gateways.joined(separator: ",")]
    }

    /// Whether the helper lets this portal's tunnel go to a gateway, by the
    /// same rule it checks itself.
    func allows(_ gateway: String) -> Bool {
        gateway.lowercased() == host.lowercased() || gateways.contains { $0.lowercased() == gateway.lowercased() }
    }

    /// A new id for a name: its letters and digits, lowercase, made unique.
    static func newID(for name: String, taken: Set<String>) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        var slug = String(folded.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" })
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = String(slug.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(20))
        if slug.isEmpty { slug = "vpn" }
        var id = slug, n = 2
        while taken.contains(id) { id = "\(slug)-\(n)"; n += 1 }
        return id
    }

    /// Where this institution's sign-in pages keep their cookies: a store of
    /// its own, so that two institutions signing in through the same identity
    /// provider (a large cloud one, say) don't share a session or an account.
    var dataStoreID: UUID {
        var b = Array(SHA256.hash(data: Data("\(Brand.id).signin.\(id)".utf8)).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50   // a name-based UUID, version 5 in form
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

/// The helper's checks, repeated so that the form can say what's wrong before
/// the password is asked for. The helper's are the ones that count.
enum Check {
    static func id(_ s: String) -> Bool { matches(s, "^[a-z0-9][a-z0-9-]{0,23}$") }
    static func server(_ s: String) -> Bool {
        s.count <= 255 && matches(s, "^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._~%/-]*)?$")
    }
    static func option(_ s: String) -> Bool { matches(s, "^(-|[A-Za-z0-9._-]{1,64})$") }
    static func gateway(_ s: String) -> Bool {
        s.count <= 255 && matches(s, "^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$")
    }
    static func domains(_ s: String) -> Bool {
        s.count <= 512 && matches(s, "^(-|[A-Za-z0-9.-]+(,[A-Za-z0-9.-]+)*)$")
    }
    static func name(_ s: String) -> Bool {
        (1...64).contains(s.utf8.count) && !s.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        !s.contains("\n") && s.range(of: pattern, options: .regularExpression) != nil
    }
}
