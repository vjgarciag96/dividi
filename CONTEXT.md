# dividi

A macOS app that reads DVD-Video discs and extracts selected titles or chapter ranges into MKV files, keeping the original streams untouched.

## Language

### The disc

**Source**:
Where DVD-Video content is read from: an inserted disc or a `VIDEO_TS` folder on disk.
_Avoid_: Input, drive, image

**Disc**:
The DVD-Video structure exposed by a Source, as described by its IFO files.
_Avoid_: Media, volume

**Sector**:
The 2048-byte unit in which all disc content is read.
_Avoid_: Block

**Title Set**:
A group of Titles on a Disc that share the same video, audio and subtitle attributes.
_Avoid_: VTS (outside of format-level code)

**Title**:
A playable programme on a Disc (an episode, a movie, an extra, a "Play All" sequence), made of an ordered list of Cells.
_Avoid_: Track, video, stream

**Chapter**:
A user-visible entry point within a Title.
_Avoid_: Part, scene

**Cell**:
A contiguous run of Sectors that a Title plays as one piece; a Title may play its Cells in an order different from their position on the Disc.
_Avoid_: Segment, chunk

**Track**:
One audio or subtitle stream a Title offers, with its language and kind (e.g. commentary, forced).
_Avoid_: Stream (for the user-facing concept), channel

**Unsupported Title**:
A Title using multi-angle or seamless branching, which dividi detects and declines to extract.

### Extraction

**Selection**:
A whole Title, or a contiguous range of its Chapters, chosen for extraction.
_Avoid_: Clip, cut

**Naming Template**:
The user-filled pattern (show, season, starting episode) that names each Selection's output file.

**Extraction**:
Turning one Selection into one MKV file by remuxing its original streams, without re-encoding.
_Avoid_: Rip, conversion, encode

**Batch**:
The set of Extractions requested from a single Disc in one run, reported together at the end.
_Avoid_: Queue, job
