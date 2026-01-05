# PolySplit

PolySplit is a macOS-friendly Bash utility that splits **polywav** (multichannel WAV) and **AIFF** files into **labeled mono WAVs** using FFmpeg.

It is designed for multitrack recordings from Behringer X32 and M32 systems (including the M32C), including the common case where long recordings are split into multiple 4.31 GB segments because the recorder is writing to a **FAT32** drive.

## What it does

- Splits each multichannel file into one WAV per channel
- Names files using your `channels.txt` labels (comments supported)
- Optional **stitch mode** that concatenates segmented recordings first (for example `00000001.WAV`, `00000002.WAV`, `00000003.WAV`), then splits the combined stream so you get **one continuous file per channel** for the full set

## Requirements

- macOS
- Homebrew recommended
- FFmpeg (includes `ffmpeg` and `ffprobe`)

Install FFmpeg:

```bash
brew install ffmpeg
```

## Install

Clone the repo and make the script executable:

```bash
git clone https://github.com/derbiter/PolySplit.git
cd PolySplit
chmod +x polysplit.sh
```

## Channel labels file (channels.txt)

`channels.txt` must contain **one channel name per line**, in the same order as the recorder’s channel order.

Rules:

- Blank lines are ignored
- Lines starting with `#` are comments and ignored
- Labels are sanitized for filenames (uppercased, spaces to `_`, unsafe characters to `_`)

Example:

```text
KICK
SNARE TOP
SNARE BOTTOM
OH L
OH R
# This is a comment
BASS DI
BASS MIC
```

PolySplit will stop if the number of non-comment lines does not match the source file’s channel count.

## Basic usage (split each polywav independently)

```bash
./polysplit.sh   --src "/path/to/audio"   --out "/path/to/output"   --channels "/path/to/channels.txt"
```

This scans `--src` recursively for `.wav`, `.aif`, and `.aiff`, then splits each multichannel file into mono WAVs.

### Output naming (default: flat layout)

Flat layout writes everything directly into `--out`:

- `<stem>_<NN>_<CHANNEL>.wav`

Example:

- `5C22B94E_01_KICK.wav`
- `5C22B94E_02_SNARE_TOP.wav`

## Stitch mode (recommended for X32/M32 FAT32 segments)

When recording to FAT32, long takes are often split into multiple segment files (commonly 8-digit names):

- `00000001.WAV`
- `00000002.WAV`
- `00000003.WAV`
- `00000004.WAV`

Stitch mode concatenates the segments in filename order and then splits into mono WAVs, producing one continuous per-channel file for the full recording.

### Stitch a single session folder

This is the most common workflow: point `--src` at the session folder containing the segments and set `--stitch dir`.

```bash
./polysplit.sh   --src "/Volumes/Q4 2025/KBC 2025/AUDIO/5C22B94E"   --out "/Volumes/Q4 2025/KBC 2025/AUDIO/5C22B94E/EXPORTS"   --channels "/Volumes/Q4 2025/KBC 2025/AUDIO/5C22B94E/channels.txt"   --stitch dir
```

Output (flat layout default):

- `5C22B94E_01_KICK.wav`
- `5C22B94E_02_SNARE_TOP.wav`
- ...

### How stitch discovery works

`--stitch dir`:

- If `--src` itself contains segment files named like `00000001.WAV`, it treats `--src` as one session.
- Otherwise, it searches under `--src` and treats each directory containing segment files as a separate session.

`--stitch all`:

- Treats `--src` as one session and attempts to stitch segment files directly under `--src`.
- Use with care. `dir` is usually safer for real show folders.

### Stitch validations

Before stitching, PolySplit validates that all segments in the session have:

- The same channel count
- The same sample rate

If anything mismatches, it stops with a clear error.

## Layouts

### Flat (default)

All output files go into `--out`.

```bash
--layout flat
```

### Folders

Creates a subfolder per source file or per stitched session.

```bash
--layout folders
```

Naming in folders layout:

- `<out>/<session>/<NN>_<CHANNEL>_<session>.wav`

Example:

- `EXPORTS/5C22B94E/01_KICK_5C22B94E.wav`

## Output safety modes

`--mode` controls what happens when the output folder already exists.

- `new` (default): automatically writes to a new folder by appending `_2`, `_3`, etc
- `backup`: renames the existing output folder to `__backup_<timestamp>` and then writes fresh output
- `overwrite`: deletes the output folder first (requires confirmation)
- `resume`: keeps the output folder and skips files that already exist (useful for reruns)

Examples:

```bash
# Resume (skip already-exported files)
./polysplit.sh --src "/in" --out "/out" --channels "./channels.txt" --mode resume

# Overwrite non-interactively (use carefully)
./polysplit.sh --src "/in" --out "/out" --channels "./channels.txt" --mode overwrite --yes
```

## Dry run

Use `--dry-run` to preview actions without writing anything:

```bash
./polysplit.sh   --src "/in"   --out "/out"   --channels "./channels.txt"   --stitch dir   --dry-run
```

## Performance tuning (Apple Silicon friendly)

PolySplit can run multiple FFmpeg jobs in parallel.

- `--workers N` sets the number of parallel jobs.
- Default is automatic (CPU/2), capped at 12.

On an Apple M4 Pro, good starting points:

- `--workers 6` to `8` if you are writing to a slower external drive
- `--workers 10` to `12` if you are writing to a fast SSD and you are not IO-bound

Example:

```bash
./polysplit.sh --src "/in" --out "/out" --channels "./channels.txt" --workers 8
```

## Logging and debugging

- `--loglevel` controls FFmpeg verbosity: `quiet`, `error`, `warning`, `info`, `verbose`
- If something fails, rerun with fewer workers and more verbosity:

```bash
./polysplit.sh --src "/in" --out "/out" --channels "./channels.txt" --workers 1 --loglevel verbose
```

## Tips for zsh users

Always quote paths. This avoids glob expansion problems in zsh when arguments contain special characters:

```bash
./polysplit.sh --src "/Volumes/SHOW/AUDIO/5C22B94E" --out "/Volumes/SHOW/AUDIO/EXPORTS" --channels "/Volumes/SHOW/AUDIO/channels.txt"
```

## License

MIT. See `LICENSE`.
