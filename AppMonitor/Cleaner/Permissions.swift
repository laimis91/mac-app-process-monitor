// Full Disk Access detection (spec 3.1). Foundation only; opening System Settings is in the views.

import Foundation

enum Permissions {
    static let probes = ["Library/Containers/com.apple.stocks", "Library/Safari", "Library/Mail"]
    static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    static let settingsFallbackURL = "x-apple.systempreferences:com.apple.preference.security"

    /// Reads each probe folder. Any success means granted; EPERM with no success means denied;
    /// anything else is unknown (treated as denied for scanning, without "denied" wording).
    static func detect(home: String) -> FDAStatus {
        var sawEPERM = false
        for rel in probes {
            let p = home + "/" + rel
            if let d = opendir(p) { closedir(d); return .granted }
            if errno == EPERM { sawEPERM = true }
        }
        return sawEPERM ? .denied : .unknown
    }
}
