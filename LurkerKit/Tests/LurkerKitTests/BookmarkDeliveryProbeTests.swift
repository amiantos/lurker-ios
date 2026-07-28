import XCTest
@testable import LurkerKit

/// The swipe's honesty depends on `setBookmark` reporting false when there is no socket.
/// Asserted directly, because everything above it is written on the assumption that a
/// dropped verb is distinguishable from a delivered one.
@MainActor
final class BookmarkDeliveryProbeTests: XCTestCase {
    func testSetBookmarkReportsFailureWithNoSocket() {
        let client = LurkerClient(onFrame: { _ in })
        XCTAssertFalse(
            client.setBookmark(messageId: 1, saved: false),
            "no socket == nothing was sent; the Bookmarks swipe relies on this to keep the row"
        )
    }
}
