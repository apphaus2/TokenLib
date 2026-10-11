import XCTest
@testable import TokenLib

final class TransportTests: XCTestCase {
    func testLineSplitterHoldsPartialLines() {
        var s = LineSplitter()
        XCTAssertEqual(s.append(Data("ab\ncd".utf8)), ["ab"])
        XCTAssertEqual(s.append(Data("e\r\n\nf".utf8)), ["cde", ""])
        XCTAssertEqual(s.flush(), "f")
        XCTAssertNil(s.flush())
    }

    func testSSEParser() {
        var p = SSEParser()
        XCTAssertNil(p.feed("event: ping"))
        XCTAssertNil(p.feed(": comment"))
        XCTAssertNil(p.feed("data: {\"a\":1}"))
        XCTAssertNil(p.feed("data: more"))
        XCTAssertEqual(p.feed(""), SSEParser.Event(name: "ping", data: "{\"a\":1}\nmore"))
        XCTAssertNil(p.feed(""), "blank lines without data are ignored")
        XCTAssertNil(p.feed("data:no-space"))
        XCTAssertEqual(p.feed("")?.data, "no-space")
    }
}
