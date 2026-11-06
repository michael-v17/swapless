import Darwin
import SwaplessCore

/// The only `kill(SIGTERM)` in Swapless (§ J). It lives in the app target so SwaplessCore, the
/// tests and swapless-rig can't construct it. Never SIGKILL.
final class LiveSignalSender: SignalSender, @unchecked Sendable {
    #if DEBUG
    /// A DEBUG build can never signal the real wallpaper.
    static let refuseWallpaper = true
    #else
    static let refuseWallpaper = false
    #endif

    private let sink: EventSink

    init(sink: EventSink) { self.sink = sink }

    func sigterm(pid: Int32, target: RestartTarget) -> SignalResult {
        if let refusal = SignalGuard.refusal(pid: pid, target: target, ownPid: getpid(),
                                             refuseWallpaper: Self.refuseWallpaper) {
            sink.error(where: "signal", refusal, category: .actions)
            return .refused(refusal)
        }
        if kill(pid, SIGTERM) == 0 { return .sent }
        let e = errno
        return e == ESRCH ? .alreadyGone : .failed(e)
    }
}
