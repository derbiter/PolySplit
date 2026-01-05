#!/usr/bin/env bash
# PolySplit
# Split X32/M32 polywav recordings into per-channel mono WAVs with clean, sortable names.
#
# Also supports stitching FAT32-capped segments (00000001.WAV, 00000002.WAV, ...) into a
# single continuous set per channel.
#
# macOS compatible (Bash 3.2 safe), tested workflow for Homebrew ffmpeg + zsh users.
#
# Key features
# - Safe output modes: backup, overwrite (typed confirm), new (auto-rename), resume
# - Pan-based splitting for wide FFmpeg compatibility
# - Auto-matches source audio bit depth/format (16/24/32/f32/f64)
# - Channel labels from channels.txt (comments OK)
# - Parallel processing with a Bash-3.2-safe worker limiter
# - Stitch mode for segmented X32/M32 recordings (concat demuxer + split in one ffmpeg run)
#
# Quick start
#   ./polysplit.sh --src "/in" --out "/out" --channels "/in/channels.txt"
#
# X32/M32 stitch example (folder contains 00000001.WAV, 00000002.WAV, ...)
#   ./polysplit.sh --src "/show/5C22B94E" --out "/show/5C22B94E/EXPORTS" --channels "/show/5C22B94E/channels.txt" --stitch dir

set -euo pipefail

# ---------- Tool checks ----------
command -v ffmpeg  >/dev/null || { echo "ffmpeg not found. Install with: brew install ffmpeg"; exit 1; }
command -v ffprobe >/dev/null || { echo "ffprobe not found. Install with: brew install ffmpeg"; exit 1; }
command -v sysctl  >/dev/null || true

# ---------- Defaults ----------
SRC_DIR=""
OUT_ROOT=""
CHANNELS_FILE=""
MODE="new"          # backup|overwrite|new|resume|final
YES="0"
DRYRUN="0"
PAD_WIDTH="2"
LAYOUT="flat"       # flat|folders
WORKERS="0"         # 0 -> auto
LOGLEVEL="info"     # ffmpeg loglevel
FFMPEG_THREADS="1" # ffmpeg -threads value (audio work is usually faster with small values when running parallel jobs)
STITCH="off"        # off|dir|all
NAME_STYLE="smart"  # default|smart (smart avoids redundant numeric labels)

# ---------- Helpers ----------
timestamp() { date +%Y%m%d-%H%M%S; }
log() { printf '%s\n' "$*" >&2; }
die() { log "Error: $*"; exit 1; }
is_tty() { [ -t 0 ] && [ -t 1 ]; }

unique_dir() {
  local base="${1%/}"
  if [ ! -e "$base" ]; then echo "$base"; return; fi
  local n=2
  while [ -e "${base}_$n" ]; do n=$((n+1)); done
  echo "${base}_$n"
}

supports_wav_opt() { ffmpeg -hide_banner -h muxer=wav 2>&1 | grep -q "$1"; }
WAV_MUX_OPTS=()
supports_wav_opt "write_bext" && WAV_MUX_OPTS+=( -write_bext 1 )
supports_wav_opt "write_iXML" && WAV_MUX_OPTS+=( -write_iXML 1 )

sanitize() {
  echo "$1" \
  | tr '[:lower:]' '[:upper:]' \
  | sed -E 's/[[:space:]]+/_/g; s/[^A-Z0-9_+=.-]/_/g; s/_+/_/g; s/^_//; s/_$//'
}

# Smart label normalization:
# - If channels.txt line is just the channel number (e.g. "12"), omit it to avoid filenames like _12_12.wav
# - If NAME_STYLE=default, keep labels exactly as provided (after sanitize)
normalize_label() {
  local idx="$1" name="$2" num rest
  num="$(printf "%0${PAD_WIDTH}d" "${idx}")"

  if [ "${NAME_STYLE}" = "default" ]; then
    echo "${name}"
    return
  fi

  # Empty label -> omit (file will be <prefix>_<NN>.wav)
  [ -n "${name}" ] || { echo ""; return; }

  # Pure numeric label matching the channel index -> omit
  if [[ "${name}" =~ ^0*${idx}$ ]] || [ "${name}" = "${num}" ]; then
    echo ""
    return
  fi

  # Labels like CH12 or CH_12 -> omit (prefix already includes NN)
  if [ "${name}" = "CH${num}" ] || [ "${name}" = "CH_${num}" ]; then
    echo ""
    return
  fi

  # If label starts with the channel index, strip it once (e.g. "12_12" -> "12" -> omitted)
  if [[ "${name}" =~ ^0*${idx}(_|$) ]]; then
    rest="${name#${idx}}"
    rest="${rest#_}"
    if [ -z "${rest}" ] || [[ "${rest}" =~ ^0*${idx}$ ]] || [ "${rest}" = "${num}" ]; then
      echo ""
    else
      echo "${rest}"
    fi
    return
  fi

  echo "${name}"
}


