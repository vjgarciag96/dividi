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
  var vobs = TitleSetVOBs(titleSet: 1, source: source)

  let data = try vobs.readSectors(1...2)

  #expect(data == numberedSectors(1..<3))
}

@Test func readsSectorsEndingOnTheLastSectorOfAVOB() throws {
  var vobs = TitleSetVOBs(titleSet: 1, source: source)

  let data = try vobs.readSectors(0...2)

  #expect(data == numberedSectors(0..<3))
}

@Test func readsSectorsCrossingIntoTheNextVOB() throws {
  var vobs = TitleSetVOBs(titleSet: 1, source: source)

  let data = try vobs.readSectors(2...4)

  #expect(data == numberedSectors(2..<5))
}

@Test func readsTheLastSectorOfOneVOBAndTheFirstOfTheNext() throws {
  var vobs = TitleSetVOBs(titleSet: 1, source: source)

  let data = try vobs.readSectors(2...3)

  #expect(data == numberedSectors(2..<4))
}

@Test func readsSectorsStartingAtTheFirstSectorOfTheNextVOB() throws {
  var vobs = TitleSetVOBs(titleSet: 1, source: source)

  let data = try vobs.readSectors(3...4)

  #expect(data == numberedSectors(3..<5))
}

@Test func readsSectorsWithinALaterVOB() throws {
  var vobs = TitleSetVOBs(titleSet: 1, source: source)

  let data = try vobs.readSectors(4...4)

  #expect(data == numberedSectors(4..<5))
}

@Test func readsTheTitleSetsOwnVOBs() throws {
  var vobs = TitleSetVOBs(titleSet: 2, source: source)

  let data = try vobs.readSectors(0...1)

  #expect(data == numberedSectors(100..<102))
}

@Test func readsAcrossAnEmptyVOBBetweenTwoOthers() throws {
  let source = InMemorySource(files: [
    "VTS_01_1.VOB": numberedSectors(0..<2),
    "VTS_01_2.VOB": Data(),
    "VTS_01_3.VOB": numberedSectors(2..<4),
  ])
  var vobs = TitleSetVOBs(titleSet: 1, source: source)

  let data = try vobs.readSectors(1...2)

  #expect(data == numberedSectors(1..<3))
}

@Test func readingPastTheLastVOBFails() {
  var vobs = TitleSetVOBs(titleSet: 1, source: source)

  #expect(throws: FolderSource.ReadError.fileNotFound("VTS_01_3.VOB")) {
    try vobs.readSectors(4...5)
  }
}

@Test func measuresEachVOBOnceAcrossReads() throws {
  let counting = CountingSource(source)
  var vobs = TitleSetVOBs(titleSet: 1, source: counting)

  _ = try vobs.readSectors(0...0)
  _ = try vobs.readSectors(3...4)
  _ = try vobs.readSectors(1...3)

  #expect(counting.sectorCountCalls == 2, "each of the 2 VOBs should be measured once")
}
