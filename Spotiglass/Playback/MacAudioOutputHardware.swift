import AudioToolbox
import CoreAudio
import Foundation

/// One Core Audio output-capable device (HAL).
struct MacAudioOutputDevice: Identifiable, Equatable, Hashable {
    let id: AudioDeviceID
    let name: String
}

/// Enumerates output devices and sets the system default output (same net effect as Control Center).
enum MacAudioOutputHardware {
    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    /// Sets macOS **system-wide** default output device.
    static func setDefaultOutputDevice(_ deviceID: AudioDeviceID) -> OSStatus {
        var id = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(systemObject, &address, 0, nil, size, &id)
    }

    /// The device's nominal sample rate in Hz, `nil` when it can't be read.
    static func nominalSampleRate(deviceID: AudioDeviceID) -> Float64? {
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        guard status == noErr, rate > 0 else { return nil }
        return rate
    }

    static func copyDeviceDisplayName(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr else { return nil }

        // Core Audio hands over a retained string; take it so it is released.
        var name: Unmanaged<CFString>?
        dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &name)
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    static func enumerateOutputDevices() -> [MacAudioOutputDevice] {
        let ids = allAudioDeviceIDs().filter { outputChannelCount(deviceID: $0) > 0 }
        var rows: [MacAudioOutputDevice] = []
        rows.reserveCapacity(ids.count)
        for id in ids {
            guard let name = copyDeviceDisplayName(deviceID: id), !name.isEmpty else { continue }
            rows.append(MacAudioOutputDevice(id: id, name: name))
        }
        return rows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func allAudioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize) == noErr,
            dataSize > 0
        else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &devices)
        guard status == noErr else { return [] }
        return devices.filter { $0 != AudioObjectID(kAudioObjectUnknown) }
    }

    private static func outputChannelCount(deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var propertySize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propertySize) == noErr,
            propertySize > 0
        else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(propertySize), alignment: 16)
        defer { raw.deallocate() }
        var sz = propertySize
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &sz, raw) == noErr else {
            return 0
        }
        let abl = raw.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
        var channels = 0
        for buffer in buffers {
            channels += Int(buffer.mNumberChannels)
        }
        return channels
    }
}

/// Logs the sound path for the playback log (#590): the system's default output, every output
/// device with its nominal sample rate, and each change to them. A song that plays too fast or
/// cuts out is often two devices on different rates, so the log has to show them.
///
/// Every read of the audio system happens on the trace's own queue (#734): the lines now list
/// every app using audio and the stream format, read on every device start or stop, and the
/// audio system can be slow to answer right while a headset switches profiles. The main thread
/// never waits for it. Everything below `queue` is only touched on it.
final class AudioOutputTrace: @unchecked Sendable {
    static let shared = AudioOutputTrace()

    /// Where lines go (on ``queue``); `nil` writes them to the playback log.
    private let write: ((String) -> Void)?
    private let queue = DispatchQueue(label: "com.isaaclins.spotiglass.audio-trace", qos: .utility)
    private var started = false
    private var lastLine: String?
    private var rateListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    /// Every device, inputs too: a device starting or stopping can be another app taking the
    /// Bluetooth microphone, which drops AirPods to call quality (#734).
    private var runningListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    private var systemListeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []

    init(write: ((String) -> Void)? = nil) {
        self.write = write
    }

    /// Stops listening. The app's trace runs for the app's lifetime; tests stop the ones they start.
    // periphery:ignore
    func stop() {
        queue.sync { stopOnQueue() }
    }

    /// Returns once every line asked for so far is written. For tests.
    // periphery:ignore
    func flush() {
        queue.sync {}
    }

    private func stopOnQueue() {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        for (selector, block) in systemListeners {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(systemObject, &address, queue, block)
        }
        systemListeners = []
        for (id, block) in rateListeners {
            var address = Self.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(id, &address, queue, block)
        }
        rateListeners = [:]
        for (id, block) in runningListeners {
            var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(id, &address, queue, block)
        }
        runningListeners = [:]
        started = false
    }

    /// Starts listening and logs the current path. Later calls do nothing.
    func start() {
        queue.async { self.startOnQueue() }
    }