# Escape a path for FFmpeg concat demuxer: file '...'
concat_escape() {
  # FFmpeg concat demuxer supports backslash escapes inside quoted strings.
  # Escape backslashes first, then single quotes.
  printf "%s" "$1" | sed -e 's/\\/\\\\/g' -e "s/'/\\\'/g"
}

sort_paths() { LC_ALL=C sort "$@"; }

get_channel_count() {
  ffprobe -v error -select_streams a:0 -show_entries stream=channels -of default=nw=1:nk=1 "$1"
}

get_sample_rate() {
  ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of default=nw=1:nk=1 "$1"
}

detect_codec() {
  local f="$1" fmt bps codec
  fmt="$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_fmt -of default=nw=1:nk=1 "$f" || true)"
  bps="$(ffprobe -v error -select_streams a:0 -show_entries stream=bits_per_raw_sample -of default=nw=1:nk=1 "$f" || true)"
  if [ -z "${bps}" ] || [ "${bps}" = "N/A" ]; then
    bps="$(ffprobe -v error -select_streams a:0 -show_entries stream=bits_per_sample -of default=nw=1:nk=1 "$f" || true)"
  fi
  codec="pcm_s32le"
  case "${fmt}" in
    *s16*) codec="pcm_s16le" ;;
    *s24*) codec="pcm_s24le" ;;
    *s32*) codec="pcm_s32le" ;;
    *flt*) codec="pcm_f32le" ;;
    *dbl*) codec="pcm_f64le" ;;
  esac
  case "${bps}" in
    16) codec="pcm_s16le" ;;
    24) codec="pcm_s24le" ;;
    32) if echo "${fmt}" | grep -q flt; then codec="pcm_f32le"; else codec="pcm_s32le"; fi ;;
  esac
  echo "${codec}"
}

# Load channel labels into CHANNEL_NAMES[]
declare -a CHANNEL_NAMES
load_channel_names() {
  CHANNEL_NAMES=()
  [ -f "${CHANNELS_FILE}" ] || die "Missing channel list: ${CHANNELS_FILE}"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|\#*) continue ;; esac
    CHANNEL_NAMES+=( "$(sanitize "$line")" )
  done < "${CHANNELS_FILE}"
}

confirm_delete() {
  local target="$1"
  if [ "${YES}" = "1" ]; then return 0; fi
  if is_tty; then
    printf "About to DELETE permanently:\n  %s\nType 'DELETE' to confirm: " "${target}" >&2
    read -r ans || true
    [ "${ans}" = "DELETE" ] || die "Overwrite aborted."
  else
    die "Refusing to delete '${target}' without --yes in non-interactive mode."
  fi
}

safe_rm_rf() {
  local target="$1"
  [ -n "${target}" ] || die "rm got empty path"
  [ "${target}" != "/" ] || die "Refusing to remove /"
  [ "${target}" != "." ] || die "Refusing to remove ."

  if [ -d "${target}" ]; then
    if [ "${DRYRUN}" = "1" ]; then
      log "[DRY-RUN] rm -rf \"${target}\""
    else
      rm -rf "${target}"
    fi
  elif [ -e "${target}" ]; then
    if [ "${DRYRUN}" = "1" ]; then
      log "[DRY-RUN] rm -f \"${target}\""
    else
      rm -f "${target}"
    fi
  fi
}

mkout() {
  local dir="$1"
  if [ "${DRYRUN}" = "1" ]; then
    log "[DRY-RUN] mkdir -p \"${dir}\""
  else
    mkdir -p "${dir}"
  fi
}

# ---------- Processing ----------
build_filter_complex() {
  local ch_count="$1" i lbl fc=""
  i=0
  while [ $i -lt $ch_count ]; do
    lbl=$(printf "ch%02d" "$i")
    [ -n "$fc" ] && fc="${fc};"
    fc="${fc}[0:a]pan=mono|c0=c${i}[${lbl}]"
    i=$((i+1))
  done
  echo "${fc}"
}

