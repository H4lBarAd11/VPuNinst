// VPuNinst. Copyright (c) 2026 Riccardo Nevoso. GPL-3.0-or-later; see LICENSE.
import Foundation
import Security

/// An institution's sign-in, kept in the login keychain so its form can be
/// filled. Each is tied to the one https host it was typed on, as a browser
/// ties a password to a site, and is filled only there (see SignInWebView). A
/// rule by domain would be unsafe for everyone: the last two parts of
/// idp.example.ac.uk are ac.uk, every university in the UK. The login keychain
/// stays on this Mac; it is never synced to iCloud.
enum SavedLogin {
    struct Login: Equatable { let username: String; let password: String; let host: String }

    private static func service(_ id: String) -> String { "\(Brand.id).sso.\(id)" }

    static func load(_ id: String) -> Login? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(id),
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let item = out as? [String: Any],
              let user = item[kSecAttrAccount as String] as? String,
              let hostData = item[kSecAttrGeneric as String] as? Data,
              let host = String(data: hostData, encoding: .utf8), !host.isEmpty,
              let data = item[kSecValueData as String] as? Data,
              let pass = String(data: data, encoding: .utf8), !pass.isEmpty
        else { return nil }
        return Login(username: user, password: pass, host: host)
    }

    static func save(_ l: Login, for id: String, name: String) {
        forget(id)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(id),
            kSecAttrAccount as String: l.username,
            kSecAttrGeneric as String: Data(l.host.utf8),
            kSecAttrLabel as String: "\(Brand.name) — \(name) sign-in",
            kSecAttrComment as String: "Filled only on \(l.host)",
            kSecValueData as String: Data(l.password.utf8),
        ]
        let s = SecItemAdd(add as CFDictionary, nil)
        AppLog.write("saved the \(id) sign-in for \(l.host) to the keychain → \(s == errSecSuccess ? "ok" : "OSStatus \(s)")")
    }

    static func forget(_ id: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service(id)] as CFDictionary)
    }
}
