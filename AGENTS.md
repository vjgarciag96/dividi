# AGENTS.md

dividi: a native macOS app that remuxes DVD-Video Titles into MKV. Swift 6 and SwiftUI, macOS 15+. Read `README.md`, `CONTEXT.md` (use its vocabulary) and the issues labelled `decision` before changing behaviour.

## Layout
- `DividiKit/`: the engine, a Swift package with no UI. All logic and tests live here.
- `App/`: the SwiftUI app (`App/Dividi.xcodeproj`, scheme `Dividi`).

## Checks (run all of them before pushing; CI runs the same)
```sh
git ls-files -z '*.swift' | xargs -0 swift format lint --strict --parallel
cd DividiKit && swift test        # needs ffmpeg and ffprobe on PATH (brew install ffmpeg)
xcodebuild build -project App/Dividi.xcodeproj -scheme Dividi -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO
```
`swift format format -i --parallel <files>` fixes formatting in place.

## Rules
- No runtime dependencies (#1). ffmpeg, ffprobe, MKVToolNix and dvdauthor are development and test tools only.
- Remux only, never re-encode (#2). No CSS decryption (#3). All Disc access goes through `SectorSource`.
- Test doubles keep the same contract as `FolderSource`: they throw where it throws.
- Everything lands on `main` through a pull request with green CI, squash-merged. Large work goes up as stacked PRs, each with its own tests.

## Disc samples
- Real discs are copyrighted. Keep them in `samples/` (gitignored) and never commit them. Use them for local end-to-end checks only.

## Synthetic test disc (verified on macOS 15, ffmpeg 9, dvdauthor 0.7.2)
```sh
brew install ffmpeg dvdauthor mkvtoolnix   # spumux ships with dvdauthor
ffmpeg -f lavfi -i testsrc2=size=720x576:rate=25 -f lavfi -i sine=frequency=440:sample_rate=48000 \
  -t 12 -target pal-dvd -aspect 16:9 -ac 2 title1.mpg
spumux -s 0 subs.xml < title1.mpg > title1_sub.mpg      # image subtitles from PNGs
spumux menu.xml < menu_bg.mpg > menu.mpg                # menu buttons
VIDEO_FORMAT=PAL dvdauthor -x dvd.xml                   # menus, several Titles, Cells per <vob>
```
`subs.xml`, `menu.xml` and `dvd.xml` are the usual spumux and dvdauthor XML; each `<vob>` in a `<pgc>` becomes a Cell. Validate an extracted MKV with `mkvmerge -J`, `mkvinfo`, `ffprobe -count_frames`, `ffmpeg -xerror -i out.mkv -f null -` and VLC.

## Workflow
Frame, then model, then implement (by the `tests` skill), then review, adversarial-review and code-quality. Commits and PR text follow the `describe` skill. Keep `.work/` out of commits.