# Non-stitch mode: split one polywav into mono files
process_one() {
  local wav="$1" base stem outdir prefix ch_count codec fc i num chname lbl outfile
  base="$(basename "$wav")"; stem="${base%.*}"

  if [ "${LAYOUT}" = "folders" ]; then
    outdir="${OUT_ROOT}/${stem}"
    prefix="${stem}"
  else
    outdir="${OUT_ROOT}"
    prefix="${stem}"
  fi
  mkout "${outdir}"

  ch_count="$(get_channel_count "${wav}")"
  [ -n "${ch_count}" ] || { log "Cannot read channels for: ${base}"; return 0; }

  if [ ${#CHANNEL_NAMES[@]} -ne "${ch_count}" ]; then
    die "Channel name count (${#CHANNEL_NAMES[@]}) != source channels (${ch_count}) for: ${base}"
  fi

  codec="$(detect_codec "${wav}")"
  fc="$(build_filter_complex "${ch_count}")"

  local args=( -hide_banner -nostdin -loglevel "${LOGLEVEL}" -y -threads "${FFMPEG_THREADS}" -i "${wav}" -filter_complex "${fc}" )
  local missing=0

  i=0
  while [ $i -lt $ch_count ]; do
    num=$(printf "%0${PAD_WIDTH}d" $((i+1)))
    chname="${CHANNEL_NAMES[$i]}"
    chname="$(normalize_label $((i+1)) "${chname}")"
    lbl=$(printf "ch%02d" "$i")

    if [ "${LAYOUT}" = "folders" ]; then
      if [ -n "${chname}" ]; then
        outfile="${outdir}/${num}_${chname}_${prefix}.wav"
      else
        outfile="${outdir}/${num}_${prefix}.wav"
      fi
    else
      if [ -n "${chname}" ]; then
        outfile="${outdir}/${prefix}_${num}_${chname}.wav"
      else
        outfile="${outdir}/${prefix}_${num}.wav"
      fi
    fi

    if [ -s "${outfile}" ] && [ "${MODE}" = "resume" ]; then
      i=$((i+1)); continue
    fi

    missing=$((missing+1))
    if [ "${DRYRUN}" = "1" ]; then
      log "[DRY-RUN] would write: ${outfile}"
    else
      args+=( -map "[${lbl}]" -c:a "${codec}" -map_metadata 0 "${WAV_MUX_OPTS[@]}" "${outfile}" )
    fi
    i=$((i+1))
  done

  if [ "${DRYRUN}" = "1" ]; then
    log "[DRY-RUN] ffmpeg (pan split) -> ${outdir}"
    return 0
  fi

  if [ $missing -eq 0 ]; then
    log "[${stem}] nothing to do."
    return 0
  fi

  ffmpeg "${args[@]}"
}

# Detect if filename looks like an X32/M32 segment: 8 digits plus .WAV
is_segment_filename() {
  echo "$1" | grep -Eiq '^[0-9]{8}\.wav$'
}

# List segments in a directory (newline delimited, absolute paths), sorted by filename
list_segments_in_dir() {
  local dir="$1"
  find "${dir}" -maxdepth 1 -type f -iname "*.wav" -print0 \
    | while IFS= read -r -d '' p; do
        b="$(basename "$p")"
        if is_segment_filename "$b"; then printf "%s\n" "$p"; fi
      done \
    | sort_paths
}

# Validate all segments have same channel count and sample rate
validate_segments() {
  local first="$1" list_file="$2" first_ch first_sr p ch sr
  first_ch="$(get_channel_count "$first")"
  first_sr="$(get_sample_rate "$first")"
  [ -n "$first_ch" ] || die "Cannot read channel count for: $first"
  [ -n "$first_sr" ] || die "Cannot read sample rate for: $first"

  while IFS= read -r p || [ -n "$p" ]; do
    [ -n "$p" ] || continue
    ch="$(get_channel_count "$p")"
    sr="$(get_sample_rate "$p")"
    [ "$ch" = "$first_ch" ] || die "Segment channel mismatch. Expected $first_ch, got $ch for: $p"
    [ "$sr" = "$first_sr" ] || die "Segment sample rate mismatch. Expected $first_sr, got $sr for: $p"
  done < "$list_file"
}

# Stitch mode: join segments in order, then split into mono files in one ffmpeg run
process_stitched_session() {
  local session_dir="$1" session_out="$2" session_name="$3"
  local segs_tmp list_tmp first_seg ch_count codec fc i num chname lbl outfile missing esc target_dir

  mkout "${session_out}"

  segs_tmp="$(mktemp -t polysplit_segs.XXXXXX)"
  list_segments_in_dir "${session_dir}" > "${segs_tmp}"

  first_seg="$(head -n 1 "${segs_tmp}" || true)"
  if [ -z "${first_seg}" ]; then
    rm -f "${segs_tmp}"
    log "[${session_name}] no segment files found, skipping."
    return 0
  fi

  validate_segments "${first_seg}" "${segs_tmp}"

  ch_count="$(get_channel_count "${first_seg}")"
  if [ ${#CHANNEL_NAMES[@]} -ne "${ch_count}" ]; then
    rm -f "${segs_tmp}"
    die "Channel name count (${#CHANNEL_NAMES[@]}) != source channels (${ch_count}) for session: ${session_name}"
  fi

  codec="$(detect_codec "${first_seg}")"
  fc="$(build_filter_complex "${ch_count}")"

  list_tmp="$(mktemp -t polysplit_concat.XXXXXX)"
  : > "${list_tmp}"
  while IFS= read -r p || [ -n "$p" ]; do
    [ -n "$p" ] || continue
    esc="$(concat_escape "$p")"
    printf "file '%s'\n" "${esc}" >> "${list_tmp}"
  done < "${segs_tmp}"
  rm -f "${segs_tmp}"

  local args=( -hide_banner -nostdin -loglevel "${LOGLEVEL}" -y -threads "${FFMPEG_THREADS}" -f concat -safe 0 -i "${list_tmp}" -filter_complex "${fc}" )

  missing=0
  i=0
  while [ $i -lt $ch_count ]; do
    num=$(printf "%0${PAD_WIDTH}d" $((i+1)))
    chname="${CHANNEL_NAMES[$i]}"
    chname="$(normalize_label $((i+1)) "${chname}")"
    lbl=$(printf "ch%02d" "$i")

    # Folders layout: put channel files under a per-session folder, without double nesting.
    if [ "${LAYOUT}" = "folders" ]; then
      if [ "$(basename "${session_out}")" = "${session_name}" ]; then
        target_dir="${session_out}"
      else
        target_dir="${session_out}/${session_name}"
      fi
      mkout "${target_dir}"
      if [ -n "${chname}" ]; then
        outfile="${target_dir}/${num}_${chname}_${session_name}.wav"
      else
        outfile="${target_dir}/${num}_${session_name}.wav"
      fi
    else
      if [ -n "${chname}" ]; then
        outfile="${session_out}/${session_name}_${num}_${chname}.wav"
      else
        outfile="${session_out}/${session_name}_${num}.wav"
      fi
    fi

    if [ -s "${outfile}" ] && [ "${MODE}" = "resume" ]; then
      i=$((i+1)); continue
    fi

    missing=$((missing+1))
    if [ "${DRYRUN}" = "1" ]; then
      log "[DRY-RUN] would write: ${outfile}"
    else
      args+=( -map "[${lbl}]" -c:a "${codec}" -map_metadata 0 "${WAV_MUX_OPTS[@]}" "${outfile}" )
    fi
    i=$((i+1))
  done

  if [ "${DRYRUN}" = "1" ]; then
    log "[DRY-RUN] ffmpeg (concat + pan split) -> ${session_out}"
    rm -f "${list_tmp}"
    return 0
  fi

  if [ $missing -eq 0 ]; then
    log "[${session_name}] nothing to do."
    rm -f "${list_tmp}"
    return 0
  fi

  ffmpeg "${args[@]}"
  rm -f "${list_tmp}"
}

# ---------- Arg parsing ----------
print_help() {
  cat <<EOF
PolySplit - Split polywav files into labeled mono WAVs.

Required (if not provided interactively):
  --src PATH            Source root to scan for .wav/.aif/.aiff
  --out PATH            Output root (per-file folders created when --layout folders)
  --channels PATH       Channel labels file

Options:
  --layout L            flat (default) or folders
  --mode M              backup | overwrite | new (default) | resume
  --stitch S            off (default) | dir | all
                        off: split each polywav file independently
                        dir: for each directory with segment files like 00000001.WAV, stitch in order, then split
                        all: stitch all segments found directly under --src as one session (use with care)
  --workers N           jobs to run in parallel (default: auto from CPU)
  --loglevel L          ffmpeg loglevel (quiet|error|warning|info|verbose) (default: info)
  --yes                 Skip destructive prompts (required for non-interactive overwrite)
  --dry-run             Print planned actions without writing
  --pad N               Zero pad width (default: 2)
  --help                Show this help

Examples:
  # Split each polywav independently
  ./polysplit.sh --src "/in" --out "/out" --channels "/in/channels.txt"

  # X32/M32 stitch mode, output one continuous file per channel
  ./polysplit.sh --src "/show/5C22B94E" --out "/show/5C22B94E/EXPORTS" --channels "/show/5C22B94E/channels.txt" --stitch dir

  # Resume and skip files that already exist
  ./polysplit.sh --src "/in" --out "/out" --channels "./channels.txt" --mode resume

  # Overwrite non-interactively
  ./polysplit.sh --src "/in" --out "/out" --channels "./channels.txt" --mode overwrite --yes
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --src) SRC_DIR="${2-}"; shift 2 ;;
    --out) OUT_ROOT="${2-}"; shift 2 ;;
    --channels) CHANNELS_FILE="${2-}"; shift 2 ;;
    --layout) LAYOUT="${2-}"; shift 2 ;;
    --mode) MODE="${2-}"; shift 2 ;;
    --stitch) STITCH="${2-}"; shift 2 ;;
    --name-style) NAME_STYLE="${2-}"; shift 2 ;;
    --workers) WORKERS="${2-}"; shift 2 ;;
    --loglevel) LOGLEVEL="${2-}"; shift 2 ;;
    --ffmpeg-threads) FFMPEG_THREADS="${2-}"; shift 2 ;;
    --yes) YES="1"; shift ;;
    --dry-run) DRYRUN="1"; shift ;;
    --pad) PAD_WIDTH="${2-}"; shift 2 ;;
    --help|-h) print_help; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# Interactive fallbacks
