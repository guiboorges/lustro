import Foundation

public enum FinderTrashError: Error, CustomStringConvertible {
    case cancelled
    case notAllowed
    case failed(String)

    public var description: String {
        switch self {
        case .cancelled:
            String(localized: "Cancelled. macOS needs your password to move apps installed by the App Store to the Trash.")
        case .notAllowed:
            String(localized: "Lustro isn't allowed to ask Finder. Allow it in System Settings → Privacy & Security → Automation, then try again.")
        case .failed(let message):
            String(localized: "Finder couldn't move it to the Trash: \(message)")
        }
    }
}

/// Apps installed by the App Store belong to root, so moving one to the Trash needs an administrator's password.
/// Lustro runs no privileged code of its own: it asks Finder, which shows the system password dialog, moves only
/// the item it is given, and remembers it for Put Back.
public enum FinderTrash {
    public static let applicationRoots = [URL(fileURLWithPath: "/Applications")]

    /// Only an app bundle the user can't move: a real folder (not a link) named `*.app`, owned by root, inside
    /// an applications folder through no symbolic link.
    public static func isEligible(_ url: URL, roots: [URL] = applicationRoots) -> Bool {
        let url = url.standardizedFileURL
        guard url.pathExtension.lowercased() == "app", url.resolvingSymlinksInPath().path == url.path,
              roots.contains(where: { SafetyPolicy.isStrictlyInside(SafetyPolicy.key(url.path), SafetyPolicy.key($0.path)) })
        else { return false }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFDIR && info.st_uid == 0 && access(url.path, W_OK) != 0
    }

    /// Asks Finder to move `url` to the Trash and returns where it went.
    @MainActor
    public static func trash(_ url: URL) -> Result<URL?, FinderTrashError> {
        // The path travels as an Apple event parameter, never as script text, so no file name can change the script.
        let source = """
        on trashitem(p)
            set doomed to (p as POSIX file)
            with timeout of 600 seconds
                tell application "Finder" to set trashed to delete doomed
            end timeout
            tell application "Finder" to return POSIX path of (trashed as alias)
        end trashitem
        """
        guard let script = NSAppleScript(source: source) else { return .failure(.failed("script")) }
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string: url.path), at: 1)
        let event = NSAppleEventDescriptor(eventClass: fourCC("ascr"), eventID: fourCC("psbr"),
                                           targetDescriptor: .currentProcess(),
                                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: "trashitem"), forKeyword: fourCC("snam"))
        event.setParam(arguments, forKeyword: fourCC("----"))
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        if let error {
            switch error[NSAppleScript.errorNumber] as? Int {
            case -128: return .failure(.cancelled)
            case -1743: return .failure(.notAllowed)
            default: return .failure(.failed(error[NSAppleScript.errorMessage] as? String ?? "\(error)"))
            }
        }
        return .success(result.stringValue.map { URL(fileURLWithPath: $0) })
    }

    private static func fourCC(_ code: String) -> FourCharCode {
        code.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}
