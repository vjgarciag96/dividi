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

  private enum Header {
    /// The Sector where the Chapter table starts (u32).
    static let chapterTableSector = 0xC8
    /// The Sector where the program chain table starts (u32).
    static let programChainTableSector = 0xCC
  }

  /// The Chapter table (`VTS_PTT_SRPT`): the number of Titles (u16), then each Title's offset
  /// to its list of 4-byte Chapter entries. Each list runs until the next one, the last until
  /// the table's end. An entry is a program chain (u16) and a program within it (u16).
  private enum ChapterTable {
    /// The table's last byte, relative to its start (u32).
    static let lastByte = 4
    /// Each Title's list offset, relative to the table's start (u32 each).
    static let listOffsets = 8
    static let entrySize = 4
    /// Within an entry: the program, after the program chain (u16).
    static let program = 2
  }

  /// The program chain table (`VTS_PGCI`): the number of program chains (u16), then one
  /// 8-byte entry per program chain.
  private enum ProgramChainTable {
    static let firstEntry = 8
    static let entrySize = 8
    /// Within an entry: the chain's offset, relative to the table's start (u32).
    static let chainOffset = 4
  }

  /// For each Title in the set, its Chapters' entry points.
  let chapters: [[ChapterEntry]]
  let programChains: [ProgramChain]

  init(_ data: Data) throws(DiscError.Reason) {
    let ifo = ByteReader(data)
    guard try ifo.bytes(at: 0, count: 12) == Array("DVDVIDEO-VTS".utf8) else { throw .notAnIFO }

    let chapterTable = try ifo.u32(at: Header.chapterTableSector) * Sector.size
    // The table starts with its Title count (u16).
    let titleCount = try ifo.u16(at: chapterTable)
    let chapterTableEnd = chapterTable + (try ifo.u32(at: chapterTable + ChapterTable.lastByte)) + 1
    var listStarts: [Int] = []
    for index in 0..<titleCount {
      let listOffset = chapterTable + ChapterTable.listOffsets + 4 * index
      listStarts.append(chapterTable + (try ifo.u32(at: listOffset)))
    }
    var chapters: [[ChapterEntry]] = []
    for (start, end) in zip(listStarts, listStarts.dropFirst() + [chapterTableEnd]) {
      var list: [ChapterEntry] = []
      for entry in stride(from: start, to: end, by: ChapterTable.entrySize) {
        list.append(
          ChapterEntry(
            // An entry starts with its program chain (u16).
            programChain: try ifo.u16(at: entry),
            program: try ifo.u16(at: entry + ChapterTable.program)))
      }
      chapters.append(list)
    }
    self.chapters = chapters

    let chainTable = try ifo.u32(at: Header.programChainTableSector) * Sector.size
    var programChains: [ProgramChain] = []
    // The table starts with its program chain count (u16).
    for index in 0..<(try ifo.u16(at: chainTable)) {
      let entry = chainTable + ProgramChainTable.firstEntry + ProgramChainTable.entrySize * index
      let chain = chainTable + (try ifo.u32(at: entry + ProgramChainTable.chainOffset))
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

  /// Fields relative to the start of the program chain.
  private enum Field {
    /// The number of programs (u8).
    static let programCount = 2
    /// The number of Cells (u8).
    static let cellCount = 3
    /// The chain's playback time (BCD, 4 bytes).
    static let playbackTime = 4
    /// The offset of the program map: each program's entry Cell (u16; u8 per program).
    static let programMapOffset = 0xE6
    /// The offset of the Cell playback table (u16).
    static let cellTableOffset = 0xE8
  }

  /// The Cell playback table: one 24-byte entry per Cell, in playback order.
  private enum CellEntry {
    static let size = 24
    /// The Cell's playback time (BCD, 4 bytes).
    static let playbackTime = 4
    /// The Cell's first Sector (u32).
    static let firstSector = 8
    /// The Cell's last Sector (u32).
    static let lastSector = 20
  }

  let playbackTime: Duration
  /// The 1-based entry Cell of each program.
  let programs: [Int]
  let cells: [CellPlayback]

  init(_ ifo: ByteReader, at start: Int) throws(DiscError.Reason) {
    let programCount = try ifo.u8(at: start + Field.programCount)
    let cellCount = try ifo.u8(at: start + Field.cellCount)
    playbackTime = try ifo.playbackTime(at: start + Field.playbackTime)

    let programMap = start + (try ifo.u16(at: start + Field.programMapOffset))
    programs = try (0..<programCount).map { (index) throws(DiscError.Reason) in
      try ifo.u8(at: programMap + index)
    }

    let cellTable = start + (try ifo.u16(at: start + Field.cellTableOffset))
    cells = try (0..<cellCount).map { (index) throws(DiscError.Reason) in
      let cell = cellTable + CellEntry.size * index
      let firstSector = try ifo.u32(at: cell + CellEntry.firstSector)
      let lastSector = try ifo.u32(at: cell + CellEntry.lastSector)
      return CellPlayback(
        sectors: firstSector...lastSector,
        playbackTime: try ifo.playbackTime(at: cell + CellEntry.playbackTime))
    }
  }
}
