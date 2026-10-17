import DividiKit
import Foundation

/// Builds the IFO files of a synthetic Disc, laid out as the DVD-Video format
/// specifies, without sharing any code with the parser.
struct TestDisc {
  var titles: [TestTitle] = []
  var titleSets: [TestTitleSet] = []

  var source: InMemorySource {
    InMemorySource(files: ["VIDEO_TS.IFO": videoManagerIFO()])
  }

  private func videoManagerIFO() -> Data {
    var titleTable = ByteWriter()
    titleTable.u16(titles.count)
    titleTable.u16(0)  // reserved
    titleTable.u32(8 + 12 * titles.count - 1)  // last byte of the table
    for title in titles {
      titleTable.u8(0)  // title type
      titleTable.u8(1)  // angle count
      titleTable.u16(1)  // Chapter count
      titleTable.u16(0)  // parental mask
      titleTable.u8(title.titleSet)
      titleTable.u8(title.titleInSet)
      titleTable.u32(0)  // Title Set's first Sector
    }

    var header = ByteWriter()
    header.ascii("DVDVIDEO-VMG")
    header.u16(titleSets.count, at: 0x3E)  // Title Set count
    header.u32(1, at: 0xC4)  // title table Sector
    return layOutIFO(header: header, tables: [titleTable])
  }
}

/// An entry in the Disc's title table.
struct TestTitle {
  var titleSet = 1
  var titleInSet = 1
}

struct TestTitleSet {}

/// Lays out an IFO: the header in sector 0, then each table starting on its own sector.
private func layOutIFO(header: ByteWriter, tables: [ByteWriter]) -> Data {
  var header = header
  let lastSector = tables.map(\.sectorCount).reduce(0, +)
  header.u32(lastSector, at: 0x1C)  // the IFO's last Sector
  header.pad(to: Sector.size)
  var data = header.data
  for table in tables {
    var table = table
    table.pad(to: table.sectorCount * Sector.size)
    data += table.data
  }
  return data
}

/// Writes big-endian fields, appending or at a fixed offset, growing as needed.
struct ByteWriter {
  private(set) var data = Data()

  var sectorCount: Int { max(1, (data.count + Sector.size - 1) / Sector.size) }

  mutating func pad(to count: Int) {
    if data.count < count { data.append(Data(count: count - data.count)) }
  }

  mutating func bytes(_ bytes: Data, at offset: Int? = nil) {
    let offset = offset ?? data.count
    pad(to: offset + bytes.count)
    data.replaceSubrange(offset..<offset + bytes.count, with: bytes)
  }

  mutating func u8(_ value: Int, at offset: Int? = nil) {
    bytes(Data([UInt8(value)]), at: offset)
  }

  mutating func u16(_ value: Int, at offset: Int? = nil) {
    bytes(Data([UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]), at: offset)
  }

  mutating func u32(_ value: Int, at offset: Int? = nil) {
    let bytes = (0..<4).reversed().map { UInt8(value >> ($0 * 8) & 0xFF) }
    self.bytes(Data(bytes), at: offset)
  }

  mutating func ascii(_ string: String, at offset: Int? = nil) {
    bytes(Data(string.utf8), at: offset)
  }
}