    private func startOnQueue() {
        guard !started else { return }
        started = true
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        for selector in [
            kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyProcessObjectList,
        ] {
            var address = Self.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed() }
            if AudioObjectAddPropertyListenerBlock(systemObject, &address, queue, block) == noErr {
                systemListeners.append((selector, block))
            }
        }
        changed()
    }

    /// Logs the path now, with `reason` (an equalizer route change), even if it didn't change.
    func log(reason: String) {
        queue.async {
            self.lastLine = nil
            self.report(reason: reason)
        }
    }

    private func changed() {
        listenToRates()
        report(reason: nil)
    }

    private func report(reason: String?) {
        let defaultID = MacAudioOutputHardware.defaultOutputDeviceID()
        let devices = MacAudioOutputHardware.enumerateOutputDevices().map { device in
            Self.describe(device.id, name: device.name)
        }
        let defaultName =
            defaultID.map { id in
                Self.describe(id, name: MacAudioOutputHardware.copyDeviceDisplayName(deviceID: id) ?? "?")
            } ?? "none"
        let format = defaultID.map { Self.format($0) } ?? "no stream"
        let line =
            "default output \(defaultName), stream \(format); outputs: \(devices.joined(separator: ", ")); "
            + Self.microphoneUsers()
        guard line != lastLine else { return }
        lastLine = line
        let entry = reason.map { "\(line) [\($0)]" } ?? line
        if let write {
            write(entry)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { PlaybackTrace.shared.audio(entry) } }
        }
    }

    /// "microphone in use by com.microsoft.teams2 on bluetooth device (73)": an app recording from
    /// a Bluetooth headset switches it to its call profile, so music on it sounds like a phone
    /// call until the app lets go (#734).
    nonisolated static func microphoneUsers() -> String {
        let processes: [AudioObjectID] = objectList(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        var users: [String] = []
        for process in processes {
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var address = Self.address(kAudioProcessPropertyIsRunningInput)
            guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr, running != 0 else {
                continue
            }
            var bundleID: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var bundleAddress = Self.address(kAudioProcessPropertyBundleID)
            let name =
                AudioObjectGetPropertyData(process, &bundleAddress, 0, nil, &bundleSize, &bundleID) == noErr
                ? (bundleID?.takeRetainedValue() as String?) ?? "an app" : "an app"
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = Self.address(kAudioProcessPropertyPID)
            if AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid) != noErr { pid = 0 }
            // Every device the app uses: the input among them is the one it records from. Only
            // the HAL's bookkeeping is read here, never sound (eq-mic-permission-audit.sh).
            let devices: [AudioDeviceID] = objectList(process, kAudioProcessPropertyDevices)
            let on = devices.map { id in
                describe(id, name: MacAudioOutputHardware.copyDeviceDisplayName(deviceID: id) ?? "?")
            }
            users.append(
                "\(name.isEmpty ? "an app" : name) (pid \(pid))"
                    + (on.isEmpty ? "" : " using \(on.joined(separator: ", "))"))
        }
        return users.isEmpty ? "microphone in use by nobody" : "microphone in use by \(users.joined(separator: "; "))"
    }

    /// The stream format a device runs at: "48000 Hz 24-bit int 2 ch". A Bluetooth headset in
    /// call mode shows as 16000 or 24000 Hz, 1 ch.
    nonisolated static func format(_ id: AudioDeviceID) -> String {
        var streamsAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let streams: [AudioStreamID] = objectList(id, &streamsAddress)
        guard let stream = streams.first else { return "(no output stream)" }
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = Self.address(kAudioStreamPropertyPhysicalFormat)
        guard AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &asbd) == noErr else {
            return "(format unknown)"
        }
        let kind = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "float" : "int"
        return "\(Int(asbd.mSampleRate)) Hz \(asbd.mBitsPerChannel)-bit \(kind) \(asbd.mChannelsPerFrame) ch"
    }

    nonisolated private static func objectList<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector)
        -> [T]
    {
        var address = Self.address(selector)
        return objectList(object, &address)
    }

    nonisolated private static func objectList<T>(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress)
        -> [T]
    {
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer) == noErr else { return [] }
        let typed = buffer.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: Int(size) / MemoryLayout<T>.stride))
    }

    /// Follows the nominal sample rate of every output device, so a rate change is logged.
    private func listenToRates() {
        let current = Set(MacAudioOutputHardware.enumerateOutputDevices().map(\.id))
        for (id, block) in rateListeners where !current.contains(id) {
            var address = Self.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(id, &address, queue, block)
            rateListeners[id] = nil
        }
        let all: [AudioDeviceID] = Self.objectList(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        for (id, block) in runningListeners where !all.contains(id) {
            var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(id, &address, queue, block)
            runningListeners[id] = nil
        }
        for id in all where runningListeners[id] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.report(reason: "device \(id) started or stopped")
            }
            var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            if AudioObjectAddPropertyListenerBlock(id, &address, queue, block) == noErr {
                runningListeners[id] = block
            }
        }
        for id in current where rateListeners[id] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.report(reason: "sample rate of \(id) changed")
            }
            var address = Self.address(kAudioDevicePropertyNominalSampleRate)
            if AudioObjectAddPropertyListenerBlock(id, &address, queue, block) == noErr {
                rateListeners[id] = block
            }
        }
    }

    /// "MacBook Pro Speakers (built-in, 91) 48000 Hz". The log gets attached to public issues,
    /// so wireless devices, whose names carry their owner in any language ("AirPods Max von
    /// Isaac"), are named only by their kind.
    nonisolated static func describe(_ id: AudioDeviceID, name: String) -> String {
        "\(publicName(name, transport: transport(id))) (\(transport(id)), \(id)) \(rate(id))"
    }

    nonisolated static func publicName(_ name: String, transport: String) -> String {
        switch transport {
        case "built-in", "usb", "hdmi", "displayport", "virtual", "thunderbolt": name
        default: "\(transport) device"
        }
    }

    /// The device behind a Core Audio UID, described like the others. A Bluetooth UID is the
    /// device's hardware address, so it never goes into the log itself.
    nonisolated static func describe(uid: String) -> String {
        var cfUID = uid as CFString
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = Self.address(kAudioHardwarePropertyTranslateUIDToDevice)
        let status = withUnsafePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                uidPointer,
                &size,
                &id
            )
        }
        guard status == noErr, id != AudioDeviceID(kAudioObjectUnknown) else { return "a device that is gone" }
        return describe(id, name: MacAudioOutputHardware.copyDeviceDisplayName(deviceID: id) ?? "?")
    }

    nonisolated private static func transport(_ id: AudioDeviceID) -> String {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = Self.address(kAudioDevicePropertyTransportType)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return "unknown" }
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        case kAudioDeviceTransportTypeHDMI: return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: return "displayport"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return "aggregate"
        case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
        default: return "other"
        }
    }

    nonisolated private static func rate(_ id: AudioDeviceID) -> String {
        MacAudioOutputHardware.nominalSampleRate(deviceID: id).map { "\(Int($0)) Hz" } ?? "? Hz"
    }

    nonisolated private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
