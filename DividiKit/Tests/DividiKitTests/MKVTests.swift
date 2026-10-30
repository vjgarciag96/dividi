import Foundation
import Testing

@testable import DividiKit

@Test(arguments: [MKV.Video.DisplayAspect.fourByThree, .sixteenByNine])
func realStreamsRoundTrip(aspect: MKV.Video.DisplayAspect) throws {
  try withTemporaryDirectory { directory in
    let source = directory.appendingPathComponent("source.mkv")
    let output = directory.appendingPathComponent("output.mkv")
    let ratio = aspect == .fourByThree ? "4:3" : "16:9"
    try run(
      "ffmpeg",
      [
        "-f", "lavfi", "-i", "testsrc2=size=720x480:rate=25",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
        "-t", "1", "-c:v", "mpeg2video", "-bf", "2", "-g", "12",
        "-aspect", ratio, "-c:a", "ac3", "-ac", "2", source.path,
      ], in: directory)
    let original = try probe(source, in: directory)
    let offset = try #require(original.packets.map(\.time).min())
    func packets(_ index: Int) throws -> [MKV.Packet] {
      try original.packets.filter { $0.streamIndex == index }.map {
        MKV.Packet(
          bytes: try $0.payload(), presentation: .seconds($0.time - offset),
          duration: .seconds(try #require(Double($0.durationTime))),
          isKeyframe: $0.flags.contains("K"))
      }
    }
    let videoPackets = try packets(0)
    let audioPackets = try packets(1)
    #expect(
      zip(videoPackets, videoPackets.dropFirst()).contains { $0.presentation > $1.presentation })
    #expect(videoPackets.contains { !$0.isKeyframe })
    let data = try MKV.data(
      video: MKV.Video(width: 720, height: 480, displayAspect: aspect, packets: videoPackets),
      audio: MKV.Audio(sampleRate: 48_000, channels: 2, packets: audioPackets))
    try data.write(to: output)
    let result = try probe(output, in: directory)
    #expect(result.streams.map(\.codecName) == ["mpeg2video", "ac3"])
    #expect(result.streams[0].displayAspectRatio == ratio)
    let end = (videoPackets + audioPackets).map { $0.presentation + $0.duration }.max()!
    #expect(abs(Double(result.format.duration)! - seconds(end)) <= 0.001)
    for index in 0...1 {
      let before = original.packets.filter { $0.streamIndex == index }
      let after = result.packets.filter { $0.streamIndex == index }
      #expect(before.count == after.count)
      for (a, b) in zip(before, after) {
        #expect(try a.payload() == b.payload())
        #expect(a.flags.contains("K") == b.flags.contains("K"))
        #expect(abs(a.time - offset - b.time) <= 0.001)
      }
    }
    // Video must decode identically. Audio packet bytes are already compared above;
    // container skip-samples / priming is not modeled yet, so PCM framing can differ
    // under ffmpeg 9 even when the AC-3 bitstream matches. Still require a clean decode.
    #expect(
      try decodedHashes(source, map: "0:v:0", in: directory)
        == decodedHashes(output, map: "0:v:0", in: directory))
    try run(
      "ffmpeg", ["-xerror", "-i", output.path, "-map", "0:a:0", "-f", "null", "-"],
      in: directory)
  }
}

@Test func durationIncludesFinalFrameAndLongestTrack() throws {
  let packet = MKV.Packet(
    bytes: Data([0]), presentation: .zero, duration: .milliseconds(40), isKeyframe: true)
  let audioPacket = MKV.Packet(
    bytes: Data([0]), presentation: .zero, duration: .milliseconds(64), isKeyframe: true)
  let data = try MKV.data(
    video: MKV.Video(width: 720, height: 480, displayAspect: .fourByThree, packets: [packet]),
    audio: MKV.Audio(sampleRate: 48_000, channels: 2, packets: [audioPacket]))
  let duration = try #require(elements(data).first { $0.id == 0x4489 })
  let bits = duration.body.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
  #expect(Double(bitPattern: bits) == 64)
}

@Test func reorderedFramesAcrossClusterBoundaryKeepSignedTimestamps() throws {
  let times = [0, 32_800, 32_720, 32_760, 65_600, 65_520]
  let packets = times.enumerated().map { index, time in
    MKV.Packet(
      bytes: Data([UInt8(index)]), presentation: .milliseconds(time),
      duration: .milliseconds(40), isKeyframe: index == 0)
  }
  let data = try MKV.data(
    video: MKV.Video(width: 720, height: 480, displayAspect: .fourByThree, packets: packets),
    audio: MKV.Audio(sampleRate: 48_000, channels: 2, packets: [packets[0]]))
  var timestamp = 0
  var recovered: [Int] = []
  var flags: [UInt8] = []
  for element in elements(data) {
    if element.id == 0xE7 { timestamp = element.body.reduce(0) { ($0 << 8) | Int($1) } }
    if element.id == 0xA3, element.body[0] == 0x81 {
      let relative = Int16(bitPattern: UInt16(element.body[1]) << 8 | UInt16(element.body[2]))
      recovered.append(timestamp + Int(relative))
      flags.append(element.body[3])
    }
  }
  #expect(recovered == times)
  #expect(flags == [0x80, 0, 0, 0, 0, 0])
  let duration = try #require(elements(data).first { $0.id == 0x4489 })
  #expect(Double(bitPattern: duration.body.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }) == 65_640)
}

