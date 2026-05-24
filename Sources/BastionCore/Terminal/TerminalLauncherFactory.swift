import Foundation

/// Maps a TerminalID to its concrete TerminalLauncher implementation.
/// Used by the menu app's Coordinator + the CLI to abstract terminal
/// selection over the per-terminal launcher implementations.
public struct TerminalLauncherFactory: Sendable {
    public let recorder: TerminalLaunchRecorder?
    public init(recorder: TerminalLaunchRecorder? = nil) { self.recorder = recorder }

    public func launcher(for id: TerminalID) -> TerminalLauncher {
        switch id {
        case .terminal:  return TerminalAppLauncher(recorder: recorder)
        case .iterm2:    return ITerm2Launcher(recorder: recorder)
        case .ghostty:   return GhosttyLauncher(recorder: recorder)
        case .alacritty: return AlacrittyLauncher(recorder: recorder)
        case .kitty:     return KittyLauncher(recorder: recorder)
        case .wezterm:   return WezTermLauncher(recorder: recorder)
        case .warp:      return WarpLauncher(recorder: recorder)
        case .hyper:     return HyperLauncher(recorder: recorder)
        case .tabby:     return TabbyLauncher(recorder: recorder)
        case .rio:       return RioLauncher(recorder: recorder)
        }
    }
}
