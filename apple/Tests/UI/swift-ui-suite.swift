import Foundation
import Testing

@main struct SwiftUISuite {
    @MainActor static func main() async throws {
        var arguments = Testing.__CommandLineArguments_v0()
        arguments.parallel = false
        let result: CInt = await Testing.__swiftPMEntryPoint(passing: arguments)
        guard result == 0 else { throw SuiteFailure.testsFailed }
    }
    enum SuiteFailure: Error { case testsFailed }
}
