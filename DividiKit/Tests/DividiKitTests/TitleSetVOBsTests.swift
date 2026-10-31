import Foundation
import Testing

@testable import DividiKit

/// Sectors filled with their number in the Title Set, so a read shows where it came from.
private func numberedSectors(_ numbers: Range<Int>) -> Data {
  Data(numbers.flatMap { Array(repeating: UInt8($0), count: Sector.size) })
}

/// Title Set 1 split across two VOB files, plus another Title Set's VOB.
private let source = InMemorySource(files: [
  "VTS_01_1.VOB": numberedSectors(0..<3),
  "VTS_01_2.VOB": numberedSectors(3..<5),
  "VTS_02_1.VOB": numberedSectors(100..<102),
])

@Test func readsSectorsWithinTheFirstVOB() throws {
  let data = try TitleSetVOBs(titleSet: 1, source: source).readSectors(1...2)

  #expect(data == numberedSectors(1..<3))
}

@Test func readsSectorsCrossingIntoTheNextVOB() throws {
  let data = try TitleSetVOBs(titleSet: 1, source: source).readSectors(2...4)

  #expect(data == numberedSectors(2..<5))
}

@Test func readsSectorsWithinALaterVOB() throws {
  let data = try TitleSetVOBs(titleSet: 1, source: source).readSectors(4...4)

  #expect(data == numberedSectors(4..<5))
}

@Test func readsTheTitleSetsOwnVOBs() throws {
  let data = try TitleSetVOBs(titleSet: 2, source: source).readSectors(0...1)

  #expect(data == numberedSectors(100..<102))
}

@Test func readingPastTheLastVOBFails() {
  #expect(throws: InMemorySource.MissingFile.self) {
    try TitleSetVOBs(titleSet: 1, source: source).readSectors(4...5)
  }
}
