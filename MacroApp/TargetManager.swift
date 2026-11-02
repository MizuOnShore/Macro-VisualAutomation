import AppKit
import ApplicationServices
import CoreGraphics

enum TargetWindowFocus {
    case matched
    case different
    case unavailable
}

protocol TargetDiscovering {
    func discoverWindows() throws -> [TargetWindow]
}

/// An automation must use the chosen window when an app owns more than one.
/// A bundle ID alone does not identify the window that received the recording.
enum AutomationTargetSelector {
    static func select(
        from windows: [TargetWindow],
        selected: TargetWindow?,
        bundleIdentifier: String?,
        isAvailable: (TargetWindow) -> Bool
    ) -> TargetWindow? {
        if let selected, bundleIdentifier == nil || selected.bundleIdentifier == bundleIdentifier {
            guard let exact = windows.first(where: {
                $0.id == selected.id && $0.processIdentifier == selected.processIdentifier
            }), isAvailable(exact) else { return nil }
            return exact
        }
        guard let bundleIdentifier else { return nil }
        let matches = windows.filter { $0.bundleIdentifier == bundleIdentifier && isAvailable($0) }
        return matches.count == 1 ? matches[0] : nil
    }
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
    func window(at point: CGPoint) -> TargetWindow? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // The window list is front to back. Only normal application windows
        // can be selected as recording targets.
        return windows.lazy.compactMap { targetWindow(from: $0, excluding: ownPID) }
            .first { $0.bounds.contains(point) }
    }

    func focusedWindowStatus(matching target: TargetWindow) -> TargetWindowFocus {
        let application = AXUIElementCreateApplication(target.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .unavailable }
        let focused = value as! AXUIElement
        if let selected = matchingAXWindow(target, application: application) {
            return CFEqual(focused, selected) ? .matched : .different
        }
        guard let frame = axFrame(of: focused) else { return .unavailable }
        return framesMatch(frame, target.bounds) ? .unavailable : .different
    }

    @discardableResult
    func raiseWindow(matching target: TargetWindow) -> Bool {
        let application = AXUIElementCreateApplication(target.processIdentifier)
        guard let window = matchingAXWindow(target, application: application) else { return false }
        _ = AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, window)
        return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
    }

    func currentWindow(matching target: TargetWindow) -> TargetWindow? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow], CGWindowID(target.id)
        ) as? [[String: Any]] else { return nil }
        return windows.compactMap { targetWindow(from: $0, excluding: ProcessInfo.processInfo.processIdentifier) }
            .first { $0.id == target.id && $0.processIdentifier == target.processIdentifier }
    }

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

    private func axFrame(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        let position = positionValue as! AXValue
        let size = sizeValue as! AXValue
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin),
              AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }

    private func matchingAXWindow(_ target: TargetWindow, application: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        let frameMatches = windows.filter {
            guard let frame = axFrame(of: $0) else { return false }
            return framesMatch(frame, target.bounds)
        }
        if frameMatches.count == 1 { return frameMatches[0] }
        guard target.windowTitle != "Untitled Window" else { return nil }
        let titleMatches = frameMatches.filter { window in
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success else { return false }
            return (title as? String) == target.windowTitle
        }
        return titleMatches.count == 1 ? titleMatches[0] : nil
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 8 && abs(lhs.minY - rhs.minY) <= 8 &&
        abs(lhs.width - rhs.width) <= 8 && abs(lhs.height - rhs.height) <= 8
    }
}
