# PolySplit

PolySplit is a macOS-friendly Bash utility that splits multichannel WAV (polywav) and AIFF files into labeled mono WAVs using FFmpeg.

It is built for Behringer X32 and M32 multitrack recordings, including the common FAT32 workflow where long recordings are saved as multiple 4.31 GB segment files.

## What it does

- Splits each multichannel file into one mono WAV per channel.
- Names files using your `channels.txt` labels (comments supported).
- Optional stitch mode that concatenates segmented recordings first (for example `00000001.WAV`, `00000002.WAV`, `00000003.WAV`), then splits the combined stream so you get one continuous file per channel.

## Audio quality

PolySplit does not compress audio. It writes uncompressed PCM WAV output.

If your files are large, that is normal. X32 and M32 recordings are commonly 48 kHz PCM, often 32-bit, which produces large mono files for long sets.

## Requirements

- macOS (works on macOS 15+)
- Homebrew recommended
- FFmpeg (includes `ffmpeg` and `ffprobe`)

Install FFmpeg:

```bash
brew install ffmpeg

