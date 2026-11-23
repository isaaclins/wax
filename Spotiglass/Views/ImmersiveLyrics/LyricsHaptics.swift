import AppKit

/// What the trackpad does during a lyrics timing hold (#640).
@MainActor
protocol LyricsHaptics: AnyObject {
    /// The hold started: a firm tap.
    func holdStarted()
    /// A new line moved into the highlight: a tick.
    func lineChanged()
    /// The hold ended and the timing was saved: the firmest tap.
    func saved()
}

/// Plays the hold's taps as strongly as the Force Touch trackpad goes. The standard haptic
/// patterns are faint and have no strength setting, so the trackpad's own actuator is driven
/// directly when it can be; when it can't (no Force Touch trackpad found, or the system no
/// longer offers it) the standard patterns play instead.
@MainActor
final class TrackpadLyricsHaptics: LyricsHaptics {
    static let shared = TrackpadLyricsHaptics()

    /// Actuator strengths: 3 weak, 4 medium, 6 strong.
    enum Strength: Int32 {
        case tick = 3
        case firm = 4
        case strongest = 6
    }

    private let actuators: MultitouchActuators
    private let fallback: NSHapticFeedbackPerformer

    init(
        actuators: MultitouchActuators? = nil,
        fallback: NSHapticFeedbackPerformer = NSHapticFeedbackManager.defaultPerformer
    ) {
        self.actuators = actuators ?? MultitouchActuators()
        self.fallback = fallback
    }

    func holdStarted() { play(.firm, fallback: .levelChange) }
    func lineChanged() { play(.tick, fallback: .alignment) }
    func saved() { play(.strongest, fallback: .levelChange) }

    private func play(_ strength: Strength, fallback pattern: NSHapticFeedbackManager.FeedbackPattern) {
        if actuators.actuate(strength.rawValue) { return }
        fallback.perform(pattern, performanceTime: .now)
    }
}

/// The Force Touch trackpads' actuators, through the system's MultitouchSupport framework. It
/// is loaded at run time, so a system without it (or without its functions) only means the
/// standard haptics play.
@MainActor
final class MultitouchActuators {
    private typealias CreateDeviceList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias GetDeviceID = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
    private typealias CreateActuator = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
    private typealias OpenActuator = @convention(c) (CFTypeRef) -> Int32
    private typealias Actuate = @convention(c) (CFTypeRef, Int32, UInt32, Float, Float) -> Int32

    private struct Functions {
        let createDeviceList: CreateDeviceList
        let getDeviceID: GetDeviceID
        let createActuator: CreateActuator
        let open: OpenActuator
        let actuate: Actuate
    }

    static let frameworkPath = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    private let functions: Functions?
    private var actuators: [CFTypeRef] = []

    init(frameworkPath: String = MultitouchActuators.frameworkPath) {
        functions = Self.load(frameworkPath)
    }

    /// Plays one tap on every Force Touch trackpad; false when none took it.
    func actuate(_ actuationID: Int32) -> Bool {
        guard let functions else { return false }
        if actuators.isEmpty {
            // A trackpad connected later is found on the next tap.
            actuators = Self.openActuators(functions)
        }
        var played = false
        for actuator in actuators where functions.actuate(actuator, actuationID, 0, 1.0, 2.0) == 0 {
            played = true
        }
        return played
    }

    private static func load(_ path: String) -> Functions? {
        guard let handle = dlopen(path, RTLD_LAZY) else { return nil }
        guard let createDeviceList = dlsym(handle, "MTDeviceCreateList"),
              let getDeviceID = dlsym(handle, "MTDeviceGetDeviceID"),
              let createActuator = dlsym(handle, "MTActuatorCreateFromDeviceID"),
              let open = dlsym(handle, "MTActuatorOpen"),
              let actuate = dlsym(handle, "MTActuatorActuate")
        else { return nil }
        return Functions(
            createDeviceList: unsafeBitCast(createDeviceList, to: CreateDeviceList.self),
            getDeviceID: unsafeBitCast(getDeviceID, to: GetDeviceID.self),
            createActuator: unsafeBitCast(createActuator, to: CreateActuator.self),
            open: unsafeBitCast(open, to: OpenActuator.self),
            actuate: unsafeBitCast(actuate, to: Actuate.self)
        )
    }

    private static func openActuators(_ functions: Functions) -> [CFTypeRef] {
        guard let devices = functions.createDeviceList()?.takeRetainedValue() else { return [] }
        var opened: [CFTypeRef] = []
        for index in 0..<CFArrayGetCount(devices) {
            guard let device = CFArrayGetValueAtIndex(devices, index) else { continue }
            var deviceID: UInt64 = 0
            guard functions.getDeviceID(device, &deviceID) == 0,
                  let actuator = functions.createActuator(deviceID)?.takeRetainedValue(),
                  functions.open(actuator) == 0
            else { continue }
            opened.append(actuator)
        }
        return opened
    }
}