if [ -z "${SRC_DIR}" ]; then
  echo "Enter the source directory containing your polywavs:"
  read -r SRC_DIR
fi
[ -d "${SRC_DIR}" ] || die "Source not found: ${SRC_DIR}"

if [ -z "${OUT_ROOT}" ]; then
  SRC_PARENT="$(cd "${SRC_DIR}/.." && pwd)"
  OUT_ROOT="${SRC_DIR}/PolySplit_Final"
fi

# Finalize mode: build into a temporary work directory, then replace the final output folder on success.
FINAL_OUT="${OUT_ROOT}"
WORK_OUT="${OUT_ROOT}"
if [ "${MODE}" = "final" ]; then
  FINAL_OUT="${OUT_ROOT}"
  WORK_OUT="${OUT_ROOT}__work_$(timestamp)"
  WORK_OUT="$(unique_dir "${WORK_OUT}")"
  OUT_ROOT="${WORK_OUT}"
fi

# Conflict policy for OUT_ROOT (top-level only)
if [ -e "${OUT_ROOT}" ]; then
  case "${MODE}" in
    backup)
      BACKUP="${OUT_ROOT}__backup_$(timestamp)"
      log "Moving existing output to: ${BACKUP}"
      [ "${DRYRUN}" = "1" ] || mv "${OUT_ROOT}" "${BACKUP}"
      ;;
    overwrite)
      confirm_delete "${OUT_ROOT}"
      safe_rm_rf "${OUT_ROOT}"
      ;;
    resume)
      # keep as-is
      ;;
    new|"" )
      OUT_ROOT="$(unique_dir "${OUT_ROOT}")"
      log "Using new directory: ${OUT_ROOT}"
      ;;
    *)
      die "Unknown --mode '${MODE}'"
      ;;
  esac
