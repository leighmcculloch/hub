import XCTest
@testable import ExeDesktopApp

/// Reading a VM's own name back off it, which is how the app notices a VM that
/// renamed itself. exe.dev's reflection endpoint publishes the name; these cover
/// the parsing and the destination derivation on `ExeProvider`.
final class ExeProviderReflectionTests: XCTestCase {

    private let provider = ExeProvider()

    /// Shape confirmed against the live reflection integration: the name sits
    /// at the top level, alongside the paths the integration offers.
    func testNameIsReadFromTheReflectionIndex() {
        let output = """
        {"name":"fix-login-redirect","emoji":"🚀","paths":[{"path":"/email"}]}
        """
        XCTAssertEqual(provider.parseReflectedName(output), "fix-login-redirect")
    }

    /// curl's output is whatever the VM said; anything unexpected has to mean
    /// "don't know", not a rename to nonsense.
    func testUnusableOutputYieldsNoName() {
        XCTAssertNil(provider.parseReflectedName(""))
        XCTAssertNil(provider.parseReflectedName("curl: (6) Could not resolve host"))
        XCTAssertNil(provider.parseReflectedName("{}"))
        XCTAssertNil(provider.parseReflectedName(#"{"name":""}"#))
        XCTAssertNil(provider.parseReflectedName(#"{"name":42}"#))
        XCTAssertNil(provider.parseReflectedName("[]"))
    }

    func testDestinationFollowsTheName() {
        XCTAssertEqual(provider.destination(forVMName: "fix-login-redirect"),
                       "fix-login-redirect.exe.xyz")
    }

    /// The command has to fail rather than hang when the VM can't answer: each
    /// poll otherwise leaves an ssh waiting on a curl that never returns.
    func testTheNameCommandCannotHang() {
        guard let command = provider.reflectionNameCommand else {
            return XCTFail("ExeProvider should expose a reflection command")
        }
        XCTAssertTrue(command.contains("--max-time"))
        XCTAssertTrue(command.contains("-fsS"))
    }
}
