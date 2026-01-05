# PolySplit

PolySplit is a macOS-friendly Bash utility that splits multichannel WAV (polywav) and AIFF files into labeled mono WAVs using FFmpeg.

It is built for Behringer X32 and M32 multitrack recordings, including the common FAT32 workflow where long recordings are saved as multiple 4.31 GB segment files.

## What it does

- Splits each multichannel file into one mono WAV per channel
- Names files using your channels.txt labels (comments supported)
- Optional stitch mode that concatenates segmented recordings first (for example 00000001.WAV, 00000002.WAV, 00000003.WAV), then splits the combined stream so you get one continuous file per channel

## Audio quality

PolySplit does not compress audio. It writes uncompressed PCM WAV output.

If your files are large, that is normal. X32 and M32 recordings are commonly 48 kHz PCM, often 32-bit, which produces large mono files for long sets.

## Requirements

- macOS (works on macOS 15+)
- Homebrew recommended
- FFmpeg (includes ffmpeg and ffprobe)

Install FFmpeg:

```bash
brew install ffmpeg
```

## Install

```bash
git clone https://github.com/derbiter/PolySplit.git
cd PolySplit
chmod +x polysplit.sh
```

## Channel labels file (channels.txt)

channels.txt must contain one channel name per line, in the same order as your recorder’s channels.

Rules:
- Blank lines are ignored
- Lines starting with # are comments and ignored
- Labels are sanitized for filenames (uppercase, spaces to _, unsafe characters to _)

Example:

```text
KICK IN
KICK OUT
SNARE TOP
SNARE BOT
RACK TOM
FLOOR
HH
BASS
VINCE GTR
BRANDON GTR
BRANDON VOX
# Unused channels can be numbers or left blank
12
13
14
```

PolySplit will stop if the number of non-comment lines does not match the source file’s channel count.

## Basic usage (split each polywav independently)

```bash
./polysplit.sh \
  --src "/path/to/audio" \
  --out "/path/to/output" \
  --channels "/path/to/channels.txt"
```

This scans --src recursively for .wav, .aif, and .aiff, then splits each multichannel file into mono WAVs.

## Stitch mode (recommended for X32/M32 FAT32 segments)

When recording to FAT32, long takes are often split into segment files (commonly 8-digit names):
- 00000001.WAV
- 00000002.WAV
- 00000003.WAV
- 00000004.WAV

Stitch mode concatenates the segments in filename order and then splits into mono WAVs, producing one continuous per-channel file for the full recording.

### Stitch a single session folder

```bash
./polysplit.sh \
  --src "/Volumes/Q4 2025/KBC 2025/AUDIO/5C22B94E" \
  --out "/Volumes/Q4 2025/KBC 2025/AUDIO/5C22B94E/PolySplit_Final" \
  --channels "/Volumes/Q4 2025/KBC 2025/AUDIO/5C22B94E/channels.txt" \
  --stitch dir \
  --mode final \
  --yes
```

### Stitch discovery modes

--stitch dir:
- If --src itself contains segment files named like 00000001.WAV, it treats --src as one session
- Otherwise, it searches under --src and treats each directory containing segment files as a separate session

--stitch all:
- Treats --src as one session and attempts to stitch segment files directly under --src
- Use with care. dir is usually safer.

### Stitch validations

Before stitching, PolySplit validates that all segments in the session have the same channel count and sample rate.

## Output naming

Default naming is:
- <SESSION>_<NN>_<LABEL>.wav

Example:
- 5C22B94E_01_KICK_IN.wav
- 5C22B94E_02_KICK_OUT.wav

### Smart naming (default)

Smart naming avoids redundant numeric labels. If your label is just the channel number, PolySplit omits it so you do not get 12_12.wav.

Example with 12 in channels.txt:
- 5C22B94E_12.wav

Name style options:
- --name-style smart (default)
- --name-style default (always include the label if present)

## Layouts

- --layout flat (default): all outputs go directly into --out
- --layout folders: creates a subfolder per source file or per stitched session

## Output safety modes

--mode controls what happens when the output already exists:

- new (default): writes to a new folder by appending _2, _3, etc
- backup: renames the existing output folder to __backup_<timestamp> and writes fresh output
- overwrite: deletes the output folder first (requires confirmation, or --yes)
- resume: keeps the output folder and skips files that already exist
- final: writes to a temporary work folder, then replaces the final output folder only if everything succeeds (recommended)

Recommended for clean reruns:
- --mode final --yes

## Dry run

Preview without writing files:

```bash
./polysplit.sh \
  --src "/in" \
  --out "/out" \
  --channels "./channels.txt" \
  --stitch dir \
  --mode final \
  --dry-run
```

## Performance tuning (Apple Silicon friendly)

- --workers N controls how many parallel jobs run
- --ffmpeg-threads N controls threads per FFmpeg job (often best kept low when running multiple workers)

Good starting points:
- --workers 6 to 10 depending on your disk speed
- --ffmpeg-threads 1 (default)

Example:

```bash
./polysplit.sh --src "/in" --out "/out" --channels "./channels.txt" --workers 8 --ffmpeg-threads 1
```

## zsh tip

Always quote paths to avoid zsh glob expansion issues:

```bash
./polysplit.sh --src "/Volumes/SHOW/AUDIO/5C22B94E" --out "/Volumes/SHOW/AUDIO/PolySplit_Final" --channels "/Volumes/SHOW/AUDIO/5C22B94E/channels.txt"
```

## License

MIT. See LICENSE.