fi

if [ -e "${OUT_ROOT}" ] && [ ! -d "${OUT_ROOT}" ]; then
  die "Output path exists and is not a directory: ${OUT_ROOT}"
fi
mkout "${OUT_ROOT}"

# Channels file
if [ -z "${CHANNELS_FILE}" ]; then
  if [ -f "./channels.txt" ]; then CHANNELS_FILE="./channels.txt"
  elif [ -f "${SRC_DIR}/channels.txt" ]; then CHANNELS_FILE="${SRC_DIR}/channels.txt"
  else die "--channels is required (channels.txt not found)"; fi
fi
load_channel_names

# Layout sanity
case "${LAYOUT}" in flat|folders) ;; *) log "Unknown --layout '${LAYOUT}', using 'flat'"; LAYOUT="flat" ;; esac

# Stitch sanity
case "${STITCH}" in off|dir|all) ;; *) die "Unknown --stitch '${STITCH}'. Use off, dir, or all." ;; esac

# Workers default
if [ "${WORKERS}" = "0" ]; then
  CPU="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  WORKERS=$(( CPU / 2 ))
  [ "${WORKERS}" -lt 1 ] && WORKERS=1
  # Apple Silicon can handle more parallel IO than older Intel, but still keep it sane.
  [ "${WORKERS}" -gt 12 ] && WORKERS=12
