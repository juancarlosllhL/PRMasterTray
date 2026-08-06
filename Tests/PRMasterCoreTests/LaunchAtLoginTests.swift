import Foundation
import Testing
@testable import PRMasterCore

/// Stands in for macOS's login item registry.
///
/// `landsOn` is what makes the approval path reachable at all: `register()` can
/// succeed into `on` or into `needsApproval` depending on what the user has told
/// System Settings before, and telling those two apart is most of what the store
/// has to get right.
final class FakeLoginItem: LoginItemRegistering, @unchecked Sendable {
    private let lock = NSLock()
    private var current: LoginItemState
    private var landsOn: LoginItemState
    private var failure: (any Error)?
    private var registers = 0
    private var unregisters = 0
    private var opened = false

    init(
        state: LoginItemState = .off,
        landsOn: LoginItemState = .on,
        failing failure: (any Error)? = nil
    ) {
        self.current = state
        self.landsOn = landsOn
        self.failure = failure
    }

    var registerCount: Int { lock.withLock { registers } }
    var unregisterCount: Int { lock.withLock { unregisters } }
    var didOpenSystemSettings: Bool { lock.withLock { opened } }

    /// The user changing it in System Settings while the app is running.
    func changeExternally(to state: LoginItemState) {
        lock.withLock { current = state }
    }

    func state() -> LoginItemState { lock.withLock { current } }

    func register() throws {
        try lock.withLock {
            registers += 1
            // Counted before the throw: an attempt was made, and the tests for
            // the refusal path need to see that it was.
            if let failure { throw failure }
            current = landsOn
        }
    }

    func unregister() throws {
        try lock.withLock {
            unregisters += 1
            if let failure { throw failure }
            current = .off
        }
    }

    func openSystemSettings() { lock.withLock { opened = true } }
}

/// What macOS says when it refuses. `SMServiceErrorDomain` code 1 in the wild;
/// only the wording reaches the user, so only the wording is modelled.
private struct Refused: LocalizedError {
    var errorDescription: String? { "Operation not permitted" }
}

@Suite("Launch at login")
@MainActor
struct LaunchAtLoginStoreTests {

    @Test("the state is read from macOS at launch", arguments: [
        LoginItemState.off, .on, .needsApproval,
    ])
    func readsStateAtInit(state: LoginItemState) {
        let store = LaunchAtLoginStore(
            loginItem: FakeLoginItem(state: state), preferences: MemoryPreferences()
        )
        #expect(store.state == state)
    }

    /// macOS owns the truth, but the intent has to be stored too — it is the only
    /// thing that can tell a registration lost to an update from one nobody asked
    /// for. See `repairIfNeeded`.
    @Test("switching it on registers and remembers being asked")
    func switchingOnRegisters() {
        let item = FakeLoginItem()
        let preferences = MemoryPreferences()
        let store = LaunchAtLoginStore(loginItem: item, preferences: preferences)

        store.setEnabled(true)

        #expect(item.registerCount == 1)
        #expect(store.state == .on)
        #expect(preferences.launchAtLoginRequested() == true)
    }

    @Test("switching it off unregisters and forgets being asked")
    func switchingOffUnregisters() {
        let item = FakeLoginItem(state: .on)
        let preferences = MemoryPreferences(launchAtLogin: true)
        let store = LaunchAtLoginStore(loginItem: item, preferences: preferences)

        store.setEnabled(false)

        #expect(item.unregisterCount == 1)
        #expect(store.state == .off)
        #expect(preferences.launchAtLoginRequested() == false)
    }

    /// The toggle must not spring back to off while macOS is the one holding it
    /// up: the user has already asked, and an off switch would invite them to
    /// click it again to no effect.
    @Test("the switch reads on while macOS is waiting for approval")
    func enabledWhileAwaitingApproval() {
        let store = LaunchAtLoginStore(
            loginItem: FakeLoginItem(landsOn: .needsApproval),
            preferences: MemoryPreferences()
        )

        store.setEnabled(true)

        #expect(store.state == .needsApproval)
        #expect(store.isEnabled == true)
    }

    @Test("the switch reads off when nothing is registered")
    func notEnabledWhenOff() {
        let store = LaunchAtLoginStore(
            loginItem: FakeLoginItem(state: .off), preferences: MemoryPreferences()
        )
        #expect(store.isEnabled == false)
    }

