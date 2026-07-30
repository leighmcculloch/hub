import XCTest
@testable import ExeDesktopApp

/// Reading a VM's own name back off it, which is how the app notices a VM that
/// renamed itself.
final class RemoteVMTests: XCTestCase {

    /// Shape confirmed against the live reflection integration: the name sits
    /// at the top level, alongside the paths the integration offers.
    func testNameIsReadFromTheReflectionIndex() {
        let output = """
        {"name":"fix-login-redirect","emoji":"🚀","paths":[{"path":"/email"}]}
        """
        XCTAssertEqual(RemoteVM.parseName(output), "fix-login-redirect")
    }

    /// curl's output is whatever the VM said; anything unexpected has to mean
    /// "don't know", not a rename to nonsense.
    func testUnusableOutputYieldsNoName() {
        XCTAssertNil(RemoteVM.parseName(""))
        XCTAssertNil(RemoteVM.parseName("curl: (6) Could not resolve host"))
        XCTAssertNil(RemoteVM.parseName("{}"))
        XCTAssertNil(RemoteVM.parseName(#"{"name":""}"#))
        XCTAssertNil(RemoteVM.parseName(#"{"name":42}"#))
        XCTAssertNil(RemoteVM.parseName("[]"))
    }

    func testDestinationFollowsTheName() {
        XCTAssertEqual(RemoteVM.destination(forName: "fix-login-redirect"),
                       "fix-login-redirect.exe.xyz")
    }

    /// The command has to fail rather than hang when the VM can't answer: each
    /// poll otherwise leaves an ssh waiting on a curl that never returns.
    func testTheNameCommandCannotHang() {
        XCTAssertTrue(RemoteVM.nameCommand.contains("--max-time"))
        XCTAssertTrue(RemoteVM.nameCommand.contains("-fsS"))
    }
}
