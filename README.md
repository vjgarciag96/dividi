# dividi

A native macOS app that extracts individual movies and TV episodes from DVD-Video discs into MKV files, without re-encoding.

> Status: early development. The app lists a Disc's Titles.

## What it does

- Reads DVD-Video from an inserted disc or a `VIDEO_TS` folder.
- Discovers titles, chapters, durations, audio and subtitle tracks, and their languages.
- Lets you pick whole titles or chapter ranges, and name the output files from a template.
- Extracts each selection into its own MKV file, keeping the original video, audio, subtitles and chapters.
- Runs selections as a batch, with progress for each one and a final report.

It has **no runtime dependencies**: nothing beyond the app needs to be installed.

## How it's built

Swift and SwiftUI, in two parts:

- **Engine**: no UI, fully testable.
  - *Disc reading*: reads raw disc sectors from a disc or folder.
  - *Disc understanding*: parses the IFO files into titles, chapters, cells and tracks.
  - *Demuxer*: reads a title's cells in playback order and splits out video, audio and subtitle streams.
  - *MKV writer*: writes those streams, plus chapters and track metadata, to MKV.
- **App**: one window that moves through four steps: Source → Review → Name → Extract.

Vocabulary is defined in [CONTEXT.md](CONTEXT.md); key decisions are tracked as [GitHub issues labelled `decision`](https://github.com/vjgarciag96/dividi/issues?q=label%3Adecision).

## Behaviour

- **Read errors**: retry, then fail that selection, continue the batch, and report the failure at the end.
- **Unusual discs**: titles that play cells out of disc order are supported; multi-angle and seamless-branching titles are detected and marked unsupported.
- **Playback**: output is MPEG-2 in MKV. Use VLC, IINA, Infuse, Plex or Jellyfin; QuickTime and Apple's TV app won't play it.

## Development

- `App/`: the Xcode project for the app. Open `App/Dividi.xcodeproj` and run.
- `DividiKit/`: the engine, a Swift package. Run `swift test` inside it.
- Formatting: `swift format`, default configuration. CI fails on any difference.

## Testing

- Automated tests run on GitHub Actions: format lint, engine tests and an app build.
- IFO parsing is tested with synthetic IFO bytes built by the tests.
- MKV tests require `ffmpeg` and `ffprobe` on PATH (`brew install ffmpeg`). They generate MPEG-2 video with B-frames and AC-3 audio, then verify packet preservation, timing, aspect ratio, and decoded audio/video hashes. These tools are development dependencies only.
- Real disc samples (copyrighted) may be used for local testing only and are never committed.

## Roadmap

1. Extract one title, with its video and one audio track, into an MKV that plays in VLC.
2. Chapters, all audio tracks, language tags.
3. Subtitles.
4. Chapter-range selections and batches.

### Not decided yet

- Heuristics for labelling and pre-selecting titles (episodes, extras, "Play All").
- How tracks are chosen.
- Test fixtures for the demuxer and MKV writer.
- Remembering discs between sessions.
- Decryption ([#3](https://github.com/vjgarciag96/dividi/issues/3)).
- Thumbnails and previews (for now: "Open in VLC").

### Out of scope

Re-encoding, online metadata lookup, batches spanning multiple discs, distribution through the App Store.
