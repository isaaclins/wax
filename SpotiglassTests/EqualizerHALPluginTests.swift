import Combine
import CoreAudio
import Foundation
import XCTest
@testable import Spotiglass

/// Exercises ``EqualizerHALPluginController`` against a temp HAL directory so
/// tests never touch the user's real `~/Library/Audio/Plug-Ins/HAL/`. The
/// .driver bundle that lives inside `Spotiglass.app` isn't built by an Xcode
/// target yet (see docs/equalizer.md "Known limitations"); these tests stage
/// a minimal `.driver` fixture in a temp directory so install/uninstall and
/// idempotency are still verifiable.
final class EqualizerHALPluginTests: XCTestCase {
    private var halDirectory: URL!
    private var defaultOutputBackupURL: URL!
    private var fixtureBundle: URL!
    private var fakeAppBundle: Bundle!

    override func setUp() {
        super.setUp()
        halDirectory = makeTempDirectory()
        defaultOutputBackupURL = makeTempDirectory()
            .appendingPathComponent("eq-default-output.uid")
        // Build a fake .driver bundle in a sibling temp dir so the controller
        // can locate it via Bundle.bundleURL/Contents/Library/Audio/Plug-Ins/HAL.
        let appDir = makeTempDirectory()
        let halLibrary = appDir
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Audio", isDirectory: true)
            .appendingPathComponent("Plug-Ins", isDirectory: true)
            .appendingPathComponent("HAL", isDirectory: true)
        try? FileManager.default.createDirectory(at: halLibrary, withIntermediateDirectories: true)
        fixtureBundle = halLibrary
            .appendingPathComponent(EqualizerHALPluginController.driverBundleName, isDirectory: true)
        try? FileManager.default.createDirectory(at: fixtureBundle, withIntermediateDirectories: true)
        try? "fake-driver-payload".write(
            to: fixtureBundle.appendingPathComponent("Marker.txt"),
            atomically: true,
            encoding: .utf8
        )
        try? writeDriverVersion("0.1.0", build: "1", to: fixtureBundle)
        fakeAppBundle = Bundle(url: appDir)
    }

