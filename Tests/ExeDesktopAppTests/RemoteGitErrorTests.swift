import XCTest
@testable import ExeDesktopApp

/// Condensing ssh's stderr into the one line shown in the sidebar banner.
final class RemoteGitErrorTests: XCTestCase {

    /// ssh prints this on nearly every first connection; it is never the reason
    /// a command failed, so it must not be what the user is shown.
    func testIgnoresTheHostKeyWarning() {
        let stderr = """
        Warning: Permanently added 'vm.exe.xyz' (ED25519) to the list of known hosts.
        Permission denied (publickey).
        """
        XCTAssertEqual(SSHTransport.summarize(stderr: stderr, exitCode: 255),
                       "Permission denied (publickey).")
    }

    /// The informative line is picked out of surrounding noise rather than
    /// taking the first line blindly.
    func testPicksTheNotableLineOutOfNoise() {
        let stderr = """
        Warning: Permanently added 'vm.exe.xyz' (ED25519) to the list of known hosts.
        motd: welcome to the machine
        ssh: connect to host vm.exe.xyz port 22: Connection refused
        """
        XCTAssertTrue(SSHTransport.summarize(stderr: stderr, exitCode: 255)
            .contains("Connection refused"))
    }

    func testRecognisesCommonSSHFailures() {
        let cases = [
            "ssh: Could not resolve hostname gone.exe.xyz: Name or service not known",
            "ssh: connect to host x port 22: Connection timed out",
            "Host key verification failed.",
            "ssh: connect to host x port 22: No route to host",
        ]
        for stderr in cases {
            XCTAssertEqual(SSHTransport.summarize(stderr: stderr, exitCode: 255), stderr,
                           "should surface: \(stderr)")
        }
    }

    /// A command can fail with nothing on stderr; the status is better than a
    /// blank banner.
    func testFallsBackToTheExitStatusWhenStderrIsEmpty() {
        XCTAssertEqual(SSHTransport.summarize(stderr: "", exitCode: 255),
                       "ssh exited with status 255")
        XCTAssertEqual(SSHTransport.summarize(stderr: "   \n\n", exitCode: 1),
                       "ssh exited with status 1")
    }

    /// Unrecognised failures still say something specific rather than falling
    /// through to the generic status.
    func testUsesTheLastLineForUnrecognisedErrors() {
        let stderr = "some preamble\nbash: git: command not found"
        XCTAssertEqual(SSHTransport.summarize(stderr: stderr, exitCode: 127),
                       "bash: git: command not found")
    }

    /// Remote programs emit bare carriage returns; leaving them in would put
    /// line breaks inside a banner meant to be one line.
    func testTreatsCarriageReturnsAsLineBreaks() {
        let summary = SSHTransport.summarize(stderr: "first\rPermission denied (publickey).\r",
                                          exitCode: 255)
        XCTAssertEqual(summary, "Permission denied (publickey).")
        XCTAssertFalse(summary.contains("\r"))
    }

    /// The summary is held in published state and re-compared every poll, so a
    /// pathological line must not be kept whole.
    func testCapsAnAbsurdlyLongLine() {
        let summary = SSHTransport.summarize(stderr: String(repeating: "x", count: 100_000),
                                          exitCode: 1)
        XCTAssertLessThanOrEqual(summary.count, 301)
        XCTAssertTrue(summary.hasSuffix("…"))
    }

    /// Only the host-key warning is filtered; a warning that *is* the failure
    /// must still come through.
    func testDoesNotSwallowEverythingWhenOnlyWarningsArePresent() {
        let stderr = "Warning: Permanently added 'x' (ED25519) to the list of known hosts."
        XCTAssertEqual(SSHTransport.summarize(stderr: stderr, exitCode: 255),
                       "ssh exited with status 255")
    }
}
