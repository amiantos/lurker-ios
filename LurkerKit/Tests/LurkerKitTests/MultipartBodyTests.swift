// Copyright (c) 2026 Brad Root
// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import LurkerKit

/// Locks the upload body to the server's multipart contract: the `progressToken` field
/// streams BEFORE the file (the server reads it as fields flow past a possibly-huge body),
/// the file field is named `image`, and a filename can never break out of its header.
final class MultipartBodyTests: XCTestCase {

    private func makeSourceFile(_ contents: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mpbody-src-\(UUID().uuidString).bin")
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testProgressTokenPrecedesTheImageField() throws {
        let source = try makeSourceFile("PAYLOADBYTES")
        defer { try? FileManager.default.removeItem(at: source) }

        let body = try MultipartBody.assemble(
            token: "tok-123", fileURL: source, filename: "clip.mov", mime: "video/mp4"
        )
        defer { try? FileManager.default.removeItem(at: body.fileURL) }

        let text = try String(contentsOf: body.fileURL, encoding: .utf8)
        let tokenRange = try XCTUnwrap(text.range(of: "name=\"progressToken\""))
        let imageRange = try XCTUnwrap(text.range(of: "name=\"image\""))
        XCTAssertLessThan(
            tokenRange.lowerBound, imageRange.lowerBound,
            "progressToken must stream before the file body"
        )
        XCTAssertTrue(text.contains("tok-123"))
        XCTAssertTrue(text.contains("PAYLOADBYTES"), "the source bytes are embedded verbatim")
        XCTAssertTrue(text.contains("Content-Type: video/mp4"))
        XCTAssertTrue(text.contains("filename=\"clip.mov\""))
    }

    func testContentTypeHeaderCarriesTheBoundaryThatClosesTheBody() throws {
        let source = try makeSourceFile("x")
        defer { try? FileManager.default.removeItem(at: source) }

        let body = try MultipartBody.assemble(
            token: "t", fileURL: source, filename: "a.jpg", mime: "image/jpeg"
        )
        defer { try? FileManager.default.removeItem(at: body.fileURL) }

        let boundary = try XCTUnwrap(
            body.contentType.range(of: "boundary=").map { String(body.contentType[$0.upperBound...]) }
        )
        let text = try String(contentsOf: body.fileURL, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("--\(boundary)\r\n"), "opens with the announced boundary")
        XCTAssertTrue(text.hasSuffix("--\(boundary)--\r\n"), "closes with the terminating boundary")
    }

    func testSanitizeFilenameStripsQuotesControlCharsAndDefaultsWhenEmpty() {
        XCTAssertEqual(MultipartBody.sanitizeFilename("na\"me\r\n.mov"), "name.mov")
        XCTAssertEqual(MultipartBody.sanitizeFilename("   "), "upload")
        XCTAssertEqual(MultipartBody.sanitizeFilename(""), "upload")
        XCTAssertEqual(MultipartBody.sanitizeFilename("photo.heic"), "photo.heic")
    }

    func testSanitizedFilenameIsWhatLandsInTheHeader() throws {
        let source = try makeSourceFile("y")
        defer { try? FileManager.default.removeItem(at: source) }

        let body = try MultipartBody.assemble(
            token: "t", fileURL: source, filename: "ev\"il\n.png", mime: "image/png"
        )
        defer { try? FileManager.default.removeItem(at: body.fileURL) }

        let text = try String(contentsOf: body.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("filename=\"evil.png\""))
        XCTAssertFalse(text.contains("ev\"il"), "an unescaped quote would break the header")
    }
}
