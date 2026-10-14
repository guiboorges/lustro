import Foundation
import Security

/// Code-signature checks. Lustro may hold Full Disk Access, so it only acts on data it can tie to a signature:
/// its own cleaning rules, and the identity of an app before preselecting that app's files.
public enum CodeIntegrity {
    /// Whether Lustro.app, rules.json and apps.json included, is exactly what was signed. The rules decide
    /// what Lustro removes; an edited copy would keep Lustro's permissions while steering them elsewhere.
    /// True when not running from an app bundle (`swift run`, tests).
    public static let bundleIsIntact: Bool = {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else { return true }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckNestedCode), nil) == errSecSuccess
    }()

    /// The developer team of a validly signed bundle. Nil when it is unsigned, ad-hoc signed or was modified
    /// after signing (its Info.plist included), i.e. when nothing vouches for its bundle identifier.
    public static func teamIdentifier(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), nil) == errSecSuccess
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// Lustro's own files no longer match its signature.
public struct ResourceIntegrityError: LocalizedError {
    public var errorDescription: String? {
        String(localized: "Lustro's files were changed after it was built, so its cleaning rules are not used. Download Lustro again.")
    }
}
