import Foundation
import Testing
@testable import PRMasterCore

@Suite("App discovery")
struct AppDiscoveryTests {

    // MARK: the image name, which is the only exact join

    /// The service repository names the image it pushes; the deployments folder
    /// subscribes to that same name. Neither the folder name nor the chart's own
    /// `appName` can be derived from the repository, so this string is the join.
    @Test("the pushed image name is read out of the CircleCI config")
    func readsImageName() {
        let config = """
            executor: docker-tools/default
            steps:
              - docker-tools/build_and_push:
                  repository: lec-ai-chat-assistant
                  tag: "$VERSION"
        """
        #expect(AppDiscovery.imageNames(inCircleCIConfig: config) == ["lec-ai-chat-assistant"])
    }

    /// The same image is named again under `build_and_test`. Two entries would
    /// mean two searches for one answer.
    @Test("the same image named twice yields one name")
    func deduplicatesRepeats() {
        let config = """
              - docker-tools/build_and_test:
                  repository: lec-ai-chat-assistant
              - docker-tools/build_and_push:
                  repository: lec-ai-chat-assistant
        """
        #expect(AppDiscovery.imageNames(inCircleCIConfig: config) == ["lec-ai-chat-assistant"])
    }

    @Test("a repository that pushes two images reports both, in order")
    func keepsDistinctImages() {
        let config = """
              - docker-tools/build_and_push:
                  repository: lec-ai-chat-assistant
              - docker-tools/build_and_push:
                  repository: lec-ai-chat-assistant-worker
        """
        #expect(AppDiscovery.imageNames(inCircleCIConfig: config) == [
            "lec-ai-chat-assistant", "lec-ai-chat-assistant-worker",
        ])
    }

    @Test("quoting is not part of the image name")
    func trimsQuotes() {
        #expect(AppDiscovery.imageNames(inCircleCIConfig: "    repository: \"lec-foo\"") == ["lec-foo"])
        #expect(AppDiscovery.imageNames(inCircleCIConfig: "    repository: 'lec-foo'") == ["lec-foo"])
    }

    /// Unlike the promoted version, this key is always nested, so leading
    /// whitespace has to be tolerated rather than used as the guard.
    @Test("indentation does not hide the key")
    func toleratesIndentation() {
        #expect(AppDiscovery.imageNames(inCircleCIConfig: "        repository: lec-foo") == ["lec-foo"])
    }

    @Test("a commented-out line is not an image name")
    func ignoresComments() {
        #expect(AppDiscovery.imageNames(inCircleCIConfig: "  # repository: lec-old").isEmpty)
    }

    @Test("a key that merely ends in the same word is not the image name")
    func ignoresOtherKeys() {
        #expect(AppDiscovery.imageNames(inCircleCIConfig: "  image_repository: lec-foo").isEmpty)
    }

    @Test("a key with no value is skipped rather than yielding an empty name")
    func skipsEmptyValue() {
        #expect(AppDiscovery.imageNames(inCircleCIConfig: "  repository:").isEmpty)
    }

    @Test("a config that pushes nothing yields no names")
    func noImages() {
        #expect(AppDiscovery.imageNames(inCircleCIConfig: "version: 2.1\njobs:\n  build:\n").isEmpty)
    }

    // MARK: turning search hits into app locations

    /// `.stages/` holds a rendered copy of every app, one per cluster. Kargo never
    /// writes to those, so matching one would point the reader at a generated
    /// file and multiply every app by the number of clusters.
    @Test("rendered copies under .stages are dropped")
    func dropsRenderedCopies() {
        let locations = AppDiscovery.locations(fromSearchPaths: [
            (repo: "Lansweeper/assetcortex-deployments", path: ".stages/stg-euw1-core/ai-chat-assistant/values.yaml"),
            (repo: "Lansweeper/assetcortex-deployments", path: ".stages/prd-use2-core/ai-chat-assistant/values.yaml"),
            (repo: "Lansweeper/assetcortex-deployments", path: "ai-chat-assistant/values.yaml"),
        ])
        #expect(locations == [
            AppLocation(deploymentsRepo: "Lansweeper/assetcortex-deployments", appPath: "ai-chat-assistant"),
        ])
    }

    /// The chart's values file and its Kargo sub-chart both mention the image and
    /// both belong to one app.
    @Test("the values file and the kargo sub-chart reduce to one app")
    func collapsesToOneApp() {
        let locations = AppDiscovery.locations(fromSearchPaths: [
            (repo: "Lansweeper/assetcortex-deployments", path: "ai-chat-assistant/values.yaml"),
            (repo: "Lansweeper/assetcortex-deployments", path: "ai-chat-assistant/kargo/values.yaml"),
        ])
        #expect(locations.count == 1)
        #expect(locations.first?.appPath == "ai-chat-assistant")
    }

    /// One image can back several apps: the chat assistant and its embeddings
    /// subscribe to the same image, and both must be reported.
    @Test("one image backing several apps reports each of them")
    func severalAppsPerImage() {
        let locations = AppDiscovery.locations(fromSearchPaths: [
            (repo: "Lansweeper/assetcortex-deployments", path: "ai-chat-assistant/values.yaml"),
            (repo: "Lansweeper/assetcortex-deployments", path: "ai-chat-assistant-embeddings/values.yaml"),
        ])
        #expect(locations.map(\.appPath) == ["ai-chat-assistant", "ai-chat-assistant-embeddings"])
    }

    /// The same app name exists in more than one deployments repository, so the
    /// repository is part of the identity rather than a detail.
    @Test("the same app name in two repositories is two locations")
    func sameNameDifferentRepositories() {
        let locations = AppDiscovery.locations(fromSearchPaths: [
            (repo: "Lansweeper/assetcortex-deployments", path: "ai-chat-assistant/values.yaml"),
            (repo: "Lansweeper/analytics-deployments", path: "ai-chat-assistant/values.yaml"),
        ])
        #expect(locations.count == 2)
        #expect(Set(locations.map(\.deploymentsRepo)) == [
            "Lansweeper/assetcortex-deployments", "Lansweeper/analytics-deployments",
        ])
    }

    /// A hit at the root of the repository names no app. An empty app path would
    /// later build the request `main:/values.stg.euw1.yaml`.
    @Test("a path with no app segment is dropped", arguments: [
        "values.yaml", "/values.yaml", "", "/",
    ])
    func dropsPathsWithoutAnApp(path: String) {
        let locations = AppDiscovery.locations(fromSearchPaths: [
            (repo: "Lansweeper/assetcortex-deployments", path: path),
        ])
        #expect(locations.isEmpty)
    }

    @Test("no hits yield no locations")
    func noHits() {
        #expect(AppDiscovery.locations(fromSearchPaths: []).isEmpty)
    }

    // MARK: persistence

    /// Discovered mappings are cached to UserDefaults, so the shape has to
    /// survive a round trip unchanged.
    @Test("a location round-trips through JSON")
    func roundTripsThroughJSON() throws {
        let location = AppLocation(
            deploymentsRepo: "Lansweeper/assetcortex-deployments",
            appPath: "ai-chat-assistant"
        )
        let data = try JSONEncoder().encode([location])
        #expect(try JSONDecoder().decode([AppLocation].self, from: data) == [location])
    }
}
