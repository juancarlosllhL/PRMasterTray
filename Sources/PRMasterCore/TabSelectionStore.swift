import Foundation
import Observation

/// A store rather than view state because the Command-digit monitor lives in
/// `AppDelegate`, which cannot reach a SwiftUI `@State`.
@MainActor
@Observable
public final class TabSelectionStore {
    public private(set) var selected: PopoverTab = .default

    public init() {}

    public func select(_ tab: PopoverTab) {
        selected = tab
    }

    public func select(at index: Int, in visible: [PopoverTab]) {
        guard visible.indices.contains(index) else { return }
        selected = visible[index]
    }

    /// A read, not a write: switching a tab back on restores the original choice.
    public func resolved(visible: [PopoverTab]) -> PopoverTab {
        PopoverTab.resolve(requested: selected, visible: visible)
    }
}