    /// There is no logging anywhere in this app, so a refusal that set nothing
    /// would be a switch that springs back with no explanation.
    @Test("a refusal is surfaced and leaves it off")
    func refusalIsSurfaced() {
        let item = FakeLoginItem(failing: Refused())
        let store = LaunchAtLoginStore(loginItem: item, preferences: MemoryPreferences())

        store.setEnabled(true)

        #expect(item.registerCount == 1)
        #expect(store.state == .off)
        #expect(store.isEnabled == false)
        #expect(store.lastFailure == "Operation not permitted")
    }

    @Test("a later success clears an earlier refusal")
    func laterSuccessClearsFailure() {
        let item = FakeLoginItem(failing: Refused())
        let store = LaunchAtLoginStore(loginItem: item, preferences: MemoryPreferences())
        store.setEnabled(true)
        #expect(store.lastFailure != nil)

        let working = FakeLoginItem()
        let recovered = LaunchAtLoginStore(loginItem: working, preferences: MemoryPreferences())
        recovered.setEnabled(true)
        #expect(recovered.lastFailure == nil)
    }

    // MARK: - Repair

    /// The self-updater replaces the app bundle the registration points at, which
    /// can leave it absent. Without this the feature quietly dies on an update.
    @Test("a registration lost to an update is put back")
    func repairsALostRegistration() {
        let item = FakeLoginItem(state: .off)
        let store = LaunchAtLoginStore(
            loginItem: item, preferences: MemoryPreferences(launchAtLogin: true)
        )

        store.repairIfNeeded()

        #expect(item.registerCount == 1)
        #expect(store.state == .on)
    }

    /// The load-bearing case. Unticking the app in System Settings leaves the
    /// registration in place and unapproved — `needsApproval`, not `off` — which
    /// is exactly what lets the repair tell "the updater lost it" from "the user
    /// said no". Registering here would argue with the user on every launch.
    @Test("unticking it in System Settings is not overridden")
    func repairLeavesAnUnapprovedItemAlone() {
        let item = FakeLoginItem(state: .needsApproval)
        let store = LaunchAtLoginStore(
            loginItem: item, preferences: MemoryPreferences(launchAtLogin: true)
        )

        store.repairIfNeeded()

        #expect(item.registerCount == 0)
        #expect(store.state == .needsApproval)
    }

    /// Registering something nobody asked for is how an app ends up in somebody's
    /// login items uninvited.
    @Test("nothing is registered for somebody who never asked")
    func repairDoesNothingWhenNeverAsked() {
        let item = FakeLoginItem(state: .off)
        let store = LaunchAtLoginStore(
            loginItem: item, preferences: MemoryPreferences(launchAtLogin: false)
        )

        store.repairIfNeeded()

        #expect(item.registerCount == 0)
        #expect(store.state == .off)
    }

    /// Ad-hoc signatures make a duplicate login item cheap to create, so a repair
    /// that fired over a registration already in place would be the bug.
    @Test("a working registration is left alone")
    func repairDoesNothingWhenAlreadyOn() {
        let item = FakeLoginItem(state: .on)
        let store = LaunchAtLoginStore(
            loginItem: item, preferences: MemoryPreferences(launchAtLogin: true)
        )

        store.repairIfNeeded()

        #expect(item.registerCount == 0)
        #expect(store.state == .on)
    }

    // MARK: - Refresh

    /// The reason none of this is cached: the user can change it in System
    /// Settings while the app is running, and a stored boolean would then lie.
    @Test("a change made in System Settings is picked up")
    func refreshPicksUpAnExternalChange() {
        let item = FakeLoginItem(state: .on)
        let store = LaunchAtLoginStore(loginItem: item, preferences: MemoryPreferences())
        #expect(store.state == .on)

        item.changeExternally(to: .needsApproval)
        #expect(store.state == .on, "nothing should change until it is re-read")

        store.refresh()
        #expect(store.state == .needsApproval)
    }

    @Test("the approval prompt opens System Settings")
    func opensSystemSettings() {
        let item = FakeLoginItem(state: .needsApproval)
        let store = LaunchAtLoginStore(loginItem: item, preferences: MemoryPreferences())

        store.openSystemSettings()

        #expect(item.didOpenSystemSettings)
    }
}
