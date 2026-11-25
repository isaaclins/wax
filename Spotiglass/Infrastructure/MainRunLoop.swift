import Foundation

enum MainRunLoop {
    /// Runs `work` once the frame this pass of the main run loop is building has been committed.
    /// `DispatchQueue.main.async` isn't enough: the run loop drains the main queue before it
    /// commits the frame, so the work still lands in it. A timer fires only after the run loop
    /// has committed and gone to wait. For work that doesn't change what this frame shows but
    /// costs a render of its own, like the menu bar's titles (#672).
    static func afterThisFrame(_ work: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { work() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}