    private func writeDriverVersion(
        _ shortVersion: String,
        build: String,
        to driverURL: URL
    ) throws {
        let propertyList: [String: String] = [
            "CFBundleShortVersionString": shortVersion,
            "CFBundleVersion": build,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
        let infoURL = driverURL.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(
            at: infoURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: infoURL, options: .atomic)
    }

    override func tearDown() {
        EqualizerHALPluginController.clearForwardingTarget()
        try? FileManager.default.removeItem(at: halDirectory)
        try? FileManager.default.removeItem(at: defaultOutputBackupURL.deletingLastPathComponent())
        super.tearDown()
    }

    // MARK: - Install / uninstall

    /// Someone updating from Spotiglass still has the driver an older release
    /// installed, and its device is called "Spotiglass EQ" until the new app
    /// replaces it. The app has to recognise that device as its own, or it
    /// can't find it and offers it as a place to send the EQ'd audio.
    func testTheEQDeviceIsRecognisedByItsUIDWhateverItIsCalled() {
        let uid = EqualizerHALPluginController.virtualDeviceUID
        let legacy = AudioDeviceEnumerator.Device(id: 41, name: "Spotiglass EQ", uid: uid)
        let renamed = AudioDeviceEnumerator.Device(id: 42, name: "Wax EQ", uid: uid)
        let speakers = AudioDeviceEnumerator.Device(id: 43, name: "MacBook Pro Speakers", uid: "BuiltInSpeakerDevice")
        let lookalike = AudioDeviceEnumerator.Device(id: 44, name: "Wax EQ", uid: "com.example.other-eq")

        XCTAssertTrue(EqualizerHALPluginController.isVirtualDevice(legacy))
        XCTAssertTrue(EqualizerHALPluginController.isVirtualDevice(renamed))
        XCTAssertFalse(EqualizerHALPluginController.isVirtualDevice(speakers))
        XCTAssertFalse(EqualizerHALPluginController.isVirtualDevice(lookalike))
    }

    func testInstallCopiesEmbeddedDriverIntoHALDirectory() throws {
        let controller = EqualizerHALPluginController(
            halDirectory: halDirectory,
            fileManager: .default,
            bundle: fakeAppBundle
        )
        XCTAssertFalse(controller.isInstalled)
        // Use the pure install() entry point so the test doesn't accidentally
        // flip the system's real default output device when a Spotiglass EQ
        // is actually loaded on the host running the tests.
        try controller.install()
        XCTAssertTrue(controller.isInstalled,
                      "the .driver should be copied even when coreaudiod hasn't picked it up")
        let marker = controller.installedDriverURL.appendingPathComponent("Marker.txt")
        XCTAssertEqual(
            try String(contentsOf: marker, encoding: .utf8),
            "fake-driver-payload"
        )
    }

    func testUninstallRemovesDirectoryAndIsIdempotent() throws {
        // Fake outputs: removal moves the Mac's output first, and a test must
        // never move the real one.
        let controller = makeController(for: FakeMacOutput())
        // Stage an install first.
        try controller.install()
        XCTAssertTrue(controller.isInstalled)
        try controller.uninstall()
        XCTAssertFalse(controller.isInstalled)
        // Calling again must NOT throw.
        XCTAssertNoThrow(try controller.uninstall())
    }

    func testInstallReplacesAStaleInstalledDriver() throws {
        // The system HAL directory is root-owned on macOS 26, so production
        // replacements happen in the helper. This isolated directory exercises
        // the same version decision without touching the user's audio setup.
        let controller = EqualizerHALPluginController(
            halDirectory: halDirectory,
            fileManager: .default,
            bundle: fakeAppBundle
        )
        try controller.install()
        let userFile = controller.installedDriverURL.appendingPathComponent("UserFile.txt")
        try "preserved".write(to: userFile, atomically: true, encoding: .utf8)

        // Mark the installed bundle stale, then let the policy trigger a
        // replacement. The fresh payload should remove files from the old
        // bundle rather than leave a mixed-version driver behind.
        try writeDriverVersion(
            "0.0.1",
            build: "1",
            to: controller.installedDriverURL
        )
        try controller.install()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: userFile.path),
            "a stale installed bundle must be replaced as a unit"
        )
        XCTAssertEqual(
            try String(contentsOf: controller.installedDriverURL.appendingPathComponent("Marker.txt"), encoding: .utf8),
            "fake-driver-payload"
        )
    }

    // MARK: - Error surfaces

    func testInstallKeepsMissingEmbeddedDriverOutOfTheUserMessage() {
        let emptyAppBundle = Bundle(url: makeTempDirectory())!
        let controller = EqualizerHALPluginController(
            halDirectory: halDirectory,
            fileManager: .default,
            bundle: emptyAppBundle
        )
        XCTAssertThrowsError(try controller.install()) { error in
            guard let driverError = error as? EqualizerHALPluginError else {
                return XCTFail("expected EqualizerHALPluginError, got \(error)")
            }
            guard case .embeddedDriverMissing = driverError else {
                return XCTFail("expected embeddedDriverMissing, got \(driverError)")
            }
            XCTAssertEqual(driverError.errorDescription, SpotiglassL10n.string("eq.error.embeddedDriverMissing"))
        }
    }

    // MARK: - Durable pre-EQ output backup

    func testPersistedOutputUIDResolvesToTheCurrentIDAfterControllerRestart() throws {
        let uid = "ExternalUSBDevice"
        try EqualizerHALPluginController.writeDefaultOutputBackup(
            uid: uid,
            to: defaultOutputBackupURL
        )
        var restoredIDs: [AudioObjectID] = []
        let controller = EqualizerHALPluginController(
            defaultOutputBackupURL: defaultOutputBackupURL,
            outputDeviceIDForUID: { $0 == uid ? AudioObjectID(42) : nil },
            defaultOutputSetter: { restoredIDs.append($0) }
        )

        XCTAssertEqual(controller.previousDefaultOutputUID, uid)
        try controller.restorePreviousDefaultOutput()
        XCTAssertEqual(restoredIDs, [AudioObjectID(42)])
        XCTAssertEqual(controller.previousDefaultOutputID, AudioObjectID(42))
    }

    func testDisableRestoresPersistedOutputAndClearsItsBackup() throws {
        let uid = "AirPodsMaxUID"
        try EqualizerHALPluginController.writeDefaultOutputBackup(
            uid: uid,
            to: defaultOutputBackupURL
        )
        var restoredIDs: [AudioObjectID] = []
        let controller = EqualizerHALPluginController(
            defaultOutputBackupURL: defaultOutputBackupURL,
            outputDeviceIDForUID: { $0 == uid ? AudioObjectID(73) : nil },
            defaultOutputSetter: { restoredIDs.append($0) }
        )

        try controller.disable()

        XCTAssertEqual(restoredIDs, [AudioObjectID(73)])
        XCTAssertNil(controller.previousDefaultOutputUID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultOutputBackupURL.path))
    }

    func testRestoreReportsWhenPersistedOutputIsNoLongerPresent() throws {
        let uid = "DisconnectedUSBDevice"
        try EqualizerHALPluginController.writeDefaultOutputBackup(
            uid: uid,
            to: defaultOutputBackupURL
        )
        let controller = EqualizerHALPluginController(
            defaultOutputBackupURL: defaultOutputBackupURL,
            outputDeviceIDForUID: { _ in nil },
            defaultOutputSetter: { _ in XCTFail("setter must not run for a missing device") }
        )

        XCTAssertThrowsError(try controller.restorePreviousDefaultOutput()) { error in
            guard case let EqualizerHALPluginError.previousOutputDeviceUnavailable(foundUID) = error else {
                return XCTFail("expected previousOutputDeviceUnavailable, got \(error)")
            }
            XCTAssertEqual(foundUID, uid)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: defaultOutputBackupURL.path))
    }

    func testRestoreExposesASetterFailureThroughTheInjectedSeam() throws {
        let uid = "ExternalUSBDevice"
        try EqualizerHALPluginController.writeDefaultOutputBackup(
            uid: uid,
            to: defaultOutputBackupURL
        )
        let controller = EqualizerHALPluginController(
            defaultOutputBackupURL: defaultOutputBackupURL,
            outputDeviceIDForUID: { $0 == uid ? AudioObjectID(91) : nil },
            defaultOutputSetter: { _ in
                throw EqualizerHALPluginError.coreAudioStatus(-1)
            }
        )

        XCTAssertThrowsError(try controller.restorePreviousDefaultOutput()) { error in
            guard case EqualizerHALPluginError.previousOutputRestoreFailed(underlying: let underlying) = error else {
                return XCTFail("expected previousOutputRestoreFailed, got \(error)")
            }
            guard case EqualizerHALPluginError.coreAudioStatus(-1) = underlying else {
                return XCTFail("expected injected CoreAudio failure, got \(underlying)")
            }
        }
        XCTAssertEqual(controller.previousDefaultOutputUID, uid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: defaultOutputBackupURL.path))
    }

    func testDisableSurfacesSetterFailureAndRetainsRecoveryState() throws {
        let uid = "ExternalUSBDevice"
        try EqualizerHALPluginController.writeDefaultOutputBackup(
            uid: uid,
            to: defaultOutputBackupURL
        )

        let forwardingURL = EqualizerHALPluginController.forwardingTargetURL
        let originalForwardingTarget = try? String(contentsOf: forwardingURL, encoding: .utf8)
        defer {
            if let originalForwardingTarget {
                try? originalForwardingTarget.write(to: forwardingURL, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: forwardingURL)
            }
        }
        EqualizerHALPluginController.writeForwardingTarget(uid: "TargetDevice")

        var shouldFail = true
        var restoredIDs: [AudioObjectID] = []
        let controller = EqualizerHALPluginController(
            defaultOutputBackupURL: defaultOutputBackupURL,
            outputDeviceIDForUID: { $0 == uid ? AudioObjectID(91) : nil },
            defaultOutputSetter: { deviceID in
                if shouldFail {
                    shouldFail = false
                    throw EqualizerHALPluginError.coreAudioStatus(-1)
                }
                restoredIDs.append(deviceID)
            }
        )

        XCTAssertThrowsError(try controller.disable()) { error in
            guard case EqualizerHALPluginError.previousOutputRestoreFailed(underlying: let underlying) = error else {
                return XCTFail("expected previousOutputRestoreFailed, got \(error)")
            }
            guard case EqualizerHALPluginError.coreAudioStatus(-1) = underlying else {
                return XCTFail("expected injected CoreAudio failure, got \(underlying)")
            }
        }
        XCTAssertEqual(controller.previousDefaultOutputUID, uid)
        XCTAssertEqual(controller.previousDefaultOutputID, AudioObjectID(91))
        XCTAssertTrue(FileManager.default.fileExists(atPath: defaultOutputBackupURL.path))
        XCTAssertEqual(controller.currentForwardingTargetUID(), "TargetDevice")

        try controller.disable()
        XCTAssertEqual(restoredIDs, [AudioObjectID(91)])
        XCTAssertNil(controller.previousDefaultOutputUID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultOutputBackupURL.path))
    }

    // MARK: - Default-output observation

    func testDefaultOutputProviderReportsDeviceAndDispatchesOutputChanges() {
        let callbackQueue = DispatchQueue(label: "spotiglass-eq-default-output-test")
        let provider = MacDefaultAudioOutputNameProvider(callbackQueue: callbackQueue)
        let change = expectation(description: "default output change")
        defer { provider.stopListening() }

        provider.startListening {
            change.fulfill()
        }

        XCTAssertNotNil(provider.listenerBlock)
        XCTAssertEqual(
            provider.currentOutputDeviceID,
            MacAudioOutputHardware.defaultOutputDeviceID()
        )

        guard let listener = provider.listenerBlock else {
            return XCTFail("the provider should retain its Core Audio listener")
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        withUnsafePointer(to: &address) { addressPointer in
            listener(1, addressPointer)
        }

        wait(for: [change], timeout: mustHappenTimeout)
        provider.stopListening()
        XCTAssertNil(provider.listenerBlock)
    }

    // MARK: - Router readiness and system-output reconciliation

    func testRouterStatusParserReadsReadyAndFailureRecords() throws {
        let statusURL = makeTempDirectory().appendingPathComponent("router.status")
        try "ready\nAirPodsMaxUID\n".write(to: statusURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            EqualizerHALPluginController.readRouterStatus(from: statusURL),
            .ready(targetUID: "AirPodsMaxUID")
        )

        try "failed\nDisconnectedUSBDevice\n3\n".write(
            to: statusURL,
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(
            EqualizerHALPluginController.readRouterStatus(from: statusURL),
            .failed(targetUID: "DisconnectedUSBDevice", reasonCode: 3)
        )
    }

    func testRouterReadinessFailureIsSurfacedWithTheLocalizedEQError() {
        let uid = "DisconnectedUSBDevice"
        let controller = EqualizerHALPluginController(
            routerStatusURL: makeTempDirectory().appendingPathComponent("router.status"),
            routerStatusReader: {
                .failed(targetUID: uid, reasonCode: 3)
            },
            routerReadinessTimeout: 0
        )

        XCTAssertThrowsError(try controller.waitForRouterReadiness(targetUID: uid)) { error in
            guard case let EqualizerHALPluginError.routerTargetOpenFailed(
                targetUID: foundUID,
                reasonCode
            ) = error else {
                return XCTFail("expected routerTargetOpenFailed, got \(error)")
            }
            XCTAssertEqual(foundUID, uid)
            XCTAssertEqual(reasonCode, 3)
            XCTAssertEqual(
                error.localizedDescription,
                SpotiglassL10n.string("eq.error.routerTargetOpenFailed")
            )
        }
    }

    @MainActor
    func testStartDoesNotReportLiveWhenRouterOpenFails() async throws {
        let originalID = AudioObjectID(41)
        let virtualID = AudioObjectID(99)
        let uid = "OriginalOutputUID"
        var setIDs: [AudioObjectID] = []
        let controller = EqualizerHALPluginController(
            halDirectory: halDirectory,
            bundle: fakeAppBundle,
            defaultOutputBackupURL: defaultOutputBackupURL,
            outputDeviceUID: { $0 == originalID ? uid : nil },
            defaultOutputDeviceIDProvider: { originalID },
            virtualDeviceIDProvider: { virtualID },
            defaultOutputSetter: { setIDs.append($0) },
            routerStatusURL: makeTempDirectory().appendingPathComponent("router.status"),
            routerStatusReader: {
                .failed(targetUID: uid, reasonCode: 2)
            },
            routerReadinessTimeout: 0,
            activeSampleRateObservationStarter: { _ in }
        )
        try controller.install()
        let engine = AudioEqualizerEngine(pluginController: controller)

        let error = await startError(of: engine)
        XCTAssertEqual(
            error?.localizedDescription,
            SpotiglassL10n.string("eq.error.routerTargetOpenFailed")
        )
        XCTAssertEqual(setIDs, [virtualID])
        XCTAssertFalse(engine.isRunning)
        guard case .failed = engine.routeState else {
            return XCTFail("a failed router must not publish Live state")
        }
    }

    // MARK: - Sound never stays on the EQ device without a working route (#587)

    /// The Mac's output as CoreAudio would report it, so a test can tell where
    /// the sound ends up after the equalizer gives up.
    private final class FakeMacOutput {
        let originalID = AudioObjectID(41)
        let virtualID = AudioObjectID(99)
        let originalUID = "OriginalOutputUID"
        var current: AudioObjectID
        var setIDs: [AudioObjectID] = []
        var routerStatus: EqualizerRouterStatus?

        init() { current = originalID }
    }

    private func makeController(
        for output: FakeMacOutput,
        routerStatusURL: URL? = nil,
        driverInstaller: EqualizerDriverInstalling? = nil
    ) -> EqualizerHALPluginController {
        EqualizerHALPluginController(
            halDirectory: halDirectory,
            bundle: fakeAppBundle,
            defaultOutputBackupURL: defaultOutputBackupURL,
            driverInstaller: driverInstaller,
            outputDeviceIDForUID: { $0 == output.originalUID ? output.originalID : nil },
            outputDeviceUID: { $0 == output.originalID ? output.originalUID : nil },
            defaultOutputDeviceIDProvider: { output.current },
            virtualDeviceIDProvider: { output.virtualID },
            defaultOutputSetter: { id in
                output.setIDs.append(id)
                output.current = id
            },
            routerStatusURL: routerStatusURL ?? makeTempDirectory().appendingPathComponent("router.status"),
            routerStatusReader: { output.routerStatus },
            routerReadinessTimeout: 0,
            activeSampleRateObservationStarter: { _ in }
        )
    }

    /// Switching the EQ on while its router never comes up (nothing processes
    /// the EQ device) used to leave the Mac's sound on the EQ device, where it
    /// stuttered and sped up.
    @MainActor
    func testASwitchOnTheRouterNeverConfirmsPutsTheSoundBackOnThePreviousDevice() async throws {
        let output = FakeMacOutput()
        let controller = makeController(for: output)
        try controller.install()
        let engine = AudioEqualizerEngine(pluginController: controller)

        let error = await startError(of: engine)
        XCTAssertNotNil(error)

        XCTAssertEqual(output.setIDs, [output.virtualID, output.originalID])
        XCTAssertEqual(output.current, output.originalID, "the sound stayed on the EQ device")
        XCTAssertFalse(engine.isEngaged)
        XCTAssertNotNil(engine.lastError, "nothing said why the equalizer is off")
    }

    /// A live route whose router stops processing hands the sound back by itself.
    @MainActor
    func testALiveRouteThatStopsProcessingPutsTheSoundBack() async throws {
        let output = FakeMacOutput()
        output.routerStatus = .ready(targetUID: output.originalUID)
        let controller = makeController(for: output)
        try controller.install()
        let engine = AudioEqualizerEngine(pluginController: controller)
        try await engine.start()
        XCTAssertEqual(output.current, output.virtualID)

        engine.checkRouteHealth()
        XCTAssertEqual(output.current, output.virtualID, "a working route was torn down")

        output.routerStatus = .failed(targetUID: output.originalUID, reasonCode: 2)
        engine.checkRouteHealth()
        XCTAssertEqual(output.current, output.virtualID, "one bad reading tore the route down")
        engine.checkRouteHealth()

        XCTAssertEqual(output.current, output.originalID, "the sound stayed on the EQ device")
        XCTAssertFalse(engine.isEngaged)
        XCTAssertEqual(engine.lastError, SpotiglassL10n.string("eq.error.routerStopped"))
    }

    private struct FailingDriverInstaller: EqualizerDriverInstalling {
        let error: Error
        func installDriver(sourceURL: URL, destinationURL: URL) throws { throw error }
        func removeDriver(destinationURL: URL) throws { throw error }
    }

    /// Stands in for the privileged helper: does the file work and records
    /// which path it was asked to remove.
    private final class RecordingDriverInstaller: EqualizerDriverInstalling, @unchecked Sendable {
        private let files = EqualizerFileDriverInstaller(fileManager: .default)
        private(set) var removedPaths: [String] = []
        var outputWhenRemoved: (() -> AudioObjectID)?
        private(set) var outputAtRemoval: AudioObjectID?

        func installDriver(sourceURL: URL, destinationURL: URL) throws {
            try files.installDriver(sourceURL: sourceURL, destinationURL: destinationURL)
        }

        func removeDriver(destinationURL: URL) throws {
            outputAtRemoval = outputWhenRemoved?()
            removedPaths.append(destinationURL.path)
            try files.removeDriver(destinationURL: destinationURL)
        }
    }

    @MainActor
    private func waitForTheRemovalToFinish(on engine: AudioEqualizerEngine) async {
        let finished = expectation(description: "the driver removal finished")
        finished.assertForOverFulfill = false
        // @Published replays the current value, so an already finished removal fulfils at once.
        let watch = engine.$isRemovingDriver
            .filter { !$0 }
            .sink { _ in finished.fulfill() }
        await fulfillment(of: [finished], timeout: 5)
        watch.cancel()
    }

    // MARK: - Remove equalizer driver (#606)

    /// The equalizer is on and the Mac plays through "Wax EQ". Removing the
    /// driver used to be impossible from the app; it now puts the sound back on
    /// the speakers first and only then deletes the driver, so the Mac is never
    /// left with a default output that no longer exists.
    @MainActor
    func testRemovingTheDriverPutsTheSoundBackThenDeletesIt() async throws {
        let output = FakeMacOutput()
        output.routerStatus = .ready(targetUID: output.originalUID)
        let installer = RecordingDriverInstaller()
        installer.outputWhenRemoved = { output.current }
        let controller = makeController(for: output, driverInstaller: installer)
        try controller.install()
        let settingsStore = try ViewTestHost.makeSettingsStore()
        let engine = AudioEqualizerEngine(pluginController: controller)
        engine.observe(settingsStore: settingsStore)
        try settingsStore.mutate { $0.equalizer.enabled = true }
        // The start runs off the main actor (#604).
        await waitForRoute(of: engine) { $0.isLive }
        XCTAssertEqual(output.current, output.virtualID)
        XCTAssertTrue(engine.isRunning)

        engine.removeDriver(settingsStore: settingsStore)
        XCTAssertTrue(engine.isRemovingDriver, "the button showed no progress straight away")
        await waitForTheRemovalToFinish(on: engine)

        XCTAssertEqual(installer.outputAtRemoval, output.originalID,
                       "the driver was deleted while the Mac's sound was still on it")
        XCTAssertEqual(installer.removedPaths, [controller.installedDriverURL.path])
        XCTAssertFalse(controller.isInstalled)
        XCTAssertEqual(output.current, output.originalID)
        XCTAssertFalse(settingsStore.settings.equalizer.enabled)
        XCTAssertFalse(engine.isEngaged)
        XCTAssertNil(engine.lastError)
        XCTAssertTrue(engine.driverWasRemoved)
        XCTAssertNil(controller.currentForwardingTargetUID())
    }

    /// If nothing can take the Mac's output off "Wax EQ", deleting the driver
    /// would leave the default output on a device that no longer exists. The
    /// driver stays and the pane says why.
    @MainActor
    func testTheDriverStaysWhenTheSoundCantLeaveTheEQDevice() async throws {
        let output = FakeMacOutput()
        output.current = output.virtualID
        let installer = RecordingDriverInstaller()
        let controller = EqualizerHALPluginController(
            halDirectory: halDirectory,
            bundle: fakeAppBundle,
            defaultOutputBackupURL: defaultOutputBackupURL,
            driverInstaller: installer,
            outputDeviceIDForUID: { _ in nil },
            outputDeviceUID: { _ in nil },
            defaultOutputDeviceIDProvider: { output.current },
            virtualDeviceIDProvider: { output.virtualID },
            defaultOutputSetter: { _ in throw EqualizerHALPluginError.coreAudioStatus(-1) },
            routerStatusReader: { nil },
            routerReadinessTimeout: 0,
            activeSampleRateObservationStarter: { _ in }
        )
        try controller.install()
        let engine = AudioEqualizerEngine(pluginController: controller)

        engine.removeDriver(settingsStore: nil)
        await waitForTheRemovalToFinish(on: engine)

        XCTAssertTrue(installer.removedPaths.isEmpty, "the driver was deleted under the default output")
        XCTAssertTrue(controller.isInstalled)
        XCTAssertFalse(engine.driverWasRemoved)
        XCTAssertEqual(engine.lastError, SpotiglassL10n.string("eq.error.outputStuckOnEqualizerDevice"))
    }

    /// The headphones the sound was on before the EQ were unplugged, so switching
    /// the EQ off can't put the sound back there. Removal used to stop at that
    /// error and turn the switch back on; it now moves the sound to another output
    /// that plays and removes the driver.
    @MainActor
    func testRemovingTheDriverAfterThePreEQDeviceIsGoneUsesAnotherOutput() async throws {
        let output = FakeMacOutput()
        output.routerStatus = .ready(targetUID: output.originalUID)
        let speakersID = AudioObjectID(7)
        var originalIsPlugged = true
        let installer = RecordingDriverInstaller()
        installer.outputWhenRemoved = { output.current }
        let controller = EqualizerHALPluginController(
            halDirectory: halDirectory,
            bundle: fakeAppBundle,
            defaultOutputBackupURL: defaultOutputBackupURL,
            driverInstaller: installer,
            outputDeviceIDForUID: { uid in
                if uid == output.originalUID { return originalIsPlugged ? output.originalID : nil }
                return uid == EqualizerHALPluginController.fallbackForwardingUID ? speakersID : nil
            },
            outputDeviceUID: { $0 == output.originalID ? output.originalUID : nil },
            defaultOutputDeviceIDProvider: { output.current },
            virtualDeviceIDProvider: { output.virtualID },
            defaultOutputSetter: { id in output.current = id },
            routerStatusURL: makeTempDirectory().appendingPathComponent("router.status"),
            routerStatusReader: { output.routerStatus },
            routerReadinessTimeout: 0,
            activeSampleRateObservationStarter: { _ in }
        )
        try controller.install()
        let settingsStore = try ViewTestHost.makeSettingsStore()
        let engine = AudioEqualizerEngine(pluginController: controller)
        engine.observe(settingsStore: settingsStore)
        try settingsStore.mutate { $0.equalizer.enabled = true }
        // The start runs off the main actor (#604).
        await waitForRoute(of: engine) { $0.isLive }
        XCTAssertEqual(output.current, output.virtualID)

        originalIsPlugged = false
        engine.removeDriver(settingsStore: settingsStore)
        await waitForTheRemovalToFinish(on: engine)

        XCTAssertEqual(installer.outputAtRemoval, speakersID,
                       "the driver was deleted while the Mac's sound was still on it")
        XCTAssertEqual(installer.removedPaths, [controller.installedDriverURL.path],
                       "removal gave up because the pre-EQ device was gone")
        XCTAssertEqual(output.current, speakersID)
        XCTAssertTrue(engine.driverWasRemoved)
        XCTAssertFalse(engine.isEngaged)
        XCTAssertFalse(settingsStore.settings.equalizer.enabled, "the switch went back on after the driver was removed")
    }

    /// The helper deletes only the one driver bundle in the HAL folder.
    func testTheHelperIsOnlyAskedToRemoveTheInstalledDriver() {
        let client = EqualizerPrivilegedHelperClient(bundle: fakeAppBundle)
        XCTAssertThrowsError(
            try client.removeDriver(destinationURL: URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/Other.driver"))
        ) { error in
            XCTAssertEqual(error as? EqualizerDriverInstallError, .invalidRequest)
        }
        XCTAssertThrowsError(
            try client.removeDriver(destinationURL: URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/../../../Applications"))
        ) { error in
            XCTAssertEqual(error as? EqualizerDriverInstallError, .invalidRequest)
        }
    }

    /// Quitting with the equalizer on left the Mac's output on "Wax EQ". After
    /// a restart (or with Wax deleted) nothing moved it back and the Mac stayed
    /// silent. Quitting now puts the sound back and keeps the switch on, so the
    /// next launch brings the equalizer back.
    @MainActor
    func testQuittingWithTheEqualizerOnPutsTheSoundBack() async throws {
        let output = FakeMacOutput()
        output.routerStatus = .ready(targetUID: output.originalUID)
        let controller = makeController(for: output)
        try controller.install()
        let settingsStore = try ViewTestHost.makeSettingsStore()
        let engine = AudioEqualizerEngine(pluginController: controller)
        engine.observe(settingsStore: settingsStore)
        try settingsStore.mutate { $0.equalizer.enabled = true }
        // The start runs off the main actor (#604).
        await waitForRoute(of: engine) { $0.isLive }
        XCTAssertEqual(output.current, output.virtualID)

        engine.releaseOutputForQuit()

        XCTAssertEqual(output.current, output.originalID, "the sound stayed on the EQ device after quitting")
        XCTAssertTrue(settingsStore.settings.equalizer.enabled, "quitting turned the equalizer off for the next launch")
    }

    /// Waits for the store to publish the switch going back off. On the old code that never
    /// happened (the write was swallowed), so the timeout is the failure, not a pause.
    @MainActor
    private func waitForTheSwitchToGoBackOff(in settingsStore: SpotiglassSettingsStore) async {
        await waitForTheSwitch(in: settingsStore, toBe: false)
    }

    @MainActor
    private func waitForTheSwitch(in settingsStore: SpotiglassSettingsStore, toBe enabled: Bool) async {
        let flipped = expectation(description: "the equalizer switch went \(enabled ? "back on" : "back off")")
        flipped.assertForOverFulfill = false
        let watch = settingsStore.$settings
            .filter { $0.equalizer.enabled == enabled }
            .sink { _ in flipped.fulfill() }
        await fulfillment(of: [flipped], timeout: 5)
        watch.cancel()
    }

    /// Switching the equalizer on when the helper can't install the driver flipped the switch
    /// back with nothing on screen saying why (#587).
    @MainActor
    func testAFailedDriverInstallFlipsTheSwitchBackAndSaysWhy() async throws {
        let output = FakeMacOutput()
        let controller = EqualizerHALPluginController(
            halDirectory: halDirectory,
            bundle: fakeAppBundle,
            defaultOutputBackupURL: defaultOutputBackupURL,
            driverInstaller: FailingDriverInstaller(
                error: EqualizerDriverInstallError.helperUnavailable(message: "connection invalidated")
            ),
            defaultOutputDeviceIDProvider: { output.current },
            virtualDeviceIDProvider: { nil },
            defaultOutputSetter: { output.current = $0 },
            routerStatusReader: { nil },
            driverLoadTimeout: 0,
            activeSampleRateObservationStarter: { _ in }
        )
        let settingsStore = try ViewTestHost.makeSettingsStore()
        let engine = AudioEqualizerEngine(pluginController: controller)
        engine.observe(settingsStore: settingsStore)

        try settingsStore.mutate { $0.equalizer.enabled = true }
        await waitForTheSwitchToGoBackOff(in: settingsStore)

        XCTAssertFalse(settingsStore.settings.equalizer.enabled, "the switch stayed on")
        XCTAssertFalse(SpotiglassSettingsStore(fileURL: settingsStore.fileURL).settings.equalizer.enabled,
                       "the switch is off in memory but on in the settings file")
        XCTAssertEqual(output.current, output.originalID)
        XCTAssertEqual(engine.lastError, SpotiglassL10n.string("eq.error.driverInstallationFailed"),
                       "nothing said why the equalizer is off")
    }

    /// The driver installs but Core Audio never shows its device: same switch-back, same need
    /// for a line saying why (#587).
    @MainActor
    func testADriverThatNeverLoadsFlipsTheSwitchBackAndSaysWhy() async throws {
        let output = FakeMacOutput()
        let controller = EqualizerHALPluginController(
            halDirectory: halDirectory,
            bundle: fakeAppBundle,
            defaultOutputBackupURL: defaultOutputBackupURL,
            defaultOutputDeviceIDProvider: { output.current },
            virtualDeviceIDProvider: { nil },
            defaultOutputSetter: { output.current = $0 },
            routerStatusReader: { nil },
            driverLoadTimeout: 0,
            activeSampleRateObservationStarter: { _ in }
        )
        let settingsStore = try ViewTestHost.makeSettingsStore()
        let engine = AudioEqualizerEngine(pluginController: controller)
        engine.observe(settingsStore: settingsStore)

        try settingsStore.mutate { $0.equalizer.enabled = true }
        await waitForTheSwitchToGoBackOff(in: settingsStore)

        XCTAssertFalse(settingsStore.settings.equalizer.enabled, "the switch stayed on")
        XCTAssertFalse(SpotiglassSettingsStore(fileURL: settingsStore.fileURL).settings.equalizer.enabled,
                       "the switch is off in memory but on in the settings file")
        XCTAssertEqual(output.current, output.originalID)
        XCTAssertEqual(engine.lastError, SpotiglassL10n.string("eq.error.driverNotLoadedYet"),
                       "nothing said why the equalizer is off")
    }

    /// Switching the equalizer off when the previous output has gone away can't take the sound
    /// off the EQ device, so the switch has to stay on: an off switch would claim the sound is
    /// back. The write that put it back on used to be overwritten by the "off" change that
    /// triggered it (#587).
    @MainActor
    func testAFailedSwitchOffKeepsTheSwitchOnWhileTheSoundIsStillOnTheEQDevice() async throws {
        let output = FakeMacOutput()
        output.routerStatus = .ready(targetUID: output.originalUID)
        var previousOutputIsConnected = true
        let controller = EqualizerHALPluginController(
            halDirectory: halDirectory,
            bundle: fakeAppBundle,
            defaultOutputBackupURL: defaultOutputBackupURL,
            outputDeviceIDForUID: { uid in
                previousOutputIsConnected && uid == output.originalUID ? output.originalID : nil
            },
            outputDeviceUID: { $0 == output.originalID ? output.originalUID : nil },
            defaultOutputDeviceIDProvider: { output.current },
            virtualDeviceIDProvider: { output.virtualID },
            defaultOutputSetter: { output.current = $0 },
            routerStatusURL: makeTempDirectory().appendingPathComponent("router.status"),
            routerStatusReader: { output.routerStatus },
            routerReadinessTimeout: 0,
            activeSampleRateObservationStarter: { _ in }
        )
        defer { EqualizerHALPluginController.clearForwardingTarget() }
        try controller.install()
        let settingsStore = try ViewTestHost.makeSettingsStore()
        let engine = AudioEqualizerEngine(pluginController: controller)
        engine.observe(settingsStore: settingsStore)
        try settingsStore.mutate { $0.equalizer.enabled = true }
        await waitForRoute(of: engine) { $0.isLive }
        XCTAssertEqual(output.current, output.virtualID)
        XCTAssertTrue(engine.isRunning)

        previousOutputIsConnected = false
        try settingsStore.mutate { $0.equalizer.enabled = false }
        await waitForTheSwitch(in: settingsStore, toBe: true)

        XCTAssertTrue(settingsStore.settings.equalizer.enabled, "the switch went off with the sound still on the EQ device")
        XCTAssertTrue(SpotiglassSettingsStore(fileURL: settingsStore.fileURL).settings.equalizer.enabled,
                      "the switch is on in memory but off in the settings file")
        XCTAssertEqual(output.current, output.virtualID)
        XCTAssertTrue(engine.isEngaged)
        XCTAssertNotNil(engine.lastError, "nothing said why the equalizer is still on")
    }

    /// A Mac left on the EQ device by an earlier failed run gets its sound back
    /// on the next launch with the equalizer off.
    @MainActor
    func testLaunchWithTheEqualizerOffTakesTheSoundOffAStrandedEQDevice() throws {
        let output = FakeMacOutput()
        output.current = output.virtualID
        try EqualizerHALPluginController.writeDefaultOutputBackup(
            uid: output.originalUID,
            to: defaultOutputBackupURL,
            fileManager: .default
        )
        let engine = AudioEqualizerEngine(pluginController: makeController(for: output))

        engine.releaseStrandedOutput()

        XCTAssertEqual(output.current, output.originalID, "the sound stayed on the EQ device")
    }

    /// Settings › Equalizer shows why the EQ isn't running. The pane sits in the same window as
    /// the language picker, and the reason stayed in the old language after a switch (#571).
    @MainActor
    func testTheRouteFailureFollowsALanguageSwitch() async throws {
        let languageStore = try ViewTestHost.makeSettingsStore()
        SpotiglassL10n.settingsStore = languageStore
        defer { SpotiglassL10n.settingsStore = nil }
        try languageStore.mutate { $0.appearance.language = .english }
        let originalID = AudioObjectID(41)
        let virtualID = AudioObjectID(99)
        let uid = "OriginalOutputUID"
        let controller = EqualizerHALPluginController(
            halDirectory: halDirectory,
            bundle: fakeAppBundle,
            defaultOutputBackupURL: defaultOutputBackupURL,
            outputDeviceUID: { $0 == originalID ? uid : nil },
            defaultOutputDeviceIDProvider: { originalID },
            virtualDeviceIDProvider: { virtualID },
            defaultOutputSetter: { _ in },
            routerStatusURL: makeTempDirectory().appendingPathComponent("router.status"),
            routerStatusReader: {
                .failed(targetUID: uid, reasonCode: 2)
            },
            routerReadinessTimeout: 0,
            activeSampleRateObservationStarter: { _ in }
        )
        try controller.install()
        let engine = AudioEqualizerEngine(pluginController: controller)
        let error = await startError(of: engine)
        XCTAssertNotNil(error)
        XCTAssertEqual(engine.lastError, SpotiglassL10n.string("eq.error.routerTargetOpenFailed"))

        try languageStore.mutate { $0.appearance.language = .german }

        XCTAssertEqual(
            engine.lastError,
            SpotiglassL10n.string("eq.error.routerTargetOpenFailed", locale: Locale(identifier: "de")),
            "The equalizer's reason stayed in the old language"
        )
    }

    @MainActor
    func testSelectingHardwareOutputWhileEQIsEnabledKeepsVirtualOutputAsDefault() async throws {
        let originalID = AudioObjectID(41)
        let selectedID = AudioObjectID(42)
        let virtualID = AudioObjectID(99)
        let originalUID = "OriginalOutputUID"
        let selectedUID = "SelectedOutputUID"
        var statusTarget = originalUID
        var setIDs: [AudioObjectID] = []
        let controller = EqualizerHALPluginController(
            halDirectory: halDirectory,
            bundle: fakeAppBundle,
            defaultOutputBackupURL: defaultOutputBackupURL,
            outputDeviceUID: { deviceID in
                switch deviceID {
                case originalID: originalUID
                case selectedID: selectedUID
                default: nil
                }
            },
            defaultOutputDeviceIDProvider: { originalID },
            virtualDeviceIDProvider: { virtualID },
            defaultOutputSetter: { setIDs.append($0) },
            routerStatusURL: makeTempDirectory().appendingPathComponent("router.status"),
            routerStatusReader: {
                .ready(targetUID: statusTarget)
            },
            activeSampleRateObservationStarter: { _ in }
        )
        try controller.install()
        let engine = AudioEqualizerEngine(pluginController: controller)
        try await engine.start()

        let macOutput = TestEqualizerMacOutputProvider(deviceID: selectedID)
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()),
            macAudioOutput: macOutput,
            equalizerEngine: engine,
            defaults: UserDefaults(suiteName: "spotiglass-eq-routing-\(UUID().uuidString)")!
        )
        statusTarget = selectedUID
        viewModel.setSystemDefaultOutputDevice(selectedID)
        await waitForRoute(of: engine) { $0 == .live(targetUID: selectedUID, errorMessage: nil) }

        XCTAssertEqual(setIDs, [virtualID, virtualID])
        XCTAssertEqual(controller.currentForwardingTargetUID(), selectedUID)
        XCTAssertEqual(
            engine.routeState,
            .live(targetUID: selectedUID, errorMessage: nil)
        )

        // A later Control Center-style notification follows the same route
        // state machine rather than bypassing the EQ or creating a second
        // status interpretation in the playback model.
        statusTarget = originalUID
        macOutput.currentOutputDeviceID = originalID
        macOutput.emitOutputChange()
        // The change is handled on a task of its own and the route waits off the main actor
        // (#604); wait for the route to settle on the new target however late that is.
        await waitForRoute(of: engine) { $0 == .live(targetUID: originalUID, errorMessage: nil) }

        XCTAssertEqual(setIDs, [virtualID, virtualID, virtualID])
        XCTAssertEqual(controller.currentForwardingTargetUID(), originalUID)
        XCTAssertEqual(
            engine.routeState,
            .live(targetUID: originalUID, errorMessage: nil)
        )
        XCTAssertTrue(engine.isRunning)
    }

    // MARK: - Built-in preset → coefficient frame round-trip

    func testAllSevenBuiltInPresetsProduceUniqueCoefficientFrames() {
        // Confirms `EqualizerPreset.builtIns` is wired to coefficient
        // generation correctly: each preset (except Flat) produces a frame
        // distinguishable from the bypass identity.
        let bypass = EQCoefficientFrame.bypass(sampleRateHz: 48_000)
        var seen: Set<String> = []
        for preset in EqualizerPreset.builtIns {
            var settings = EqualizerSettings()
            settings.apply(preset: preset)
            let frame = EQCoefficientFrame.build(settings: settings, sampleRateHz: 48_000)
            let fingerprint = frame.bands.map { String(format: "%.4f", $0) }.joined(separator: ",")
            XCTAssertFalse(seen.contains(fingerprint),
                           "two presets produced identical coefficients: \(preset.name)")
            seen.insert(fingerprint)
            if preset.name != EqualizerPreset.flatName {
                XCTAssertNotEqual(frame.bands, bypass.bands,
                                  "\(preset.name) should differ from bypass")
            }
        }
    }

    func testForwardingFormatAcceptsOnlyFloat32StereoLayouts() {
        var interleaved = AudioStreamBasicDescription()
        interleaved.mFormatID = kAudioFormatLinearPCM
        interleaved.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        interleaved.mBytesPerPacket = 8
        interleaved.mFramesPerPacket = 1
        interleaved.mBytesPerFrame = 8
        interleaved.mChannelsPerFrame = 2
        interleaved.mBitsPerChannel = 32

        var nonInterleaved = interleaved
        nonInterleaved.mFormatFlags |= kAudioFormatFlagIsNonInterleaved
        nonInterleaved.mBytesPerPacket = 4
        nonInterleaved.mBytesPerFrame = 4

        var integerStereo = interleaved
        integerStereo.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked

        var threeChannel = interleaved
        threeChannel.mChannelsPerFrame = 3
        threeChannel.mBytesPerPacket = 12
        threeChannel.mBytesPerFrame = 12

        XCTAssertTrue(AudioDeviceEnumerator.supportsEQForwarding(format: interleaved))
        XCTAssertTrue(AudioDeviceEnumerator.supportsEQForwarding(format: nonInterleaved))
        XCTAssertFalse(AudioDeviceEnumerator.supportsEQForwarding(format: integerStereo))
        XCTAssertFalse(AudioDeviceEnumerator.supportsEQForwarding(format: threeChannel))
    }

    func testControllerPublishesAChangedDeviceSampleRateOnce() {
        let controller = EqualizerHALPluginController()
        var received: [UInt32] = []
        controller.activeSampleRateDidChange = { received.append($0) }

        XCTAssertTrue(controller.updateActiveSampleRate(nominalRate: 44_100))
        XCTAssertFalse(controller.updateActiveSampleRate(nominalRate: 44_100))
        XCTAssertFalse(controller.updateActiveSampleRate(nominalRate: 0))
        XCTAssertEqual(received, [44_100])
        XCTAssertEqual(controller.activeSampleRate, 44_100)
    }

    @MainActor
    func testActiveSampleRateChangePublishesCoefficientsForThatRate() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("spotiglass-eq-rate-\(UUID().uuidString).shm")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let publisher = EQCoefficientPublisher(shmPath: path)
        let sampleRateProvider = TestSampleRateProvider(sampleRate: 48_000)
        let engine = AudioEqualizerEngine(
            coefficientPublisher: publisher,
            sampleRateProvider: sampleRateProvider
        )
        var settings = EqualizerSettings(enabled: true)
        settings.bands[5] = 6

        engine.apply(settings: settings)
        let at48k = try XCTUnwrap(publisher.readForTesting())
        sampleRateProvider.setActiveSampleRate(44_100)
        let at44k = try XCTUnwrap(publisher.readForTesting())

        let expectedAt44k = EQCoefficientFrame.build(
            settings: settings,
            sampleRateHz: 44_100
        )
        XCTAssertEqual(at44k.sampleRateHz, 44_100)
        XCTAssertEqual(at44k.bands, expectedAt44k.bands)
        XCTAssertNotEqual(at44k.bands, at48k.bands)
    }

    // MARK: - Settings reload observation

    @MainActor
    func testExternalSettingsReloadReappliesCoefficientsWhileEngineIsRunning() async throws {
        let settingsURL = makeTempDirectory().appendingPathComponent("settings.json")
        var initialSettings = SpotiglassSettingsStore.bootstrapDefaults()
        initialSettings.equalizer.enabled = true
        initialSettings.equalizer.bands[0] = -2
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(initialSettings).write(to: settingsURL)
        let settingsStore = SpotiglassSettingsStore(fileURL: settingsURL)

        let originalOutputID = AudioObjectID(41)
        let virtualOutputID = AudioObjectID(99)
        let originalOutputUID = "OriginalOutputUID"
        var routedOutputIDs: [AudioObjectID] = []
        let controller = EqualizerHALPluginController(
            halDirectory: halDirectory,
            bundle: fakeAppBundle,
            defaultOutputBackupURL: defaultOutputBackupURL,
            outputDeviceIDForUID: { uid in
                uid == originalOutputUID ? originalOutputID : nil
            },
            outputDeviceUID: { deviceID in
                deviceID == originalOutputID ? originalOutputUID : nil
            },
            defaultOutputDeviceIDProvider: { originalOutputID },
            virtualDeviceIDProvider: { virtualOutputID },
            defaultOutputSetter: { routedOutputIDs.append($0) },
            routerStatusReader: {
                .ready(targetUID: originalOutputUID)
            },
            routerReadinessTimeout: 0,
            activeSampleRateObservationStarter: { _ in }
        )
        let coefficientPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("spotiglass-eq-settings-\(UUID().uuidString).shm")
        defer {
            try? FileManager.default.removeItem(atPath: coefficientPath)
            EqualizerHALPluginController.clearForwardingTarget()
        }

        let publisher = EQCoefficientPublisher(shmPath: coefficientPath)
        let engine = AudioEqualizerEngine(
            pluginController: controller,
            coefficientPublisher: publisher
        )
        try await engine.start()
        engine.observe(settingsStore: settingsStore)
        XCTAssertEqual(
            engine.routeState,
            .live(targetUID: originalOutputUID, errorMessage: nil)
        )
        XCTAssertEqual(routedOutputIDs, [virtualOutputID])

        let beforeReload = try XCTUnwrap(publisher.readForTesting())
        var externalSettings = initialSettings
        externalSettings.equalizer.bands[0] = 8
        try encoder.encode(externalSettings).write(to: settingsURL, options: .atomic)

        settingsStore.reloadFromDisk()

        let afterReload = try XCTUnwrap(publisher.readForTesting())
        let expected = EQCoefficientFrame.build(
            settings: externalSettings.equalizer,
            sampleRateHz: controller.activeSampleRate
        )
        XCTAssertEqual(
            engine.routeState,
            .live(targetUID: originalOutputUID, errorMessage: nil),
            "a curve reload must not restart or disable the running EQ"
        )
        XCTAssertEqual(afterReload.preampLinear, expected.preampLinear)
        XCTAssertEqual(afterReload.bands, expected.bands)
        XCTAssertEqual(afterReload.sampleRateHz, expected.sampleRateHz)
        XCTAssertEqual(afterReload.enabledMask, expected.enabledMask)
        XCTAssertNotEqual(afterReload.bands, beforeReload.bands)
        XCTAssertEqual(routedOutputIDs, [virtualOutputID], "reloading a curve must not reroute the output")

        // The injected #252 routing seams keep cleanup in-process and prove the
        // running engine still has a recoverable pre-EQ output after the reload.
        try engine.stop()
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(routedOutputIDs, [virtualOutputID, originalOutputID])
    }

    // MARK: - Slow helper or Core Audio (#604)

    /// An installer that is still busy (an approved helper that hangs, or coreaudiod coming back
    /// after the helper restarted it) until the test lets it finish. It gives up after 2 s, so the
    /// old code, which waited on the main thread, ends instead of hanging the test.
    private final class HeldDriverInstaller: EqualizerDriverInstalling, @unchecked Sendable {
        private let held = DispatchSemaphore(value: 0)

        func letItFinish() { held.signal() }

        func installDriver(sourceURL: URL, destinationURL: URL) throws {
            _ = held.wait(timeout: .now() + 2)
            try EqualizerFileDriverInstaller(fileManager: .default)
                .installDriver(sourceURL: sourceURL, destinationURL: destinationURL)
        }

        func removeDriver(destinationURL: URL) throws {
            try EqualizerFileDriverInstaller(fileManager: .default).removeDriver(destinationURL: destinationURL)
        }
    }

    /// Switching the equalizer on froze the whole app with a beachball while the helper or
    /// Core Audio was slow: the install and the waits ran on the main thread.
    @MainActor
    func testStartingTheEqualizerNeverBlocksTheMainThread() async throws {
        let output = FakeMacOutput()
        output.routerStatus = .ready(targetUID: output.originalUID)
        let installer = HeldDriverInstaller()
        let engine = AudioEqualizerEngine(pluginController: makeController(for: output, driverInstaller: installer))
        var stateWhileInstalling: EqualizerRouteState?
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated { stateWhileInstalling = engine.routeState }
            installer.letItFinish()
        }

        try await engine.start()

        XCTAssertEqual(stateWhileInstalling, .starting(targetUID: nil),
                       "the main thread was blocked until the equalizer had started")
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(output.current, output.virtualID)
    }

    /// A launch with the equalizer on showed no window until the driver was up: the restore ran
    /// inside the app's init.
    @MainActor
    func testALaunchWithTheEqualizerOnDoesNotWaitForTheDriver() async throws {
        let output = FakeMacOutput()
        output.routerStatus = .ready(targetUID: output.originalUID)
        let installer = HeldDriverInstaller()
        let engine = AudioEqualizerEngine(pluginController: makeController(for: output, driverInstaller: installer))
        let settingsStore = try ViewTestHost.makeSettingsStore()
        try settingsStore.mutate { $0.equalizer.enabled = true }

        engine.observe(settingsStore: settingsStore)

        XCTAssertFalse(engine.isRunning, "the launch waited for the driver before going on")
        await waitForRoute(of: engine) { $0 == .starting(targetUID: nil) }
        installer.letItFinish()
        await waitForRoute(of: engine) { $0.isLive }
        XCTAssertEqual(output.current, output.virtualID)
        XCTAssertTrue(settingsStore.settings.equalizer.enabled)
    }

    /// With the start no longer blocking, the switch can go off while the driver is still coming
    /// up. The sound must not be left on the EQ device with the switch off.
    @MainActor
    func testSwitchingOffWhileTheEqualizerIsStartingPutsTheSoundBack() async throws {
        let output = FakeMacOutput()
        output.routerStatus = .ready(targetUID: output.originalUID)
        let installer = HeldDriverInstaller()
        let engine = AudioEqualizerEngine(pluginController: makeController(for: output, driverInstaller: installer))
        let settingsStore = try ViewTestHost.makeSettingsStore()
        engine.observe(settingsStore: settingsStore)

        try settingsStore.mutate { $0.equalizer.enabled = true }
        await waitForRoute(of: engine) { $0 == .starting(targetUID: nil) }
        try settingsStore.mutate { $0.equalizer.enabled = false }
        installer.letItFinish()
        await waitForRoute(of: engine) { $0 == .disabled }

        XCTAssertEqual(output.current, output.originalID, "the sound stayed on the EQ device with the switch off")
        XCTAssertFalse(settingsStore.settings.equalizer.enabled)
    }

    /// "Remove equalizer driver" pressed while the equalizer was still starting ran next to the
    /// start on the controller: the driver was deleted, then the start installed it again.
    @MainActor
    func testRemovingTheDriverWhileTheEqualizerIsStartingWaitsForTheStart() async throws {
        let output = FakeMacOutput()
        output.routerStatus = .ready(targetUID: output.originalUID)
        let installer = HeldDriverInstaller()
        let controller = makeController(for: output, driverInstaller: installer)
        let engine = AudioEqualizerEngine(pluginController: controller)
        let settingsStore = try ViewTestHost.makeSettingsStore()
        engine.observe(settingsStore: settingsStore)
        try settingsStore.mutate { $0.equalizer.enabled = true }
        await waitForRoute(of: engine) { $0 == .starting(targetUID: nil) }

        engine.removeDriver(settingsStore: settingsStore)
        XCTAssertTrue(engine.isRemovingDriver, "the button showed no progress straight away")
        XCTAssertEqual(engine.routeState, .starting(targetUID: nil),
                       "the removal went ahead on the controller while the start was still running")
        installer.letItFinish()
        await waitForTheRemovalToFinish(on: engine)

        XCTAssertFalse(controller.isInstalled, "the start put the driver back after it was removed")
        XCTAssertTrue(engine.driverWasRemoved)
        XCTAssertEqual(engine.routeState, .disabled)
        XCTAssertEqual(output.current, output.originalID)
        XCTAssertFalse(settingsStore.settings.equalizer.enabled)
    }

    /// The player's output menu stays usable while the equalizer starts. A device picked there
    /// meanwhile was dropped, and the sound went to the old device once the equalizer was up.
    @MainActor
    func testAnOutputPickedFromTheMenuWhileTheEqualizerIsStartingIsUsedOnceItIsUp() async throws {
        let rig = makeTwoOutputRig()
        let starting = Task { try await rig.engine.start() }
        await waitForRoute(of: rig.engine) { $0 == .starting(targetUID: nil) }

        rig.viewModel.setSystemDefaultOutputDevice(rig.selectedID)
        rig.installer.letItFinish()
        try await starting.value
        await waitForRoute(of: rig.engine) { $0 == .live(targetUID: rig.selectedUID, errorMessage: nil) }

        XCTAssertEqual(rig.controller.currentForwardingTargetUID(), rig.selectedUID)
    }

    /// Same for Control Center or another app: the change arrived while the equalizer was starting,
    /// was dropped, and the equalizer kept sending the sound to the old device.
    @MainActor
    func testAnOutputChosenInControlCenterWhileTheEqualizerIsStartingIsUsedOnceItIsUp() async throws {
        let rig = makeTwoOutputRig()
        let starting = Task { try await rig.engine.start() }
        await waitForRoute(of: rig.engine) { $0 == .starting(targetUID: nil) }

        rig.macOutput.currentOutputDeviceID = rig.selectedID
        rig.macOutput.emitOutputChange()
        // The notification is handled on a main-actor task of its own. It is queued before the
        // start can resume there, so it reaches the engine while the route still says "starting".
        rig.installer.letItFinish()
        try await starting.value
        await waitForRoute(of: rig.engine) { $0 == .live(targetUID: rig.selectedUID, errorMessage: nil) }

        XCTAssertEqual(rig.controller.currentForwardingTargetUID(), rig.selectedUID)
    }

    /// A device picked while the equalizer was starting must not be lost when the equalizer then
    /// gives up: before, the click ran after the freeze and set that device directly.
    @MainActor
    func testAnOutputPickedWhileTheEqualizerIsStartingIsUsedWhenTheStartFails() async throws {
        let rig = makeTwoOutputRig(routerOpens: false)
        let starting = Task { try await rig.engine.start() }
        await waitForRoute(of: rig.engine) { $0 == .starting(targetUID: nil) }

        rig.viewModel.setSystemDefaultOutputDevice(rig.selectedID)
        rig.installer.letItFinish()
        do {
            try await starting.value
            XCTFail("the router never opened, so the start should have failed")
        } catch {}

        XCTAssertFalse(rig.engine.isEngaged)
        XCTAssertEqual(rig.output.current, rig.selectedID, "the sound went back to the old device instead of the picked one")
    }

    @MainActor
    func testAnOutputPickedWhileTheEqualizerIsStartingIsUsedWhenItIsSwitchedOffMeanwhile() async throws {
        let rig = makeTwoOutputRig()
        let settingsStore = try ViewTestHost.makeSettingsStore()
        rig.engine.observe(settingsStore: settingsStore)
        try settingsStore.mutate { $0.equalizer.enabled = true }
        await waitForRoute(of: rig.engine) { $0 == .starting(targetUID: nil) }

        rig.viewModel.setSystemDefaultOutputDevice(rig.selectedID)
        try settingsStore.mutate { $0.equalizer.enabled = false }
        rig.installer.letItFinish()
        await waitForRoute(of: rig.engine) { $0 == .disabled }

        XCTAssertEqual(rig.output.current, rig.selectedID, "the sound went back to the old device instead of the picked one")
    }

    /// The Mac's default output as the rig's controller sets and reads it, from the route's queue
    /// and from the test.
    private final class RigOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var storedCurrent: AudioObjectID

        init(current: AudioObjectID) { storedCurrent = current }

        var current: AudioObjectID {
            get { lock.withLock { storedCurrent } }
            set { lock.withLock { storedCurrent = newValue } }
        }
    }

    private struct TwoOutputRig {
        let selectedID = AudioObjectID(42)
        let selectedUID = "SelectedOutputUID"
        let installer: HeldDriverInstaller
        let output: RigOutput
        let controller: EqualizerHALPluginController
        let engine: AudioEqualizerEngine
        let macOutput: TestEqualizerMacOutputProvider
        let viewModel: PlaybackSessionViewModel
    }

    /// Two hardware outputs, an install that waits for the test, and a router that opens whatever
    /// target was last written, or never opens anything.
    @MainActor
    private func makeTwoOutputRig(routerOpens: Bool = true) -> TwoOutputRig {
        let originalID = AudioObjectID(41)
        let selectedID = AudioObjectID(42)
        let virtualID = AudioObjectID(99)
        let uids = [originalID: "OriginalOutputUID", selectedID: "SelectedOutputUID"]
        let installer = HeldDriverInstaller()
        let output = RigOutput(current: originalID)
        let controller = EqualizerHALPluginController(
            halDirectory: halDirectory,
            bundle: fakeAppBundle,
            defaultOutputBackupURL: defaultOutputBackupURL,
            driverInstaller: installer,
            outputDeviceIDForUID: { uid in uids.first { $0.value == uid }?.key },
            outputDeviceUID: { uids[$0] },
            defaultOutputDeviceIDProvider: { output.current },
            virtualDeviceIDProvider: { virtualID },
            defaultOutputSetter: { output.current = $0 },
            routerStatusURL: makeTempDirectory().appendingPathComponent("router.status"),
            routerStatusReader: {
                guard routerOpens else { return nil }
                let written = try? String(contentsOf: EqualizerHALPluginController.forwardingTargetURL, encoding: .utf8)
                return written.map { .ready(targetUID: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            },
            routerReadinessTimeout: 0.2,
            activeSampleRateObservationStarter: { _ in }
        )
        let engine = AudioEqualizerEngine(pluginController: controller)
        let macOutput = TestEqualizerMacOutputProvider(deviceID: originalID)
        let viewModel = PlaybackSessionViewModel(
            provider: SpotifyPlaybackProvider(playbackAPI: MockPlaybackAPI(), webCommander: MockWebPlaybackCommander()),
            macAudioOutput: macOutput,
            equalizerEngine: engine,
            defaults: UserDefaults(suiteName: "spotiglass-eq-starting-\(UUID().uuidString)")!
        )
        return TwoOutputRig(
            installer: installer,
            output: output,
            controller: controller,
            engine: engine,
            macOutput: macOutput,
            viewModel: viewModel
        )
    }

    /// Waits for the engine's route to reach a state. Fails after 5 s rather than hanging.
    @MainActor
    private func waitForRoute(
        of engine: AudioEqualizerEngine,
        _ isReached: @escaping (EqualizerRouteState) -> Bool
    ) async {
        let reached = expectation(description: "the equalizer route reached the expected state")
        reached.assertForOverFulfill = false
        let watch = engine.$routeState
            .filter(isReached)
            .sink { _ in reached.fulfill() }
        await fulfillment(of: [reached], timeout: 5)
        watch.cancel()
    }

    @MainActor
    private func startError(of engine: AudioEqualizerEngine) async -> Error? {
        do {
            try await engine.start()
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Helpers

    private func makeTempDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("spotiglass-eq-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class TestEqualizerMacOutputProvider: MacDefaultAudioOutputProviding {
    let currentOutputDisplayName = "Test output"
    var currentOutputDeviceID: AudioDeviceID?
    private var onChange: (() -> Void)?

    init(deviceID: AudioDeviceID) {
        currentOutputDeviceID = deviceID
    }

    func startListening(_ onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func stopListening() {
        onChange = nil
    }

    func emitOutputChange() {
        onChange?()
    }
}
