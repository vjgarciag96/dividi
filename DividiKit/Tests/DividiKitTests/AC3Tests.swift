import Foundation
import Testing

@testable import DividiKit

/// 128 kbps at 48 kHz: 256 words.
private func frame(_ filler: UInt8) -> Data {
  TestAC3.frame(frameSizeCode: 16, size: 512, filler: filler)
}

@Test func eachSyncFrameIsOneFrameOf1536Samples() throws {
  // 448 kbps at 48 kHz is 896 words; 192 kbps is 384 words.
  let first = TestAC3.frame(frameSizeCode: 30, size: 1_792, filler: 0x11)
  let second = TestAC3.frame(frameSizeCode: 20, size: 768, filler: 0x22)

  let frames = try AC3.frames(in: [.ac3(first + second, presentation: 90_000)]).frames

  #expect(
    frames == [
      CodedFrame(bytes: first, presentation: 90_000, duration: 2_880, isKeyframe: true),
      CodedFrame(bytes: second, presentation: 92_880, duration: 2_880, isKeyframe: true),
    ])
}

@Test func formatComesFromTheFirstFrame() throws {
  let stereo = try AC3.frames(in: [.ac3(frame(0))]).format
  let surround = try AC3.frames(in: [
    .ac3(TestAC3.frame(frameSizeCode: 16, size: 512, codingMode: 7, lfe: true))
  ]).format

  #expect(stereo == AC3.Format(sampleRate: 48_000, channels: 2))
  #expect(surround == AC3.Format(sampleRate: 48_000, channels: 6))
}

@Test func framesAt32kHzLast4320Ticks() throws {
  // 128 kbps at 32 kHz: 384 words.
  let frames = try AC3.frames(in: [
    .ac3(TestAC3.frame(sampleRateCode: 2, frameSizeCode: 16, size: 768), presentation: 0)
  ])

  #expect(frames.format?.sampleRate == 32_000)
  #expect(frames.frames.map(\.duration) == [4_320])
}

@Test func framesSplitAcrossPacketsAreJoined() throws {
  let frames = try AC3.frames(in: [
    .ac3(frame(1) + frame(2).prefix(100), presentation: 0),
    .ac3(frame(2).dropFirst(100)),
  ]).frames

  #expect(frames.map(\.bytes) == [frame(1), frame(2)])
}

@Test func timestampBelongsToTheFrameStartingInItsPacket() throws {
  let frames = try AC3.frames(in: [
    .ac3(frame(1) + frame(2).prefix(100), presentation: 0),
    .ac3(frame(2).dropFirst(100) + frame(3), presentation: 9_000),
  ]).frames

  #expect(frames.map(\.presentation) == [0, 2_880, 9_000])
}

@Test func framesBeforeTheFirstTimestampCountBack() throws {
  let frames = try AC3.frames(in: [
    .ac3(frame(1)),
    .ac3(frame(2), presentation: 9_000),
  ]).frames

  #expect(frames.map(\.presentation) == [6_120, 9_000])
}

@Test func partialFramesAtEitherEndAreDropped() throws {
  let frames = try AC3.frames(in: [
    .ac3(frame(1).suffix(50) + frame(2) + frame(3).prefix(50), presentation: 0)
  ]).frames

  #expect(frames.map(\.bytes) == [frame(2)])
}

@Test func streamWithoutFramesHasNoFormat() throws {
  let frames = try AC3.frames(in: [.ac3(Data([1, 2, 3]))])

  #expect(frames.format == nil)
  #expect(frames.frames.isEmpty)
}

@Test(arguments: [2, 6])
func realAudioFramesMatchFFprobe(channels: Int) throws {
  try withTemporaryDirectory { directory in
    let vob = directory.appendingPathComponent("source.vob")
    try run(
      "ffmpeg",
      [
        "-f", "lavfi", "-i", "testsrc2=size=720x576:rate=25",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "1",
        "-c:v", "mpeg2video", "-c:a", "ac3", "-ac", "\(channels)", "-f", "dvd", vob.path,
      ], in: directory)
    let data = try Data(contentsOf: vob)
    var packets: [PESPacket] = []
    for start in stride(from: 0, to: data.count, by: Sector.size) {
      packets += try ProgramStream.packets(inPack: data.subdata(in: start..<start + Sector.size))
    }

    let (format, frames) = try AC3.frames(in: packets.filter { $0.stream == .ac3(0) })

    #expect(format == AC3.Format(sampleRate: 48_000, channels: channels))
    let expected = try probe(vob, in: directory).packets.filter { $0.streamIndex == 2 }
    #expect(frames.count == expected.count)
    for (frame, packet) in zip(frames, expected) {
      #expect(frame.bytes == (try packet.payload()))
      #expect(frame.presentation == Int((packet.time * 90_000).rounded()))
      #expect(frame.duration == 2_880)
    }
  }
}