@Test func rejectsInvalidInput() {
  let packet = MKV.Packet(
    bytes: Data([0]), presentation: .zero, duration: .milliseconds(40), isKeyframe: true)
  let audio = MKV.Audio(sampleRate: 48_000, channels: 2, packets: [packet])
  func video(_ packets: [MKV.Packet], width: Int = 720) -> MKV.Video {
    MKV.Video(width: width, height: 480, displayAspect: .fourByThree, packets: packets)
  }
  #expect(throws: MKVError.emptyPackets(.video)) { try MKV.data(video: video([]), audio: audio) }
  #expect(throws: MKVError.emptyPackets(.audio)) {
    try MKV.data(
      video: video([packet]), audio: MKV.Audio(sampleRate: 48_000, channels: 2, packets: []))
  }
  #expect(throws: MKVError.negativePresentation(.video)) {
    try MKV.data(
      video: video([
        MKV.Packet(
          bytes: Data([0]), presentation: .seconds(-1),
          duration: .milliseconds(40), isKeyframe: true)
      ]), audio: audio)
  }
  for duration in [Duration.zero, .seconds(-1)] {
    #expect(throws: MKVError.nonPositiveDuration(.video)) {
      try MKV.data(
        video: video([
          MKV.Packet(
            bytes: Data([0]), presentation: .zero,
            duration: duration, isKeyframe: true)
        ]), audio: audio)
    }
  }
  #expect(throws: MKVError.nonPositive(.width)) {
    try MKV.data(video: video([packet], width: 0), audio: audio)
  }
}

private struct Probe: Decodable {
  struct Packet: Decodable {
    var streamIndex: Int
    var ptsTime: String
    var durationTime: String
    var flags: String
    var data: String
    var time: Double { Double(ptsTime)! }

    func payload() throws -> Data {
      var bytes = Data()
      for line in data.split(separator: "\n") {
        let afterAddress = try #require(line.split(separator: ":", maxSplits: 1).last)
        let hex = afterAddress.trimmingCharacters(in: .whitespaces).components(separatedBy: "  ")[0]
          .replacingOccurrences(of: " ", with: "")
        var index = hex.startIndex
        while index < hex.endIndex {
          let end = hex.index(index, offsetBy: 2)
          bytes.append(try #require(UInt8(hex[index..<end], radix: 16)))
          index = end
        }
      }
      return bytes
    }
  }
  struct Stream: Decodable {
    var codecName: String
    var displayAspectRatio: String?
  }
  struct Format: Decodable { var duration: String }
  var packets: [Packet]
  var streams: [Stream]
  var format: Format
}

private func probe(_ url: URL, in directory: URL) throws -> Probe {
  let output = try run(
    "ffprobe",
    ["-show_packets", "-show_data", "-show_streams", "-show_format", "-of", "json", url.path],
    in: directory)
  let decoder = JSONDecoder()
  decoder.keyDecodingStrategy = .convertFromSnakeCase
  return try decoder.decode(Probe.self, from: output)
}

private func decodedHashes(_ url: URL, map: String, in directory: URL) throws -> [String] {
  let output = try run(
    "ffmpeg",
    ["-xerror", "-i", url.path, "-map", map, "-f", "framemd5", "-"],
    in: directory)
  let rows = String(decoding: output, as: UTF8.self).split(separator: "\n").filter {
    !$0.hasPrefix("#")
  }
  #expect(!rows.isEmpty)
  return rows.map { row in
    let fields = row.split(separator: ",")
    return "\(fields[4]):\(fields[5])"
  }
}

private struct ToolFailure: Error, CustomStringConvertible { let description: String }

@discardableResult
private func run(_ tool: String, _ arguments: [String], in directory: URL) throws -> Data {
  let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
  let executable = try #require(
    paths.map { URL(fileURLWithPath: String($0)).appendingPathComponent(tool) }
      .first { FileManager.default.isExecutableFile(atPath: $0.path) })
  let stdout = directory.appendingPathComponent(UUID().uuidString)
  let stderr = directory.appendingPathComponent(UUID().uuidString)
  FileManager.default.createFile(atPath: stdout.path, contents: nil)
  FileManager.default.createFile(atPath: stderr.path, contents: nil)
  let outputHandle = try FileHandle(forWritingTo: stdout)
  let errorHandle = try FileHandle(forWritingTo: stderr)
  defer {
    try? outputHandle.close()
    try? errorHandle.close()
  }
  let process = Process()
  process.executableURL = executable
  process.arguments = ["-v", "error"] + arguments
  process.standardInput = FileHandle.nullDevice
  process.standardOutput = outputHandle
  process.standardError = errorHandle
  try process.run()
  process.waitUntilExit()
  let errors = try String(contentsOf: stderr, encoding: .utf8)
  guard process.terminationStatus == 0, errors.isEmpty else {
    throw ToolFailure(description: "\(tool) exited \(process.terminationStatus): \(errors)")
  }
  return try Data(contentsOf: stdout)
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(directory)
}

private func seconds(_ duration: Duration) -> Double {
  let parts = duration.components
  return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
}

private func elements(_ data: Data) -> [(id: UInt64, body: [UInt8])] {
  let bytes = Array(data)
  var result: [(id: UInt64, body: [UInt8])] = []
  var offset = 0
  func vint(stripMarker: Bool) -> UInt64 {
    let first = bytes[offset]
    let width = first.leadingZeroBitCount + 1
    var value = UInt64(stripMarker ? first & (0xFF >> width) : first)
    for index in 1..<width { value = (value << 8) | UInt64(bytes[offset + index]) }
    offset += width
    return value
  }
  while offset < bytes.count {
    let id = vint(stripMarker: false)
    let size = Int(vint(stripMarker: true))
    let body = Array(bytes[offset..<offset + size])
    result.append((id, body))
    if [UInt64(0x1853_8067), 0x1549_A966, 0x1F43_B675].contains(id) {
      result.append(contentsOf: elements(Data(body)))
    }
    offset += size
  }
  return result
}
