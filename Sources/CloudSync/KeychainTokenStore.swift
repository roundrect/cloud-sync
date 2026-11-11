import Foundation
import Security

/// The device token in the login keychain: a generic password, service chosen by the app, account =
/// device id.
///
/// An app and its CLI are one device. A legacy keychain item trusts only the binary that made it
/// unless its ACL says otherwise, so every item is created with both binaries trusted
/// (`SecAccessCreate`). Those APIs are deprecated but are the only way to share a legacy item without
/// an entitlement. Ad-hoc-signed dev builds will prompt. Unit tests never use this type.
public struct KeychainTokenStore: TokenStore {
    public var service: String
    /// The name Keychain Access shows, such as `Example sync token`.
    public var label: String
    /// Binaries that may read the item without a prompt, in addition to the creator.
    public var trustedApplicationPaths: [String]

    public init(service: String, label: String, trustedApplicationPaths: [String]) {
        self.service = service
        self.label = label
        self.trustedApplicationPaths = trustedApplicationPaths
    }

    /// Each of `bundlePaths` (relative to the bundle, such as `Contents/MacOS/Example`) when running
    /// from or inside an app bundle; otherwise just this executable.
    public static func trustedPaths(inBundle bundlePaths: [String], executable: URL? = Bundle.main.executableURL) -> [String] {
        guard let executable = executable?.resolvingSymlinksInPath() else { return [] }
        let components = executable.pathComponents
        if let index = components.firstIndex(where: { $0.hasSuffix(".app") }) {
            let root = URL(fileURLWithPath: NSString.path(withComponents: Array(components[...index])))
            return bundlePaths.map { root.appending(path: $0).path }
        }
        return [executable.path]
    }

    private func query(_ deviceID: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: deviceID]
    }

    private func fail(_ action: String, _ status: OSStatus) -> CloudError {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return .local("Keychain: couldn't \(action) the sync token (\(text))")
    }

    public func token(for deviceID: String) throws -> String? {
        var request = query(deviceID)
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw fail("read", status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func save(_ token: String, for deviceID: String) throws {
        SecItemDelete(query(deviceID) as CFDictionary)
        var item = query(deviceID)
        item[kSecValueData] = Data(token.utf8)
        item[kSecAttrLabel] = label
        if let access = makeAccess() { item[kSecAttrAccess] = access }
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw fail("save", status) }
    }

    public func delete(for deviceID: String) throws {
        let status = SecItemDelete(query(deviceID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw fail("delete", status) }
    }

    @available(macOS, deprecated: 10.10, message: "SecAccess is the only way to share a legacy keychain item without an entitlement")
    private func makeAccess() -> SecAccess? {
        var trusted: [SecTrustedApplication] = []
        var me: SecTrustedApplication?
        if SecTrustedApplicationCreateFromPath(nil, &me) == errSecSuccess, let me { trusted.append(me) }
        for path in trustedApplicationPaths where FileManager.default.fileExists(atPath: path) {
            var app: SecTrustedApplication?
            if SecTrustedApplicationCreateFromPath(path, &app) == errSecSuccess, let app { trusted.append(app) }
        }
        var access: SecAccess?
        guard SecAccessCreate(label as CFString, trusted as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }
}
