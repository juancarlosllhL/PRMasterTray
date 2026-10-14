import CoreGraphics

/// Where another app's window has to go so the side panel does not cover it.
///
/// Pure geometry, in whichever coordinate space the caller uses for all three
/// rectangles — the app layer passes Accessibility's top-left space.
public enum WindowClearance {

    /// Less than this much overlap is rounding, not a window under the panel.
    static let tolerance: CGFloat = 1

    /// Nil when the window already stays clear. Otherwise the same window moved
    /// off the panel, and narrowed only when it cannot fit beside it. Height and
    /// vertical position are never touched.
    ///
    /// - Parameters:
    ///   - window: the other app's window.
    ///   - panel: the panel's frame.
    ///   - screen: the visible frame of the screen the panel is on.
    public static func clearedFrame(_ window: CGRect, avoiding panel: CGRect, within screen: CGRect) -> CGRect? {
        let overlap = window.intersection(panel)
        guard !overlap.isNull, overlap.width > tolerance, overlap.height > tolerance else { return nil }

        let allowed: (minX: CGFloat, maxX: CGFloat) = panel.midX < screen.midX
            ? (panel.maxX, screen.maxX)
            : (screen.minX, panel.minX)
        let allowedWidth = allowed.maxX - allowed.minX
        guard allowedWidth > 0 else { return nil }

        var cleared = window
        if window.width > allowedWidth {
            cleared.origin.x = allowed.minX
            cleared.size.width = allowedWidth
        } else {
            cleared.origin.x = min(max(window.minX, allowed.minX), allowed.maxX - window.width)
        }
        return cleared
    }
}