fi

log "Source:   ${SRC_DIR}"
log "Output:   ${OUT_ROOT}"
log "Layout:   ${LAYOUT}"
log "Mode:     ${MODE}"
log "Stitch:   ${STITCH}"
log "Workers:  ${WORKERS}"
log "Loglevel: ${LOGLEVEL}"
log "FFmpegTh: ${FFMPEG_THREADS}"
log "Channels: ${#CHANNEL_NAMES[@]}"

# ---------- Parallel worker limiter (Bash 3.2 safe) ----------
pids=()

prune_pids() {
  local pid
  local -a next=()
  for pid in "${pids[@]}"; do
    if kill -0 "${pid}" 2>/dev/null; then
      next+=( "${pid}" )
    fi
  done
  pids=( "${next[@]}" )
}

wait_for_slot() {
  while :; do
    prune_pids
    [ "${#pids[@]}" -lt "${WORKERS}" ] && break
    sleep 0.2
  done
}

run_job() {
  ( "$@" ) &
  pids+=( $! )
  wait_for_slot
}

# ---------- Scan and process ----------
if [ "${STITCH}" = "off" ]; then
  while IFS= read -r -d '' wav; do
    run_job process_one "${wav}"
  done < <(find "${SRC_DIR}" -type f \( -iname "*.wav" -o -iname "*.aif" -o -iname "*.aiff" \) -print0)
else
  sessions_tmp="$(mktemp -t polysplit_sessions.XXXXXX)"

  if [ "${STITCH}" = "dir" ]; then
    # If SRC_DIR itself is a session, just use it.
    if [ -n "$(list_segments_in_dir "${SRC_DIR}" | head -n 1 || true)" ]; then
      printf "%s\n" "${SRC_DIR}" > "${sessions_tmp}"
    else
      # Otherwise find any segment file under SRC_DIR and collect parent dirs (null-safe)
      find "${SRC_DIR}" -type f -iname "*.wav" -print0 \
        | while IFS= read -r -d '' p; do
            b="$(basename "$p")"
            if is_segment_filename "$b"; then dirname "$p"; fi
          done \
        | sort_paths -u > "${sessions_tmp}"
    fi
  else
    # all: treat SRC_DIR as one session (expects segments directly under SRC_DIR)
    printf "%s\n" "${SRC_DIR}" > "${sessions_tmp}"
  fi

  while IFS= read -r session_dir || [ -n "${session_dir}" ]; do
    [ -n "${session_dir}" ] || continue
    session_name="$(basename "${session_dir}")"

    # Output strategy:
    # - If stitching SRC_DIR itself (single session), write directly to OUT_ROOT.
    # - If stitching multiple discovered session dirs, write to OUT_ROOT/<session_name>.
    if [ "${session_dir}" = "${SRC_DIR}" ] && [ "${STITCH}" = "dir" ]; then
      session_out="${OUT_ROOT}"
    else
      session_out="${OUT_ROOT}/${session_name}"
    fi

    run_job process_stitched_session "${session_dir}" "${session_out}" "${session_name}"
  done < "${sessions_tmp}"

  rm -f "${sessions_tmp}"
fi

# Wait for background jobs and surface failures cleanly.
fail=0
set +e
for pid in "${pids[@]}"; do
  wait "${pid}"
  rc=$?
  if [ "${rc}" -ne 0 ]; then
    fail=1
  fi
done
set -e

if [ "${fail}" -ne 0 ]; then
  die "One or more jobs failed. Re-run with --workers 1 and/or --loglevel verbose for easier debugging."
fi


# If final mode, swap work directory into FINAL_OUT now that everything succeeded.
if [ "${MODE}" = "final" ] && [ "${DRYRUN}" != "1" ]; then
  if [ -e "${FINAL_OUT}" ]; then
    # Require confirmation/--yes to replace existing final output
    confirm_delete "${FINAL_OUT}"
    safe_rm_rf "${FINAL_OUT}"
  fi
  mv "${OUT_ROOT}" "${FINAL_OUT}"
  OUT_ROOT="${FINAL_OUT}"
  log "Finalized output: ${FINAL_OUT}"
fi

log "Done."
