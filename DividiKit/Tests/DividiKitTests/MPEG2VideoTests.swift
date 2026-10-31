import Foundation
import Testing

@testable import DividiKit

private typealias ES = TestMPEG2Video

@Test func eachPictureIsOneFrameWithItsSequenceAndGroupHeaders() throws {
  let headers = ES.sequenceHeader() + ES.groupOfPictures()
  let i = ES.picture(temporalReference: 2, type: 1, filler: 0x11)
  let b0 = ES.picture(temporalReference: 0, type: 3, filler: 0x22)
  let b1 = ES.picture(temporalReference: 1, type: 3, filler: 0x33)

  let frames = try MPEG2Video.frames(in: [
    .video(headers + i, presentation: 97_200),
    .video(b0, presentation: 90_000),
    .video(b1, presentation: 93_600),
  ]).frames

  #expect(
    frames == [
      CodedFrame(bytes: headers + i, presentation: 97_200, duration: 3_600, isKeyframe: true),
      CodedFrame(bytes: b0, presentation: 90_000, duration: 3_600, isKeyframe: false),
      CodedFrame(bytes: b1, presentation: 93_600, duration: 3_600, isKeyframe: false),
    ])
}

@Test func formatComesFromTheSequenceHeader() throws {
  let format = try MPEG2Video.frames(in: [
    .video(
      ES.sequenceHeader(width: 720, height: 480, aspect: 3, rate: 4)
        + ES.picture(temporalReference: 0, type: 1),
      presentation: 0)
  ]).format

  #expect(
    format == MPEG2Video.Format(width: 720, height: 480, displayAspect: .sixteenByNine))
}

@Test func ntscFramesLast3003Ticks() throws {
  let frames = try MPEG2Video.frames(in: [
    .video(
      ES.sequenceHeader(rate: 4) + ES.picture(temporalReference: 0, type: 1)
        + ES.picture(temporalReference: 1, type: 2),
      presentation: 0)
  ]).frames

  #expect(frames.map(\.presentation) == [0, 3_003])
  #expect(frames.map(\.duration) == [3_003, 3_003])
}

@Test func softTelecinedFramesLastTheFieldsTheyAreShownFor() throws {
  let three = ES.Coding(repeatFirstField: true)
  let two = ES.Coding()

  let frames = try MPEG2Video.frames(in: [
    .video(
      ES.sequenceHeader(rate: 4, progressive: false) + ES.groupOfPictures()
        + ES.picture(temporalReference: 0, type: 1, coding: three),
      presentation: 90_000),
    .video(ES.picture(temporalReference: 1, type: 2, coding: two)),
    .video(ES.picture(temporalReference: 2, type: 2, coding: three)),
    .video(ES.picture(temporalReference: 3, type: 2, coding: two)),
  ]).frames

  // 3 + 2 + 3 + 2 fields at 1501.5 ticks each, rounded from the group's start.
  #expect(frames.map(\.presentation) == [90_000, 94_505, 97_508, 102_012])
  #expect(frames.map(\.duration) == [4_505, 3_003, 4_505, 3_003])
}

@Test func reorderedPicturesCountTheFieldsShownBeforeThem() throws {
  let frames = try MPEG2Video.frames(in: [
    .video(
      ES.sequenceHeader(rate: 4, progressive: false) + ES.groupOfPictures()
        + ES.picture(temporalReference: 2, type: 1, coding: ES.Coding()),
      presentation: 97_508),
    .video(ES.picture(temporalReference: 0, type: 3, coding: ES.Coding(repeatFirstField: true))),
    .video(ES.picture(temporalReference: 1, type: 3, coding: ES.Coding())),
  ]).frames

  #expect(frames.map(\.presentation) == [97_508, 90_000, 94_505])
}

@Test func fieldPicturesOfOneFrameAreOneFrame() throws {
  let headers = ES.sequenceHeader(progressive: false) + ES.groupOfPictures()
  let top = ES.picture(temporalReference: 0, type: 1, coding: ES.Coding(structure: 1))
  let bottom = ES.picture(temporalReference: 0, type: 2, coding: ES.Coding(structure: 2))
  let next = ES.picture(temporalReference: 1, type: 2, coding: ES.Coding())

  let frames = try MPEG2Video.frames(in: [
    .video(headers + top, presentation: 90_000),
    .video(bottom),
    .video(next),
  ]).frames

  #expect(frames.map(\.bytes) == [headers + top + bottom, next])
  #expect(frames.map(\.presentation) == [90_000, 93_600])
  #expect(frames.map(\.duration) == [3_600, 3_600])
  #expect(frames.map(\.isKeyframe) == [true, false])
}

@Test func progressiveFramesRepeatWholeFrames() throws {
  let frames = try MPEG2Video.frames(in: [
    .video(
      ES.sequenceHeader() + ES.groupOfPictures()
        + ES.picture(temporalReference: 0, type: 1, coding: ES.Coding(repeatFirstField: true))
        + ES.picture(
          temporalReference: 1, type: 2,
          coding: ES.Coding(topFieldFirst: false, repeatFirstField: true))
        + ES.picture(temporalReference: 2, type: 2, coding: ES.Coding()),
      presentation: 0)
  ]).frames

  #expect(frames.map(\.presentation) == [0, 10_800, 18_000])
  #expect(frames.map(\.duration) == [10_800, 7_200, 3_600])
}

