// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// The server→provider progress leg (#47): the `upload-progress` frame, and the state machine
/// that folds it together with the device leg `URLSession` reports.
///
/// The bug this feature exists to kill is a readout that says "Uploading… 100%" and then sits
/// there through the two slowest phases of the upload. Most of what's locked here is the ways
/// that lie can come back: a stage that rewinds, a percentage claimed where none was reported,
/// a missing key read as a zero.
final class UploadProgressTests: XCTestCase {

    // MARK: - The wire

    func testProcessingFrameParses() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"upload-progress","token":"abc","phase":"processing","destination":"Catbox","percent":null}"##
        )
        XCTAssertEqual(
            frame,
            .uploadProgress(
                token: "abc",
                progress: UploadServerProgress(phase: .processing, percent: nil, destination: "Catbox")
            )
        )
    }

    func testSendingFrameCarriesItsPercent() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"upload-progress","token":"abc","phase":"sending","destination":"Catbox","percent":42}"##
        )
        XCTAssertEqual(
            frame,
            .uploadProgress(
                token: "abc",
                progress: UploadServerProgress(phase: .sending, percent: 42, destination: "Catbox")
            )
        )
    }

    func testAbsentPercentIsNilRatherThanZero() {
        // ⚠ The whole point of the nullable percent. Read as 0, a driver that never counts a
        // byte (`local` renames a temp file — there is no wire) would freeze the readout at
        // "Sending… 0%" for the entire send: the same dead air one phase along.
        let frame = FrameParser.parseWs(
            ##"{"kind":"upload-progress","token":"abc","phase":"sending","destination":"Local disk"}"##
        )
        XCTAssertEqual(
            frame,
            .uploadProgress(
                token: "abc",
                progress: UploadServerProgress(phase: .sending, percent: nil, destination: "Local disk")
            )
        )
    }

    func testFrameWithoutATokenIsIgnored() {
        // Unmatchable: the token is the only thing tying a frame to the upload it describes,
        // and these fan out to every socket the account has open.
        XCTAssertEqual(
            FrameParser.parseWs(##"{"kind":"upload-progress","phase":"sending","percent":10}"##),
            .ignored
        )
    }

    func testUnknownPhaseIsIgnored() {
        // A phase this build has no rendering for. Falling back to the indeterminate readout
        // already on screen beats acting on a payload we can't read.
        XCTAssertEqual(
            FrameParser.parseWs(##"{"kind":"upload-progress","token":"abc","phase":"finalising"}"##),
            .ignored
        )
    }

    func testDestinationIsOptional() {
        let frame = FrameParser.parseWs(
            ##"{"kind":"upload-progress","token":"abc","phase":"processing","destination":null,"percent":null}"##
        )
        XCTAssertEqual(
            frame,
            .uploadProgress(
                token: "abc",
                progress: UploadServerProgress(phase: .processing, percent: nil, destination: nil)
            )
        )
    }

    // MARK: - Folding the two legs

    func testStartsOnTheDeviceLeg() {
        let progress = UploadProgress()
        XCTAssertEqual(progress.stage, .uploading)
        XCTAssertEqual(progress.deviceFraction, 0)
        XCTAssertNil(progress.sentFraction)
        XCTAssertNil(progress.destination)
    }

    func testDeviceLegReportsItsFraction() {
        var progress = UploadProgress()
        progress.apply(deviceFraction: 0.42)
        XCTAssertEqual(progress.stage, .uploading)
        XCTAssertEqual(progress.deviceFraction, 0.42, accuracy: 0.0001)
    }

    func testDeviceLegHittingOneAdvancesWithoutAnyServerFrame() {
        // Tier 1, and the whole reason this isn't gated on the server: an instance too old to
        // send these frames — or a socket that dropped mid-upload — still stops claiming to be
        // uploading the moment the last byte leaves the device.
        var progress = UploadProgress()
        progress.apply(deviceFraction: 1)
        XCTAssertEqual(progress.stage, .processing)
    }

    func testALateDeviceTickCannotRewindTheStage() {
        // Those callbacks hop threads to reach the main actor, so one can land after the
        // server's first frame. Letting it through would put "Uploading…" back on screen after
        // the readout had already moved on.
        var progress = UploadProgress()
        progress.apply(server: UploadServerProgress(phase: .sending, percent: 30, destination: "Catbox"))
        progress.apply(deviceFraction: 0.99)
        XCTAssertEqual(progress.stage, .sending)
        XCTAssertEqual(progress.sentFraction, 0.3)
    }

    func testARestartedBodyReturnsToTheDeviceLeg() {
        // `URLSession` can re-send the whole body (an HTTP/2 GOAWAY retry, a redirect), which
        // resets its byte count to zero. Latching on "Processing…" would sit there through the
        // entire second transmission — minutes, for a large video — and no server frame could
        // correct it, because the server hasn't got the file yet.
        var progress = UploadProgress()
        progress.apply(deviceFraction: 1)
        XCTAssertEqual(progress.stage, .processing)
        progress.apply(deviceFraction: 0.02)
        XCTAssertEqual(progress.stage, .uploading)
        XCTAssertEqual(progress.deviceFraction, 0.02, accuracy: 0.0001)
    }

    func testARepeatedFinalTickIsNotMistakenForARestart() {
        // Only a fraction that goes BACKWARDS is a restart. A duplicate 100% is just a tick.
        var progress = UploadProgress()
        progress.apply(deviceFraction: 1)
        progress.apply(deviceFraction: 1)
        XCTAssertEqual(progress.stage, .processing)
    }

    func testTheDeviceLegCannotReopenOnceTheServerHasSpoken() {
        // Past this point the server's account beats the device's: the bytes are there, so a
        // low tick is a straggler crossing the WS, not a restart. This is the guard that keeps
        // the re-entry above from reintroducing the rewind it's carved out of.
        var progress = UploadProgress()
        progress.apply(deviceFraction: 1)
        progress.apply(server: UploadServerProgress(phase: .processing, percent: nil, destination: "Catbox"))
        progress.apply(deviceFraction: 0.02)
        XCTAssertEqual(progress.stage, .processing)
    }

    func testSendingCarriesItsFraction() {
        var progress = UploadProgress()
        progress.apply(server: UploadServerProgress(phase: .sending, percent: 75, destination: "Catbox"))
        XCTAssertEqual(progress.stage, .sending)
        XCTAssertEqual(progress.sentFraction, 0.75)
        XCTAssertEqual(progress.destination, "Catbox")
    }

    func testSendingWithoutAPercentStaysIndeterminate() {
        var progress = UploadProgress()
        progress.apply(server: UploadServerProgress(phase: .sending, percent: nil, destination: "Local disk"))
        XCTAssertEqual(progress.stage, .sending)
        XCTAssertNil(progress.sentFraction)
    }

    func testProcessingNeverCarriesANumber() {
        // Only `sending` has one. The pipeline is a native one-shot with no seam to count, so
        // a percentage on this stage could only ever be a number borrowed from another phase.
        var progress = UploadProgress()
        progress.apply(server: UploadServerProgress(phase: .processing, percent: 50, destination: nil))
        XCTAssertEqual(progress.stage, .processing)
        XCTAssertNil(progress.sentFraction)
    }

    func testALateProcessingFrameCannotRewindTheSend() {
        // WS ordering makes this unlikely, not impossible, and the cost of being wrong is a
        // real percentage replaced by an indeterminate label — visibly a jump backwards.
        var progress = UploadProgress()
        progress.apply(server: UploadServerProgress(phase: .sending, percent: 60, destination: "Catbox"))
        progress.apply(server: UploadServerProgress(phase: .processing, percent: nil, destination: "Catbox"))
        XCTAssertEqual(progress.stage, .sending)
        XCTAssertEqual(progress.sentFraction, 0.6)
    }

    func testDestinationSticksOnceNamed() {
        // A later frame that omits it must not blank a label already on screen.
        var progress = UploadProgress()
        progress.apply(server: UploadServerProgress(phase: .sending, percent: 10, destination: "Catbox"))
        progress.apply(server: UploadServerProgress(phase: .sending, percent: 20, destination: nil))
        XCTAssertEqual(progress.destination, "Catbox")
        XCTAssertEqual(progress.sentFraction, 0.2)
    }

    func testFractionsAreClamped() {
        var progress = UploadProgress()
        progress.apply(deviceFraction: -0.5)
        XCTAssertEqual(progress.deviceFraction, 0)
        progress.apply(server: UploadServerProgress(phase: .sending, percent: 140, destination: nil))
        XCTAssertEqual(progress.sentFraction, 1)
    }

    func testTheWholeHappyPathInOrder() {
        var progress = UploadProgress()
        progress.apply(deviceFraction: 0.5)
        XCTAssertEqual(progress.stage, .uploading)
        progress.apply(deviceFraction: 1)
        XCTAssertEqual(progress.stage, .processing)
        progress.apply(server: UploadServerProgress(phase: .processing, percent: nil, destination: "Catbox"))
        XCTAssertEqual(progress.stage, .processing)
        XCTAssertEqual(progress.destination, "Catbox")
        progress.apply(server: UploadServerProgress(phase: .sending, percent: 0, destination: "Catbox"))
        XCTAssertEqual(progress.sentFraction, 0)
        progress.apply(server: UploadServerProgress(phase: .sending, percent: 100, destination: "Catbox"))
        XCTAssertEqual(progress.stage, .sending)
        XCTAssertEqual(progress.sentFraction, 1)
    }
}
