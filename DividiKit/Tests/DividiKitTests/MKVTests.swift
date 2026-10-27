import Foundation
import Testing

@testable import DividiKit

@Test func shortExtractionMatchesProbe() throws {
  let video = MKV.Video(
    width: 720,
    height: 480,
    displayAspect: .fourByThree,
    packets: [
      MKV.Packet(bytes: Data([0x00, 0x00, 0x01, 0xB3]), presentation: .zero),
      MKV.Packet(bytes: Data([0x00, 0x00, 0x01, 0x00]), presentation: .seconds(1)),
    ])
  let audio = MKV.Audio(
    sampleRate: 48_000,
    channels: 2,
    packets: [
      MKV.Packet(bytes: Data([0x0B, 0x77]), presentation: .zero),
      MKV.Packet(bytes: Data([0x0B, 0x77]), presentation: .seconds(1)),
    ])

  let report = try ffprobe(try MKV.data(video: video, audio: audio))

  #expect(report.streams.map(\.codecType) == ["video", "audio"])
  #expect(report.streams.map(\.codecName) == ["mpeg2video", "ac3"])
  #expect(abs(report.duration - 1) <= 0.001)
}

@Test func thirtyThreeSecondPresentationOpens() throws {
  let video = MKV.Video(
    width: 720,
    height: 480,
    displayAspect: .fourByThree,
    packets: [
      MKV.Packet(bytes: Data([0x00, 0x00, 0x01, 0xB3]), presentation: .zero),
      MKV.Packet(bytes: Data([0x00, 0x00, 0x01, 0x00]), presentation: .seconds(33)),
    ])
  let audio = MKV.Audio(
    sampleRate: 48_000,
    channels: 2,
    packets: [
      MKV.Packet(bytes: Data([0x0B, 0x77]), presentation: .zero),
      MKV.Packet(bytes: Data([0x0B, 0x77]), presentation: .seconds(33)),
    ])

  let report = try ffprobe(try MKV.data(video: video, audio: audio))

  #expect(abs(report.duration - 33) <= 0.001)
}

@Test func displayAspectIsTheRatio() throws {
  let audio = MKV.Audio(
    sampleRate: 48_000,
    channels: 2,
    packets: [
      MKV.Packet(bytes: Data([0x0B, 0x77]), presentation: .zero),
      MKV.Packet(bytes: Data([0x0B, 0x77]), presentation: .seconds(1)),
    ])

  func video(_ aspect: MKV.Video.DisplayAspect) -> MKV.Video {
    MKV.Video(
      width: 720,
      height: 480,
      displayAspect: aspect,
      packets: [
        MKV.Packet(bytes: Data([0x00, 0x00, 0x01, 0xB3]), presentation: .zero),
        MKV.Packet(bytes: Data([0x00, 0x00, 0x01, 0x00]), presentation: .seconds(1)),
      ])
  }

  let fourByThree = try ffprobe(try MKV.data(video: video(.fourByThree), audio: audio))
  let sixteenByNine = try ffprobe(try MKV.data(video: video(.sixteenByNine), audio: audio))

  #expect(
    fourByThree.streams.first { $0.codecType == "video" }?.displayAspectRatio == "4:3",
    "\(fourByThree.raw)")
  #expect(
    sixteenByNine.streams.first { $0.codecType == "video" }?.displayAspectRatio == "16:9",
    "\(sixteenByNine.raw)")
}

@Test func rejectsInvalidInput() {
  let packet = MKV.Packet(bytes: Data([0x00]), presentation: .zero)
  let audio = MKV.Audio(sampleRate: 48_000, channels: 2, packets: [packet])
  let video = MKV.Video(
    width: 720, height: 480, displayAspect: .fourByThree, packets: [packet])

  #expect(throws: MKVError.emptyPackets(.video)) {
    try MKV.data(
      video: MKV.Video(width: 720, height: 480, displayAspect: .fourByThree, packets: []),
      audio: audio)
  }
  #expect(throws: MKVError.emptyPackets(.audio)) {
    try MKV.data(
      video: video,
      audio: MKV.Audio(sampleRate: 48_000, channels: 2, packets: []))
  }
  #expect(throws: MKVError.negativePresentation(.video)) {
    try MKV.data(
      video: MKV.Video(
        width: 720, height: 480, displayAspect: .fourByThree,
        packets: [MKV.Packet(bytes: Data([0x00]), presentation: .seconds(-1))]),
      audio: audio)
  }
  #expect(throws: MKVError.backwardsPresentation(.video)) {
    try MKV.data(
      video: MKV.Video(
        width: 720, height: 480, displayAspect: .fourByThree,
        packets: [
          MKV.Packet(bytes: Data([0x00]), presentation: .seconds(1)),
          MKV.Packet(bytes: Data([0x00]), presentation: .zero),
        ]),
      audio: audio)
  }
  #expect(throws: MKVError.nonPositive(.width)) {
    try MKV.data(
      video: MKV.Video(width: 0, height: 480, displayAspect: .fourByThree, packets: [packet]),
      audio: audio)
  }
}

private struct FFProbeReport {
  struct Stream {
    var codecName: String
    var codecType: String
    var displayAspectRatio: String?
  }

  var streams: [Stream]
  var duration: Double
  var raw: String
}

private struct FFProbeMissing: Error, CustomStringConvertible {
  var description: String { "ffprobe is missing" }
}

private struct FFProbeRejected: Error, CustomStringConvertible {
  var stdout: String
  var stderr: String

  var description: String { "ffprobe\n\(stdout)\n\(stderr)" }
}

private func ffprobe(_ data: Data) throws -> FFProbeReport {
  guard let executable = ffprobeExecutable() else { throw FFProbeMissing() }

  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("dividi-\(UUID().uuidString).mkv")
  try data.write(to: url)
  defer { try? FileManager.default.removeItem(at: url) }

  let process = Process()
  let stdout = Pipe()
  let stderr = Pipe()
  process.executableURL = executable
  process.arguments = [
    "-v", "error",
    "-show_entries", "format=duration:stream=codec_name,codec_type,display_aspect_ratio",
    "-of", "json",
    url.path,
  ]
  process.standardInput = FileHandle.nullDevice
  process.standardOutput = stdout
  process.standardError = stderr
  try process.run()
  process.waitUntilExit()

  let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  let errors = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  guard
    let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
    let streams = json["streams"] as? [[String: Any]],
    let format = json["format"] as? [String: Any],
    let duration = ffprobeDuration(format["duration"])
  else { throw FFProbeRejected(stdout: output, stderr: errors) }

  return FFProbeReport(
    streams: streams.map { stream in
      FFProbeReport.Stream(
        codecName: stream["codec_name"] as? String ?? "",
        codecType: stream["codec_type"] as? String ?? "",
        displayAspectRatio: stream["display_aspect_ratio"] as? String)
    },
    duration: duration,
    raw: output)
}

private func ffprobeDuration(_ value: Any?) -> Double? {
  if let text = value as? String { return Double(text) }
  if let number = value as? Double { return number }
  if let number = value as? NSNumber { return number.doubleValue }
  return nil
}

private func ffprobeExecutable() -> URL? {
  let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
  for directory in path.split(separator: ":") {
    let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("ffprobe")
    if FileManager.default.isExecutableFile(atPath: candidate.path) {
      return candidate
    }
  }
  return nil
}
