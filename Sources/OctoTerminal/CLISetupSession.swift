import Foundation
import SwiftUI
import OctoCore
import OctoGhostty

/// A dedicated native terminal for an explicitly requested CLI setup command.
/// It never writes into an existing shell or reads terminal output/credentials.
@MainActor public final class CLISetupSession: ObservableObject, Identifiable {
    public let id = UUID()
    public let state: GhosttySession
    @Published public private(set) var exited = false
    public init(executable: URL, arguments: [String], directory: String) {
        state = GhosttySession(options: .init(directory: directory,
            environment: ["PATH": Executables.searchPath],
            command: Self.command(executable: executable, arguments: arguments)))
        state.onClose = { [weak self] _ in self?.exited = true }
    }
    public static func command(executable: URL, arguments: [String]) -> String {
        ([executable.path] + arguments).map(Executables.shellQuote).joined(separator: " ")
    }
    public func close() { state.close() }
}

public struct CLISetupTerminal: View {
    @ObservedObject var session: CLISetupSession
    public init(session: CLISetupSession) { self.session = session }
    public var body: some View {
        GhosttyTerminalSurface(session: session.state)
            .onAppear { session.state.isSurfaceVisible = true; session.state.requestFocus() }
            .onDisappear { session.close() }
    }
}
