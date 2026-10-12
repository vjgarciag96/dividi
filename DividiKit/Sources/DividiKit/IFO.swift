import Foundation

// Format-level views of the IFO files, as laid out by the DVD-Video specification.
// Byte offsets are named after the fields they point to; sizes are in the comments.

/// Fields at the same place in every IFO header.
enum IFOHeader {
  /// The last Sector of the IFO itself (u32).
  static let lastSector = 0x1C
}

/// `VIDEO_TS.IFO`: the Disc's title table.
struct VideoManagerIFO {
  struct TitleEntry {
    let titleSet: Int
    let titleInSet: Int
  }

  private enum Header {
    /// The number of Title Sets on the Disc (u16).
    static let titleSetCount = 0x3E
    /// The Sector where the title table starts (u32).
    static let titleTableSector = 0xC4
  }

  /// The title table (`TT_SRPT`): the number of Titles (u16), then one 12-byte entry per Title.
  private enum TitleTable {
    static let firstEntry = 8
    static let entrySize = 12
    /// Within an entry: the Title Set holding the Title (u8).
    static let titleSet = 6
    /// Within an entry: the Title's number within its Title Set (u8).
    static let titleInSet = 7
  }

  let titleSetCount: Int
  let titles: [TitleEntry]

  init(_ data: Data) throws(DiscError.Reason) {
    let ifo = ByteReader(data)
    guard try ifo.bytes(at: 0, count: 12) == Array("DVDVIDEO-VMG".utf8) else { throw .notAnIFO }
    titleSetCount = try ifo.u16(at: Header.titleSetCount)

    let table = try ifo.u32(at: Header.titleTableSector) * Sector.size
    var titles: [TitleEntry] = []
    // The table starts with its Title count (u16).
    for index in 0..<(try ifo.u16(at: table)) {
      let entry = table + TitleTable.firstEntry + TitleTable.entrySize * index
      titles.append(
        TitleEntry(
          titleSet: try ifo.u8(at: entry + TitleTable.titleSet),
          titleInSet: try ifo.u8(at: entry + TitleTable.titleInSet)))
    }
    self.titles = titles
  }
}

/// `VTS_xx_0.IFO`: a Title Set's Chapters and program chains.
struct TitleSetIFO {
  /// A Chapter's entry point: a program within a program chain, both 1-based.
  struct ChapterEntry {
    let programChain: Int
    let program: Int
  }

  /// For each Title in the set, its Chapters' entry points.
  let chapters: [[ChapterEntry]]
  let programChains: [ProgramChain]

  init(_ data: Data) throws(DiscError.Reason) {
    let ifo = ByteReader(data)
    guard try ifo.bytes(at: 0, count: 12) == Array("DVDVIDEO-VTS".utf8) else { throw .notAnIFO }

    let chapterTable = try ifo.u32(at: 0xC8) * Sector.size
    let titleCount = try ifo.u16(at: chapterTable)
    let chapterTableEnd = chapterTable + (try ifo.u32(at: chapterTable + 4)) + 1
    var listStarts: [Int] = []
    for index in 0..<titleCount {
      listStarts.append(chapterTable + (try ifo.u32(at: chapterTable + 8 + 4 * index)))
    }
    var chapters: [[ChapterEntry]] = []
    for (start, end) in zip(listStarts, listStarts.dropFirst() + [chapterTableEnd]) {
      var list: [ChapterEntry] = []
      for entry in stride(from: start, to: end, by: 4) {
        list.append(
          ChapterEntry(programChain: try ifo.u16(at: entry), program: try ifo.u16(at: entry + 2)))
      }
      chapters.append(list)
    }
    self.chapters = chapters

    let chainTable = try ifo.u32(at: 0xCC) * Sector.size
    var programChains: [ProgramChain] = []
    for index in 0..<(try ifo.u16(at: chainTable)) {
      let chain = chainTable + (try ifo.u32(at: chainTable + 8 + 8 * index + 4))
      programChains.append(try ProgramChain(ifo, at: chain))
    }
    self.programChains = programChains
  }
}

/// A sequence of Cells played in order, split into programs (Chapter entry points).
struct ProgramChain {
  struct CellPlayback {
    let sectors: ClosedRange<Int>
    let playbackTime: Duration
  }

  let playbackTime: Duration
  /// The 1-based entry Cell of each program.
  let programs: [Int]
  let cells: [CellPlayback]

  init(_ ifo: ByteReader, at start: Int) throws(DiscError.Reason) {
    let programCount = try ifo.u8(at: start + 2)
    let cellCount = try ifo.u8(at: start + 3)
    playbackTime = try ifo.playbackTime(at: start + 4)

    let programMap = start + (try ifo.u16(at: start + 0xE6))
    programs = try (0..<programCount).map { (index) throws(DiscError.Reason) in
      try ifo.u8(at: programMap + index)
    }

    let cellTable = start + (try ifo.u16(at: start + 0xE8))
    cells = try (0..<cellCount).map { (index) throws(DiscError.Reason) in
      let cell = cellTable + 24 * index
      return CellPlayback(
        sectors: try ifo.u32(at: cell + 8)...(try ifo.u32(at: cell + 20)),
        playbackTime: try ifo.playbackTime(at: cell + 4))
    }
  }
}
