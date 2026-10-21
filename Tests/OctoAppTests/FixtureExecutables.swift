import Foundation
import OctoAgents
@testable import OctoApp

/// CI runners have no provider CLIs. Fixtures that send through a fake harness
/// must not depend on what happens to be installed on the host.
@MainActor func fixtureExecutables() -> (descriptors: [HarnessDescriptor], codex: URL?) {
    let executable = URL(fileURLWithPath: "/usr/bin/true")
    return (HarnessRegistry.descriptors.map { var descriptor = $0; descriptor.executable = executable; return descriptor }, executable)
}
