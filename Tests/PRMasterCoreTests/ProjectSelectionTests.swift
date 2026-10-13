import Foundation
import Testing
@testable import PRMasterCore

private func preferences(_ suite: String) -> (UserDefaultsPreferences, UserDefaults) {
    let name = "ProjectSelectionTests.\(suite)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return (UserDefaultsPreferences(defaults: defaults), defaults)
}

@Suite("ProjectSelection")
struct ProjectSelectionTests {

    /// An allowlist: an organization has many boards, and only yours belong here.
    @Test("no project is shown until switched on")
    func emptyByDefault() {
        let selection = ProjectSelection()
        #expect(!selection.shows(boardProject()))
        #expect(selection.isEmpty)
    }

    @Test("switching a project on and off")
    func toggles() {
        var selection = ProjectSelection()
        selection.set(boardProject(), shown: true)
        #expect(selection.shows(boardProject()))
        #expect(!selection.shows(boardProject("PVT_2")))
        selection.set(boardProject(), shown: false)
        #expect(selection.isEmpty)
    }

    @Test("an absent key reads as nothing selected, nothing known, nothing mapped")
    func absent() {
        let (prefs, _) = preferences("absent")
        #expect(prefs.projectSelection().isEmpty)
        #expect(prefs.knownProjects().isEmpty)
        #expect(prefs.projectLaneMap() == ProjectLaneMap())
    }

    @Test("selection, known projects and the column map round-trip whole")
    func roundTrip() {
        let (prefs, _) = preferences("roundTrip")
        var selection = ProjectSelection()
        selection.set(boardProject(), shown: true)
        var map = ProjectLaneMap()
        map.set(.hidden, optionID: "o-qa", in: "PVT_1")

        prefs.setProjectSelection(selection)
        prefs.setKnownProjects([boardProject(), boardProject("PVT_2", statusFieldID: nil, options: [])])
        prefs.setProjectLaneMap(map)

        #expect(prefs.projectSelection() == selection)
        #expect(prefs.knownProjects() == [boardProject(), boardProject("PVT_2", statusFieldID: nil, options: [])])
        #expect(prefs.projectLaneMap() == map)
    }

    @Test("unreadable stored values read as empty rather than throwing")
    func corrupt() {
        let (_, defaults) = preferences("corrupt")
        for key in ["projectSelection", "knownProjects", "projectLaneMap"] {
            defaults.set(Data("not json".utf8), forKey: key)
        }
        let prefs = UserDefaultsPreferences(defaults: defaults)
        #expect(prefs.projectSelection().isEmpty)
        #expect(prefs.knownProjects().isEmpty)
        #expect(prefs.projectLaneMap() == ProjectLaneMap())
    }
}
