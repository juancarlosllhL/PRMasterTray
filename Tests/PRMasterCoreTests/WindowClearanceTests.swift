import CoreGraphics
import Foundation
import Testing
@testable import PRMasterCore

@Suite("Window clearance")
struct WindowClearanceTests {

    /// Top-left space, as Accessibility reports it: a 1440x835 visible frame
    /// under a 25pt menu bar.
    private let screen = CGRect(x: 0, y: 25, width: 1440, height: 835)
    private var rightPanel: CGRect { CGRect(x: 1060, y: 25, width: 380, height: 835) }
    private var leftPanel: CGRect { CGRect(x: 0, y: 25, width: 380, height: 835) }

    @Test("a window beside the panel is left alone")
    func clearWindowUntouched() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(WindowClearance.clearedFrame(window, avoiding: rightPanel, within: screen) == nil)
    }

    @Test("a window that only touches the panel's edge is left alone")
    func edgeContactUntouched() {
        let window = CGRect(x: 260, y: 100, width: 800, height: 600)
        #expect(WindowClearance.clearedFrame(window, avoiding: rightPanel, within: screen) == nil)
    }

    @Test("a window that fits beside a right panel is moved left, not narrowed")
    func shiftsLeft() {
        let window = CGRect(x: 900, y: 100, width: 500, height: 600)
        #expect(WindowClearance.clearedFrame(window, avoiding: rightPanel, within: screen)
            == CGRect(x: 560, y: 100, width: 500, height: 600))
    }

    @Test("a window that fits beside a left panel is moved right, not narrowed")
    func shiftsRight() {
        let window = CGRect(x: 100, y: 100, width: 500, height: 600)
        #expect(WindowClearance.clearedFrame(window, avoiding: leftPanel, within: screen)
            == CGRect(x: 380, y: 100, width: 500, height: 600))
    }

    @Test("a maximised window is narrowed to the room beside a right panel")
    func narrowsBesideRight() {
        let window = CGRect(x: 0, y: 25, width: 1440, height: 835)
        #expect(WindowClearance.clearedFrame(window, avoiding: rightPanel, within: screen)
            == CGRect(x: 0, y: 25, width: 1060, height: 835))
    }

    @Test("a maximised window is narrowed to the room beside a left panel")
    func narrowsBesideLeft() {
        let window = CGRect(x: 0, y: 25, width: 1440, height: 835)
        #expect(WindowClearance.clearedFrame(window, avoiding: leftPanel, within: screen)
            == CGRect(x: 380, y: 25, width: 1060, height: 835))
    }

    @Test("a window on another screen is left alone")
    func otherScreenUntouched() {
        let window = CGRect(x: 1500, y: 100, width: 800, height: 600)
        #expect(WindowClearance.clearedFrame(window, avoiding: rightPanel, within: screen) == nil)
    }

    @Test("a panel as wide as the screen leaves nothing to move to")
    func noRoom() {
        let window = CGRect(x: 100, y: 100, width: 500, height: 600)
        #expect(WindowClearance.clearedFrame(window, avoiding: screen, within: screen) == nil)
    }
}