@Test func picturesSplitAcrossPacketsAreJoined() throws {
  let i = ES.sequenceHeader() + ES.picture(temporalReference: 0, type: 1, filler: 0x11)
  let p = ES.picture(temporalReference: 1, type: 2, filler: 0x22)

  let frames = try MPEG2Video.frames(in: [
    .video(i.prefix(10), presentation: 90_000),
    .video(i.dropFirst(10) + p.prefix(3)),
    .video(p.dropFirst(3)),
  ]).frames

  #expect(frames.map(\.bytes) == [i, p])
}

@Test func timestampBelongsToThePictureStartingInItsPacket() throws {
  let i = ES.sequenceHeader() + ES.picture(temporalReference: 0, type: 1, filler: 0x11)
  let p = ES.picture(temporalReference: 3, type: 2, filler: 0x22)

  let frames = try MPEG2Video.frames(in: [
    .video(i.prefix(30), presentation: 90_000),
    .video(i.dropFirst(30) + p, presentation: 100_800),
  ]).frames

  #expect(frames.map(\.presentation) == [90_000, 100_800])
}

@Test func picturesWithoutTimestampsCountFromTheirGroup() throws {
  let frames = try MPEG2Video.frames(in: [
    .video(
      ES.sequenceHeader() + ES.groupOfPictures() + ES.picture(temporalReference: 2, type: 1),
      presentation: 97_200),
    .video(ES.picture(temporalReference: 0, type: 3)),
    .video(ES.picture(temporalReference: 1, type: 3)),
    .video(ES.picture(temporalReference: 5, type: 2)),
  ]).frames

  #expect(frames.map(\.presentation) == [97_200, 90_000, 93_600, 108_000])
}

@Test func groupWithoutTimestampsFollowsThePreviousGroup() throws {
  let frames = try MPEG2Video.frames(in: [
    .video(
      ES.sequenceHeader() + ES.groupOfPictures() + ES.picture(temporalReference: 0, type: 1),
      presentation: 90_000),
    .video(ES.picture(temporalReference: 1, type: 2)),
    .video(ES.groupOfPictures() + ES.picture(temporalReference: 0, type: 1)),
    .video(ES.picture(temporalReference: 1, type: 2)),
  ]).frames

  #expect(frames.map(\.presentation) == [90_000, 93_600, 97_200, 100_800])
  #expect(frames.map(\.isKeyframe) == [true, false, true, false])
}

@Test func dataBeforeTheFirstSequenceHeaderIsDropped() throws {
  let i = ES.sequenceHeader() + ES.picture(temporalReference: 0, type: 1)

  let frames = try MPEG2Video.frames(in: [
    .video(ES.picture(temporalReference: 4, type: 2).dropFirst(2) + i, presentation: 90_000)
  ]).frames

  #expect(frames.map(\.bytes) == [i])
}

@Test func streamWithoutASequenceHeaderFails() {
  #expect(throws: DemuxError.missingSequenceHeader) {
    try MPEG2Video.frames(in: [.video(ES.picture(temporalReference: 0, type: 1))])
  }
}

@Test func squarePixelAspectRatioIsUnsupported() {
  #expect(throws: DemuxError.unsupportedAspectRatio) {
    try MPEG2Video.frames(in: [
      .video(ES.sequenceHeader(aspect: 1) + ES.picture(temporalReference: 0, type: 1))
    ])
  }
}

@Test func realVideoFramesMatchFFprobe() throws {
  try withTemporaryDirectory { directory in
    let vob = directory.appendingPathComponent("source.vob")
    try run(
      "ffmpeg",
      [
        "-f", "lavfi", "-i", "testsrc2=size=720x576:rate=25", "-t", "1",
        "-c:v", "mpeg2video", "-bf", "2", "-g", "12", "-aspect", "16:9", "-f", "dvd", vob.path,
      ], in: directory)
    let data = try Data(contentsOf: vob)
    var packets: [PESPacket] = []
    for start in stride(from: 0, to: data.count, by: Sector.size) {
      packets += try ProgramStream.packets(inPack: data.subdata(in: start..<start + Sector.size))
    }

    let (format, frames) = try MPEG2Video.frames(in: packets)

    #expect(format == MPEG2Video.Format(width: 720, height: 576, displayAspect: .sixteenByNine))
    let expected = try probe(vob, in: directory).packets.filter { $0.streamIndex == 1 }
    #expect(frames.count == expected.count)
    for (frame, packet) in zip(frames, expected) {
      #expect(frame.bytes == (try packet.payload()))
      #expect(frame.presentation == Int((packet.time * 90_000).rounded()))
      #expect(frame.isKeyframe == packet.flags.contains("K"))
      #expect(frame.duration == 3_600)
    }
  }
}
