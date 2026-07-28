import Foundation
import PRMasterCore

/// Replaces the running PRMaster.app with a downloaded release.
///
/// Lives in the app target rather than `PRMasterCore` because every step of it
/// is untestable by construction: it writes to the filesystem, shells out, and
/// ends the process. The parts that *can* be tested were pushed down into the
/// core — `ReleaseIntegrity` verifies the bytes and `ReleaseVersion` decides
/// whether there is anything to install.
///
/// The sequence is download → verify → unpack → validate → swap → relaunch, and
/// it refuses at the first step that does not hold rather than pressing on.
struct AppUpdateInstaller: AppUpdateInstalling {

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func install(_ release: AppRelease) async throws {
        let archive = try await download(release.assetURL)

        // Before anything is written or unpacked. An ad-hoc signature carries no
        // Team ID, so `codesign --verify` could not tell us who built this —
        // the digest is the only thing that pins these bytes to our workflow.
        guard ReleaseIntegrity.verify(archive, matches: release.sha256) else {
            throw PRMasterError.updateVerificationFailed
        }

        let work = try makeWorkDirectory()
        let unpacked = try unpack(archive, in: work)
        let newBundle = try locateBundle(in: unpacked)

        try swapAndRelaunch(to: newBundle, work: work)
    }

    // MARK: - Download

    private func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("PRMaster", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw PRMasterError.network(error)
        }

        // GitHub redirects asset downloads to object storage; URLSession follows
        // that, so a non-200 here is the final answer rather than the redirect.
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw PRMasterError.updateFailed("the download returned \(http.statusCode)")
        }
        guard !data.isEmpty else {
            throw PRMasterError.updateFailed("the download was empty")
        }
        return data
    }

    // MARK: - Unpack

    private func makeWorkDirectory() throws -> URL {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("PRMasterUpdate-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            throw PRMasterError.updateFailed("could not create a working directory")
        }
        return work
    }

    /// - Returns: the directory the archive was expanded into.
    private func unpack(_ archive: Data, in work: URL) throws -> URL {
        let zip = work.appendingPathComponent("update.zip")
        let destination = work.appendingPathComponent("unpacked")

        do {
            try archive.write(to: zip)
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true
            )
        } catch {
            throw PRMasterError.updateFailed("could not write the download to disk")
        }

        // `ditto`, not `unzip`. The archive is a code-signed bundle produced by
        // `ditto -c -k`, and unzip predates the metadata that carries — symlinks
        // and extended attributes — which is a known source of bundles that
        // extract but no longer validate.
        let status = try run("/usr/bin/ditto", ["-x", "-k", zip.path, destination.path])
        guard status == 0 else {
            throw PRMasterError.updateFailed("the archive could not be unpacked")
        }
        return destination
    }

    // MARK: - Validate

    /// Finds the app bundle in an expanded archive, refusing anything that is
    /// not unmistakably a PRMaster.
    ///
    /// The archive's structure is attacker-influenced, so this does not simply
    /// take the first `.app` it finds: it requires exactly one, carrying our
    /// bundle identifier and a runnable executable.
    private func locateBundle(in directory: URL) throws -> URL {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )
        } catch {
            throw PRMasterError.updateFailed("the unpacked archive could not be read")
        }

        let bundles = contents.filter { $0.pathExtension == "app" }
        guard bundles.count == 1, let bundle = bundles.first else {
            throw PRMasterError.updateFailed(
                bundles.isEmpty
                    ? "the archive contained no app"
                    : "the archive contained \(bundles.count) apps"
            )
        }

        // `ditto` preserves symlinks from the archive, and matching on the `.app`
        // suffix matches a link to one just as happily as the real thing — every
        // check below would then be reading whatever it points at. Refused
        // outright, and the resolved path is required to stay where it was
        // unpacked. (`ditto -x -k` does flatten `../` entries, so traversal is
        // already handled; this is about the link, not the path.)
        let isLink = (try? bundle.resourceValues(forKeys: [.isSymbolicLinkKey]))?
            .isSymbolicLink
        guard isLink != true else {
            throw PRMasterError.updateFailed("the app in the archive is a symlink")
        }
        let unpacked = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard bundle.resolvingSymlinksInPath().standardizedFileURL.path
            .hasPrefix(unpacked + "/")
        else {
            throw PRMasterError.updateFailed("the app in the archive resolves outside it")
        }

        // Read the plist directly rather than through `Bundle`, which caches by
        // path and can hand back the *running* app's values for a bundle that
        // happens to sit where one was already loaded from.
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String
        else {
            throw PRMasterError.updateFailed("the app in the archive has no readable Info.plist")
        }

        let expected = Bundle.main.bundleIdentifier ?? "com.jcll.PRMaster"
        guard identifier == expected else {
            throw PRMasterError.updateFailed("the archive contained \(identifier), not \(expected)")
        }

        let executable = bundle.appendingPathComponent("Contents/MacOS/PRMaster")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw PRMasterError.updateFailed("the app in the archive has no runnable executable")
        }

        return bundle
    }

    // MARK: - Swap and relaunch

    /// Hands the swap to a detached shell script and ends this process.
    ///
    /// An app cannot replace its own bundle while running out of it, so the work
    /// outlives us: the helper waits for this process to actually go away, moves
    /// the old bundle aside, copies the new one in, and relaunches.
    private func swapAndRelaunch(to newBundle: URL, work: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c", Self.swapScript, "--",
            String(ProcessInfo.processInfo.processIdentifier),
            Bundle.main.bundlePath,
            newBundle.path,
            work.path,
        ]

        do {
            try process.run()
        } catch {
            throw PRMasterError.updateFailed("the installer could not be started")
        }

        // Not NSApp.terminate: that runs applicationWillTerminate, which calls
        // store.stop() and would be doing so while the bundle underneath is
        // being replaced. There is no unsaved state here to protect.
        exit(0)
    }

    private static let swapScript = """
        target_pid="$1"; current="$2"; new="$3"; work="$4"
        backup="${current}.prmaster-old"

        # Wait for the app to actually exit. A fixed `sleep 1` is a guess, and
        # macOS 26 changed how quickly a terminating app goes away.
        for _ in $(seq 1 200); do
            /bin/kill -0 "$target_pid" 2>/dev/null || break
            /bin/sleep 0.1
        done

        /bin/rm -rf "$backup"

        # Moved aside rather than deleted, so there is something to put back if
        # the copy fails. If even the move fails, nothing has been touched yet —
        # relaunch what is still installed and give up.
        if ! /bin/mv "$current" "$backup"; then
            /usr/bin/open "$current"
            /bin/rm -rf "$work"
            exit 1
        fi

        if /usr/bin/ditto "$new" "$current"; then
            /bin/rm -rf "$backup"
        else
            /bin/rm -rf "$current"
            /bin/mv "$backup" "$current"
        fi

        # Belt and braces: a URLSession download is not quarantined unless the
        # app opts in, which this one does not. Costs nothing and does not
        # disturb the signature, which seals contents rather than attributes.
        /usr/bin/xattr -cr "$current" 2>/dev/null

        /usr/bin/open "$current"
        /bin/rm -rf "$work"
        """

    // MARK: - Shell

    private func run(_ path: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw PRMasterError.updateFailed("could not run \(path)")
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
