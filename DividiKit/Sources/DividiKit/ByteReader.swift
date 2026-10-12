import Foundation

/// Bounds-checked big-endian reads from an IFO's bytes.
struct ByteReader {
  private let bytes: [UInt8]

  init(_ data: Data) {
    bytes = Array(data)
  }

  func u8(at offset: Int) throws(DiscError.Reason) -> Int {
    guard offset >= 0, offset < bytes.count else { throw .truncated }
    return Int(bytes[offset])
  }

  func u16(at offset: Int) throws(DiscError.Reason) -> Int {
    try u8(at: offset) << 8 | u8(at: offset + 1)
  }

  func u32(at offset: Int) throws(DiscError.Reason) -> Int {
    try u16(at: offset) << 16 | u16(at: offset + 2)
  }

  func bytes(at offset: Int, count: Int) throws(DiscError.Reason) -> [UInt8] {
    guard offset >= 0, count >= 0, offset + count <= bytes.count else { throw .truncated }
    return Array(bytes[offset..<offset + count])
  }

}
