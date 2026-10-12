import Foundation

// Format-level views of the IFO files, as laid out by the DVD-Video specification.

/// `VIDEO_TS.IFO`: the Disc's title table.
struct VideoManagerIFO {
  struct TitleEntry {
    let titleSet: Int
    let titleInSet: Int
  }

  let titleSetCount: Int
  let titles: [TitleEntry]

  init(_ data: Data) throws(DiscError.Reason) {
    let ifo = ByteReader(data)
    guard try ifo.bytes(at: 0, count: 12) == Array("DVDVIDEO-VMG".utf8) else { throw .notAnIFO }
    titleSetCount = try ifo.u16(at: 0x3E)

    let table = try ifo.u32(at: 0xC4) * Sector.size
    var titles: [TitleEntry] = []
    for index in 0..<(try ifo.u16(at: table)) {
      let entry = table + 8 + 12 * index
      titles.append(
        TitleEntry(
          titleSet: try ifo.u8(at: entry + 6),
          titleInSet: try ifo.u8(at: entry + 7)))
    }
    self.titles = titles
  }
}
