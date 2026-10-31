import AppKit
import CoreGraphics

protocol TargetDiscovering {
    func discoverWindows() throws -> [TargetWindow]
}

enum TargetDiscoveryError: LocalizedError {
    case windowServerUnavailable

    var errorDescription: String? {
        switch self {
        case .windowServerUnavailable:
            "The macOS Window Server did not return a window list."
        }
    }
}

/// Discovers normal application windows across Spaces without activating them.
/// Discovery is read-only and does not require Accessibility permission.
struct TargetManager: TargetDiscovering {
    func discoverWindows() throws -> [TargetWindow] {
        // `.optionOnScreenOnly` omits windows on another Space and can omit a
        // fullscreen app's window when Macro itself is on a different Space.
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let rawWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else {
            throw TargetDiscoveryError.windowServerUnavailable
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier

        return rawWindows.compactMap { information in
            targetWindow(from: information, excluding: ownPID)
        }
        .sorted {
            let applicationOrder = $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName)
            if $0.isOnScreen != $1.isOnScreen { return $0.isOnScreen }
            if applicationOrder == .orderedSame {
                return $0.windowTitle.localizedCaseInsensitiveCompare($1.windowTitle) == .orderedAscending
            }
            return applicationOrder == .orderedAscending
        }
    }

    private func targetWindow(
        from information: [String: Any],
        excluding ownPID: pid_t
    ) -> TargetWindow? {
        guard
            let windowNumber = number(information[kCGWindowNumber as String]),
            let ownerPIDNumber = number(information[kCGWindowOwnerPID as String]),
            let layerNumber = number(information[kCGWindowLayer as String]),
            let ownerName = information[kCGWindowOwnerName as String] as? String,
            !ownerName.isEmpty
        else {
            return nil
        }

        let processIdentifier = pid_t(ownerPIDNumber.int32Value)
        guard processIdentifier != ownPID, layerNumber.intValue == 0 else { return nil }

        let bounds = windowBounds(from: information[kCGWindowBounds as String])
        guard bounds.width >= 80, bounds.height >= 60 else { return nil }

        let title = (information[kCGWindowName as String] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }

        let application = NSRunningApplication(processIdentifier: processIdentifier)

        return TargetWindow(
            id: windowNumber.intValue,
            applicationName: application?.localizedName ?? ownerName,
            windowTitle: title ?? "Untitled Window",
            processIdentifier: processIdentifier,
            bundleIdentifier: application?.bundleIdentifier,
            bounds: bounds,
            isOnScreen: (information[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        )
    }

    private func number(_ value: Any?) -> NSNumber? {
        if let number = value as? NSNumber { return number }
        if let integer = value as? Int { return NSNumber(value: integer) }
        return nil
    }

    private func windowBounds(from value: Any?) -> CGRect {
        guard let dictionary = value as? NSDictionary else { return .zero }
        return CGRect(dictionaryRepresentation: dictionary) ?? .zero
    }
}
