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

  /// A playback time: 4 bytes holding hours, minutes, seconds and frames, each as two BCD digits
  /// (`0x59` is 59).
  ///
  /// The frames byte also holds the frame rate. Its top 2 bits are `01` for 25 fps (PAL) or `11`
  /// for 29.97 fps (NTSC), and its bottom 6 bits are the frame count, in BCD.
  func playbackTime(at offset: Int) throws(DiscError.Reason) -> Duration {
    func bcd(_ byte: Int) -> Int { (byte >> 4) * 10 + (byte & 0x0F) }
    let hours = try bcd(u8(at: offset))
    let minutes = try bcd(u8(at: offset + 1))
    let seconds = try bcd(u8(at: offset + 2))
    let frameByte = try u8(at: offset + 3)
    let frames = bcd(frameByte & 0x3F)
    let time = Duration.seconds(hours * 3600 + minutes * 60 + seconds)
    switch frameByte >> 6 {
    case 0b01: return time + .milliseconds(frames * 40)
    case 0b11: return time + .nanoseconds(frames * 100_100_000 / 3)
    default: return time
    }
  }
}
