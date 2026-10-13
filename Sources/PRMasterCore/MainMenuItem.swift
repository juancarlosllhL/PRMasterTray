import Foundation

public enum MainMenuSection: Sendable, Equatable {
    case app, file, window
}

/// The menu bar a review window shows while the app sits in the Dock. Edit's
/// items are `EditMenuItem`; the app target turns both into `NSMenu`s.
public enum MainMenuItem: String, Sendable, Equatable, CaseIterable {
    case settings, hide, quit, close, minimize, zoom, bringAllToFront

    public var section: MainMenuSection {
        switch self {
        case .settings, .hide, .quit:            return .app
        case .close:                             return .file
        case .minimize, .zoom, .bringAllToFront: return .window
        }
    }

    public var title: String {
        switch self {
        case .settings:        return "Settings…"
        case .hide:            return "Hide PR Master Tray"
        case .quit:            return "Quit PR Master Tray"
        case .close:           return "Close"
        case .minimize:        return "Minimize"
        case .zoom:            return "Zoom"
        case .bringAllToFront: return "Bring All to Front"
        }
    }

    /// Settings is the app delegate's own action; the rest are AppKit's.
    public var selectorName: String {
        switch self {
        case .settings:        return "openSettingsFromMenu"
        case .hide:            return "hide:"
        case .quit:            return "terminate:"
        case .close:           return "performClose:"
        case .minimize:        return "performMiniaturize:"
        case .zoom:            return "performZoom:"
        case .bringAllToFront: return "arrangeInFront:"
        }
    }

    public var keyEquivalent: String {
        switch self {
        case .settings:                return ","
        case .hide:                    return "h"
        case .quit:                    return "q"
        case .close:                   return "w"
        case .minimize:                return "m"
        case .zoom, .bringAllToFront:  return ""
        }
    }

    public var isFollowedBySeparator: Bool {
        self == .settings || self == .hide || self == .zoom
    }
}
