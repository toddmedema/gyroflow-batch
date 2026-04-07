#!/usr/bin/env bash
#
# gyroflow_export_projects.sh
#
# For each footage item (video file OR directory of DNG image sequences) in
# VIDEO_FOLDER, find a matching .gcsv motion file and lens profile, then run
# the Gyroflow CLI to export a .gyroflow project file into PROJECT_FOLDER.
#
# Usage:
#   ./gyroflow_export_projects.sh \
#       <PROJECT_FOLDER> \
#       <MOTION_FOLDER> \
#       <VIDEO_FOLDER> \
#       <LENS_FOLDER> \
#       <PROJECT_DEFAULTS> \
#       [--fps <FPS>]
#
# Arguments:
#   PROJECT_FOLDER   — output directory for .gyroflow project files
#   MOTION_FOLDER    — directory containing .gcsv motion data files
#   VIDEO_FOLDER     — directory containing video files and/or subdirectories
#                      of .dng image sequences
#   LENS_FOLDER      — directory containing lens profile .json files, with
#                      focal lengths in filenames (e.g. "…_25mm_…json")
#   PROJECT_DEFAULTS — path to a .gyroflow settings/preset file applied to
#                      every export
#   --fps <FPS>      — frame rate for image sequences (required if any DNG
#                      sequence directories are present in VIDEO_FOLDER)
#   --max-offset-ms <N>  drop autosync points with |offset| > N ms, then keep only the
#                      first and last among those still in range (may be none). Offsets
#                      are ms in the project file. Gyroflow search_size is always 5s.
#
# Example:
#   ./gyroflow_export_projects.sh \
#       ./projects ./motion ./videos ./lenses ./defaults.gyroflow --fps 24
#
# CLI reference: https://docs.gyroflow.xyz/app/advanced-usage/command-line-cli

set -euo pipefail

# Repo root (for gyroflow_batch_helpers.py and video_extensions.txt).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export GYROFLOW_BATCH_SCRIPT_DIR="$SCRIPT_DIR"

# Pipe-delimited alternation for [[ ext =~ ^(a|b)$ ]] — single source with
# video_extensions.txt and resolve_gyroflow_timeline.py.
VIDEO_EXTENSIONS=""
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [[ -z "$line" ]] && continue
    line=$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')
    if [[ -n "$VIDEO_EXTENSIONS" ]]; then VIDEO_EXTENSIONS+="|"; fi
    VIDEO_EXTENSIONS+="$line"
done < "$SCRIPT_DIR/video_extensions.txt"

# ── Configuration ────────────────────────────────────────────────────
GYROFLOW="/Applications/Gyroflow.app/Contents/MacOS/gyroflow"

# Export-project mode:
#   1 = default project
#   2 = with gyro data
#   3 = with processed gyro data
#   4 = video + project file
EXPORT_MODE=2

# Maximum seconds to wait for a single Gyroflow invocation before killing it.
GYROFLOW_TIMEOUT=300

# Optical-flow auto-sync: first CLI pass asks for up to this many sync points, then
# offsets with |value| > MAX_SYNC_OFFSET_MS are dropped; of those left, only the first
# and last sync point are kept (gyroflow_batch_helpers). Second pass uses AUTO_SYNC_POINTS.
SYNC_MAX_POINTS_INITIAL=6

# Fallback max sync points (second Gyroflow attempt) if the first pass fails.
AUTO_SYNC_POINTS=2

# Always passed to Gyroflow ``-s`` as search_size (seconds); matches app default.
GYROFLOW_SYNC_SEARCH_SECONDS=5

# Optional: merged into Gyroflow ``-s`` (synchronization) for optical-flow autosync quality.
# ``of_method``: 0=AKAZE (slower, often better), 1=OpenCV PyrLK, 2=OpenCV DIS (Gyroflow CLI default).
# Leave empty to take this field only from PROJECT_DEFAULTS (preset).
GYROFLOW_SYNC_OF_METHOD=""

# ``processing_resolution``: target frame height in pixels for sync (same meaning as the GUI).
# For GUI "Full", set this to the clip's native height (e.g. 1080, 2160). Empty = preset only.
GYROFLOW_SYNC_PROCESSING_RESOLUTION=""

# Drop autosync points whose |offset| exceeds this (milliseconds in project JSON).
# Default 5000 aligns with Gyroflow’s 5s search; lower (e.g. 500) to strip large outliers only.
MAX_SYNC_OFFSET_MS=5000

# DNG proxy sync encodes an h.264 mp4 for Gyroflow CLI (optical-flow autosync). Full-res
# 4K+ sequences are prohibitively slow; sync offsets are time-based and resolution-
# independent, so we cap proxy frame height (ffmpeg lanczos scale). Set 0 to disable
# scaling (full-resolution proxy — slow).
DNG_PROXY_SYNC_MAX_HEIGHT=720

# ── Parse arguments ──────────────────────────────────────────────────
if [[ $# -lt 5 ]]; then
    cat <<'EOF'
Usage:
  gyroflow_export_projects.sh \
      <PROJECT_FOLDER> <MOTION_FOLDER> <VIDEO_FOLDER> \
      <LENS_FOLDER> <PROJECT_DEFAULTS> \
      [--fps <FPS>] [--force] [--max-offset-ms <MS>]

  --fps              Frame rate for DNG image sequences (required when sequences exist)
  --force            Rebuild .gyroflow files even if they already exist (needed after
                     changing sync behavior or to re-run DNG proxy merge)
  --max-offset-ms    Drop autosync points with |offset| > this (ms), then keep only the
                     first/last of those still in range (may be zero). search_size 5s. Default 5000.
EOF
    exit 1
fi

PROJECT_FOLDER="$1"
MOTION_FOLDER="$2"
VIDEO_FOLDER="$3"
LENS_FOLDER="$4"
PROJECT_DEFAULTS="$5"
shift 5

SEQ_FPS=""
FORCE_RESYNC=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --fps)
            SEQ_FPS="$2"
            shift 2
            ;;
        --force)
            FORCE_RESYNC=1
            shift
            ;;
        --max-offset-ms)
            if [[ $# -lt 2 ]]; then
                echo "Error: --max-offset-ms requires a value (milliseconds)"
                exit 1
            fi
            if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: --max-offset-ms must be a non-negative integer (milliseconds)"
                exit 1
            fi
            if (( 10#$2 < 1 || 10#$2 > 600000 )); then
                echo "Error: --max-offset-ms must be between 1 and 600000"
                exit 1
            fi
            MAX_SYNC_OFFSET_MS=$((10#$2))
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ── Validate paths ───────────────────────────────────────────────────
if [[ ! -x "$GYROFLOW" ]]; then
    echo "Error: Gyroflow not found at $GYROFLOW"
    echo "       Required for video file processing and DNG proxy sync."
    exit 1
fi

if ! command -v ffmpeg &>/dev/null; then
    echo "Error: ffmpeg is required (used to create DNG proxy videos for sync)"
    exit 1
fi

if ! command -v python3 &>/dev/null; then
    echo "Error: python3 is required (used to build DNG sequence project files)"
    exit 1
fi

for dir in "$MOTION_FOLDER" "$VIDEO_FOLDER" "$LENS_FOLDER"; do
    if [[ ! -d "$dir" ]]; then
        echo "Error: Directory not found: $dir"
        exit 1
    fi
done

if [[ ! -f "$PROJECT_DEFAULTS" ]]; then
    echo "Error: Project defaults file not found: $PROJECT_DEFAULTS"
    exit 1
fi

mkdir -p "$PROJECT_FOLDER"

# ── Helper: extract focal length from a filename ─────────────────────
# Matches patterns like _114mm, _25mm, -50mm at word boundaries.
# Returns just the integer.
extract_focal_length() {
    local name="$1"
    if [[ "$name" =~ [_-]([0-9]+)mm([_.-]|$) ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# ── Helper: find a lens profile JSON matching a focal length ─────────
# Searches LENS_FOLDER for a .json whose filename contains "<int>mm".
find_lens_profile() {
    local focal_mm="$1"
    for json_file in "$LENS_FOLDER"/*.json; do
        [[ -f "$json_file" ]] || continue
        local base
        base="$(basename "$json_file")"
        if [[ "$base" =~ (^|[_-])${focal_mm}mm([_.-]|$) ]]; then
            echo "$json_file"
            return 0
        fi
    done
    return 1
}

# ── Helper: check if a directory is a DNG image sequence ─────────────
# Uses find instead of ${f,,} for bash 3.2 compatibility (macOS default).
is_image_sequence_dir() {
    local dir="$1"
    [[ -d "$dir" ]] || return 1
    [[ -n "$(find "$dir" -maxdepth 1 -iname "*.dng" -print -quit 2>/dev/null)" ]]
}

# Strip stale paths / bookmarks from a preset so CLI export cannot target old
# folders (same rules as DNG proxy sync — see sync_dng_project).
gyroflow_sanitize_preset_file() {
    local src="$1"
    local dst="$2"
    python3 -c "
import json, sys

PATH_KEYS = frozenset({
    'videofile', 'project_file', 'output_path', 'export_path', 'out_video',
    'output_folder', 'output_filename',
    'outputFolder', 'outputFilename', 'outputPath', 'exportPath', 'projectFile',
    'filepath', 'last_directory', 'recent_file',
    'save_path', 'cache_path', 'working_directory',
})


def is_stale_path_string(s):
    if not isinstance(s, str):
        return False
    t = s.strip()
    if not t:
        return False
    tl = t.lower()
    if tl.startswith('http://') or tl.startswith('https://'):
        return False
    if t.startswith('file://'):
        return True
    if '/tmp/' in t or '/var/folders/' in t:
        return True
    if '/Users/' in t or '/Volumes/' in t:
        return True
    if '/home/' in t:
        return True
    if '/private/var/' in t or t.startswith('/private/'):
        return True
    if t.startswith('/') and len(t) > 1:
        if t.startswith(('/Users/', '/Volumes/', '/home/', '/private/')):
            return True
    return False


def strip_stale_paths(obj):
    if isinstance(obj, dict):
        for k in list(obj.keys()):
            v = obj[k]
            if k == 'bookmark' or k.endswith('_bookmark') or k in PATH_KEYS:
                del obj[k]
                continue
            if isinstance(v, str) and is_stale_path_string(v):
                del obj[k]
                continue
            strip_stale_paths(v)
    elif isinstance(obj, list):
        for i in range(len(obj) - 1, -1, -1):
            v = obj[i]
            if isinstance(v, str) and is_stale_path_string(v):
                del obj[i]
            else:
                strip_stale_paths(v)


with open(sys.argv[1]) as f:
    p = json.load(f)
if isinstance(p, dict):
    for _k in ('output', 'render_queue', 'renderQueue', 'recent_files'):
        p.pop(_k, None)
strip_stale_paths(p)
with open(sys.argv[2], 'w') as f:
    json.dump(p, f)
" "$src" "$dst" || return 1
}

# JSON for Gyroflow -s: merge preset synchronization but force do_autosync,
# max_sync_points, and search_size=5s (Gyroflow default; not user-tunable here).
# Optional 2nd arg: max_sync_points (default AUTO_SYNC_POINTS).
# Optional 4th/5th args: non-empty overrides for of_method and processing_resolution
# (see GYROFLOW_SYNC_OF_METHOD / GYROFLOW_SYNC_PROCESSING_RESOLUTION).
gyroflow_sync_params_json_from_preset() {
    local preset_file="$1"
    local max_points="${2:-$AUTO_SYNC_POINTS}"
    python3 -c 'import json, sys
with open(sys.argv[1]) as f:
    p = json.load(f)
sync = p.get("synchronization")
if not isinstance(sync, dict):
    sync = {}
else:
    sync = dict(sync)
# Always true: preset may set do_autosync false — setdefault would keep false and
# Gyroflow skips optical-flow autosync (render_queue.rs:do_autosync).
sync["do_autosync"] = True
sync["max_sync_points"] = int(sys.argv[2])
sync["search_size"] = float(sys.argv[3])
if len(sys.argv) > 4 and sys.argv[4] != "":
    sync["of_method"] = int(sys.argv[4])
if len(sys.argv) > 5 and sys.argv[5] != "":
    sync["processing_resolution"] = int(sys.argv[5])
tp = sync.get("time_per_syncpoint", 1.0)
try:
    tp = float(tp)
except (TypeError, ValueError):
    tp = 1.0
if tp < 0.1:
    sync["time_per_syncpoint"] = 1.0
print(json.dumps(sync, separators=(",", ":")))
' "$preset_file" "$max_points" "$GYROFLOW_SYNC_SEARCH_SECONDS" \
        "${GYROFLOW_SYNC_OF_METHOD:-}" "${GYROFLOW_SYNC_PROCESSING_RESOLUTION:-}"
}

# Temporarily clear Gyroflow's Application Support settings and macOS defaults
# so stale renderQueue / export paths cannot override -p (see AGENTS.md).
# Also replace lens_profiles/default.gyroflow with {} — after each video load,
# Gyroflow CLI applies this preset (render_queue.rs: apply_preset). apply_to_all
# merges preset["output"] into job.render_options, which overrides -p if the
# default preset still had output_folder / output_path from an old GUI session.
# Sanitizing in place is not enough (race with GUI; bundled fallback still has
# an "output" object). Empty {} skips that merge path entirely.
GF_GYROFLOW_SETTINGS_BEGIN_DONE=false
GF_GYROFLOW_LENS_DEFAULT=""
GF_GYROFLOW_LENS_DEFAULT_BACKUP=""
GF_GYROFLOW_LENS_DEFAULT_HAD_FILE=false
gyroflow_settings_begin_isolate() {
    local sync_dir="$1"
    GF_GYROFLOW_SETTINGS_FILE=$(
        python3 -c "
import os, sys
if sys.platform == 'darwin':
    import pwd
    # Match Gyroflow core settings.rs: getpwuid_r(geteuid(), …), not getuid().
    root = os.path.join(pwd.getpwuid(os.geteuid()).pw_dir, 'Library', 'Application Support', 'Gyroflow')
else:
    root = os.path.join(os.environ.get('XDG_DATA_HOME') or os.path.expanduser('~/.local/share'), 'Gyroflow')
print(os.path.join(root, 'settings.json'))
"
    )
    GF_GYROFLOW_SETTINGS_BACKUP=""
    GF_GYROFLOW_SETTINGS_HAD_FILE=false
    if [[ -f "$GF_GYROFLOW_SETTINGS_FILE" ]]; then
        GF_GYROFLOW_SETTINGS_HAD_FILE=true
        GF_GYROFLOW_SETTINGS_BACKUP=$(mktemp "${sync_dir}/settings_backup_XXXXXX")
        cp "$GF_GYROFLOW_SETTINGS_FILE" "$GF_GYROFLOW_SETTINGS_BACKUP" || return 1
    fi
    mkdir -p "$(dirname "$GF_GYROFLOW_SETTINGS_FILE")"
    printf '%s\n' '{}' >"$GF_GYROFLOW_SETTINGS_FILE"

    GF_GYROFLOW_LENS_DEFAULT=""
    GF_GYROFLOW_LENS_DEFAULT_BACKUP=""
    GF_GYROFLOW_LENS_DEFAULT_HAD_FILE=false
    GF_GYROFLOW_LENS_DEFAULT="$(dirname "$GF_GYROFLOW_SETTINGS_FILE")/lens_profiles/default.gyroflow"
    mkdir -p "$(dirname "$GF_GYROFLOW_LENS_DEFAULT")"
    if [[ -f "$GF_GYROFLOW_LENS_DEFAULT" ]]; then
        GF_GYROFLOW_LENS_DEFAULT_HAD_FILE=true
        GF_GYROFLOW_LENS_DEFAULT_BACKUP=$(mktemp "${sync_dir}/default_lens_preset_backup_XXXXXX")
        cp "$GF_GYROFLOW_LENS_DEFAULT" "$GF_GYROFLOW_LENS_DEFAULT_BACKUP" || return 1
    fi
    printf '%s\n' '{}' >"$GF_GYROFLOW_LENS_DEFAULT" || return 1

    GF_GYROFLOW_MAC_DEFAULTS_BACKUP=""
    if [[ "$(uname -s)" == Darwin ]]; then
        GF_GYROFLOW_MAC_DEFAULTS_BACKUP=$(mktemp "${sync_dir}/gf_defaults_XXXXXX.plist")
        if ! defaults export xyz.gyroflow "$GF_GYROFLOW_MAC_DEFAULTS_BACKUP" 2>/dev/null; then
            rm -f "$GF_GYROFLOW_MAC_DEFAULTS_BACKUP"
            GF_GYROFLOW_MAC_DEFAULTS_BACKUP=""
        fi
        defaults delete xyz.gyroflow 2>/dev/null || true
    fi
    GF_GYROFLOW_SETTINGS_BEGIN_DONE=true
}

gyroflow_settings_end_restore() {
    [[ "$GF_GYROFLOW_SETTINGS_BEGIN_DONE" == true ]] || return 0
    GF_GYROFLOW_SETTINGS_BEGIN_DONE=false
    if [[ "$GF_GYROFLOW_SETTINGS_HAD_FILE" == true && -n "$GF_GYROFLOW_SETTINGS_BACKUP" && -f "$GF_GYROFLOW_SETTINGS_BACKUP" ]]; then
        cp "$GF_GYROFLOW_SETTINGS_BACKUP" "$GF_GYROFLOW_SETTINGS_FILE" 2>/dev/null || true
        rm -f "$GF_GYROFLOW_SETTINGS_BACKUP"
    elif [[ "$GF_GYROFLOW_SETTINGS_HAD_FILE" == false ]]; then
        rm -f "$GF_GYROFLOW_SETTINGS_FILE"
    fi
    if [[ "$GF_GYROFLOW_LENS_DEFAULT_HAD_FILE" == true && -n "$GF_GYROFLOW_LENS_DEFAULT_BACKUP" && -f "$GF_GYROFLOW_LENS_DEFAULT_BACKUP" && -n "$GF_GYROFLOW_LENS_DEFAULT" ]]; then
        cp "$GF_GYROFLOW_LENS_DEFAULT_BACKUP" "$GF_GYROFLOW_LENS_DEFAULT" 2>/dev/null || true
        rm -f "$GF_GYROFLOW_LENS_DEFAULT_BACKUP"
    elif [[ "$GF_GYROFLOW_LENS_DEFAULT_HAD_FILE" == false && -n "$GF_GYROFLOW_LENS_DEFAULT" ]]; then
        rm -f "$GF_GYROFLOW_LENS_DEFAULT"
    fi
    GF_GYROFLOW_LENS_DEFAULT_HAD_FILE=false
    GF_GYROFLOW_LENS_DEFAULT=""
    GF_GYROFLOW_LENS_DEFAULT_BACKUP=""
    if [[ "$(uname -s)" == Darwin && -n "$GF_GYROFLOW_MAC_DEFAULTS_BACKUP" && -f "$GF_GYROFLOW_MAC_DEFAULTS_BACKUP" ]]; then
        if [[ -s "$GF_GYROFLOW_MAC_DEFAULTS_BACKUP" ]]; then
            defaults import xyz.gyroflow "$GF_GYROFLOW_MAC_DEFAULTS_BACKUP" 2>/dev/null || true
        fi
        rm -f "$GF_GYROFLOW_MAC_DEFAULTS_BACKUP"
    fi
}

# ── Helper: build .gyroflow project for a DNG sequence with Python ───
# Gyroflow's CLI deadlocks on DNG sequences (QCoreApplication can't drive
# the async image-sequence loader). This function constructs the project
# JSON directly, matching the schema from Gyroflow's export_gyroflow_data().
# Returns 0 on success, non-zero on failure. Writes the project to $6.
build_dng_project() {
    local seq_dir="$1"      # directory containing original DNG files
    local fps="$2"           # frame rate
    local lens_path="$3"    # lens profile .json
    local gcsv_path="$4"    # gyro motion .gcsv
    local preset_path="$5"  # preset .gyroflow (may be empty)
    local output_path="$6"  # where to write the project

    if ! command -v python3 &>/dev/null; then
        echo "Error: python3 is required to build DNG sequence projects" >&2
        return 1
    fi

    python3 - "$seq_dir" "$fps" "$lens_path" "$gcsv_path" "$preset_path" "$output_path" <<'PYEOF'
import json, sys, os, struct
from datetime import date

seq_dir     = sys.argv[1]
fps         = float(sys.argv[2])
lens_path   = sys.argv[3]
gcsv_path   = sys.argv[4]
preset_path = sys.argv[5]
output_path = sys.argv[6]

_root = os.environ.get("GYROFLOW_BATCH_SCRIPT_DIR")
if not _root:
    print("Error: GYROFLOW_BATCH_SCRIPT_DIR is not set", file=sys.stderr)
    sys.exit(1)
sys.path.insert(0, _root)
from gyroflow_batch_helpers import (
    canonical_dng_filenames,
    deep_merge,
    dng_sequence_videofile_url,
    file_url_from_local_path,
    lens_profile_json_looks_valid,
    normalize_gyro_source_after_preset_merge,
)


def read_dng_dimensions(path):
    """Read width/height from a DNG file's TIFF IFD0 header."""
    with open(path, "rb") as f:
        hdr = f.read(8)
        if len(hdr) < 8:
            raise ValueError("File too small for TIFF header")
        endian = "<" if hdr[:2] == b"II" else ">"
        ifd_offset = struct.unpack(endian + "I", hdr[4:8])[0]
        f.seek(ifd_offset)
        (num_entries,) = struct.unpack(endian + "H", f.read(2))

        width = height = None
        subfile_type = 0  # 0 = full-res, 1 = thumbnail

        for _ in range(num_entries):
            entry = f.read(12)
            if len(entry) < 12:
                break
            tag, dtype, count = struct.unpack(endian + "HHI", entry[:8])
            # value/offset field depends on data type size
            if dtype == 3 and count == 1:  # SHORT
                val = struct.unpack(endian + "H", entry[8:10])[0]
            elif dtype == 4 and count == 1:  # LONG
                val = struct.unpack(endian + "I", entry[8:12])[0]
            else:
                val = struct.unpack(endian + "I", entry[8:12])[0]

            if tag == 254:   # NewSubfileType
                subfile_type = val
            elif tag == 256:  # ImageWidth
                width = val
            elif tag == 257:  # ImageLength (height)
                height = val

        if width and height and subfile_type == 0:
            return width, height
        if width and height:
            return width, height

        raise ValueError("Could not find image dimensions in TIFF IFD")


def read_gcsv_header(path):
    """Parse the key=value header lines of a .gcsv file."""
    header = {}
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("t,"):
                break
            if "," in line:
                key, _, value = line.partition(",")
                header[key.strip()] = value.strip()
    return header


# ── Discover DNG files (same order as sync_dng_project / ffmpeg — see gyroflow_batch_helpers) ──
dng_files = canonical_dng_filenames(seq_dir)
if not dng_files:
    print("Error: no .dng files found in " + seq_dir, file=sys.stderr)
    sys.exit(1)

first_dng_name = dng_files[0]
first_dng_path = os.path.join(seq_dir, first_dng_name)
dng_count = len(dng_files)

# ── videofile URL: use %0Nd pattern (Gyroflow GUI resets fps / prompts if literal first frame)
video_url, seq_start = dng_sequence_videofile_url(seq_dir)

# ── Read DNG dimensions ─────────────────────────────────────────────
width, height = read_dng_dimensions(first_dng_path)

# ── Duration ─────────────────────────────────────────────────────────
duration_ms = (dng_count / fps) * 1000.0

# ── Read lens profile ────────────────────────────────────────────────
with open(lens_path, "r") as f:
    calibration_data = json.load(f)
if not lens_profile_json_looks_valid(calibration_data):
    print(
        "Warning: lens profile JSON may not load in Gyroflow (need full LensProfile: "
        "calibrator_version, calib_dimension.w/h, fisheye_params.camera_matrix). "
        "Use a profile exported from Gyroflow's lens database or a .json that matches that schema.",
        file=sys.stderr,
    )

# ── Read .gcsv header ────────────────────────────────────────────────
gcsv_header = read_gcsv_header(gcsv_path)
imu_orientation = gcsv_header.get("orientation", "XYZ")
detected_source = gcsv_header.get("vendor", gcsv_header.get("id", ""))

# ── Build file:// URL for motion file (encode % for Qt / Gyroflow) ───────
gcsv_abs = os.path.realpath(gcsv_path)
gcsv_url = file_url_from_local_path(gcsv_abs)

# ── Construct project JSON (matches Gyroflow v1.6.3 GUI export, root version 3)
project = {
    "title": "Gyroflow data file",
    "version": 3,
    "app_version": "1.6.3",
    "videofile": video_url,
    "calibration_data": calibration_data,
    "date": str(date.today()),
    "image_sequence_start": seq_start,
    "image_sequence_fps": fps,
    "background_color": [0, 0, 0, 255],
    "background_mode": 0,
    "background_margin": 0,
    "background_margin_feather": 0,
    "light_refraction_coefficient": 1.0,
    "video_info": {
        "width": width,
        "height": height,
        "rotation": 0,
        "num_frames": dng_count,
        "fps": fps,
        "duration_ms": duration_ms,
        "fps_scale": 1.0,
        "vfr_fps": fps,
        "vfr_duration_ms": duration_ms,
        "created_at": "",
    },
    "stabilization": {
        "fov": 1.0,
        "method": "Default",
        "smoothing_params": [],
        "frame_readout_time": 0.0,
        "frame_readout_direction": 0,
        "adaptive_zoom_window": 4.0,
        "adaptive_zoom_center_offset": [0.0, 0.0],
        "adaptive_zoom_method": 0,
        "additional_rotation": [0.0, 0.0, 0.0],
        "additional_translation": [0.0, 0.0, 0.0],
        "lens_correction_amount": 1.0,
        "horizon_lock_amount": 0.0,
        "horizon_lock_roll": 0.0,
        "horizon_lock_pitch_enabled": False,
        "horizon_lock_pitch": 0.0,
        "use_gravity_vectors": False,
        "horizon_lock_integration_method": 0,
        "video_speed": 1.0,
        "video_speed_affects_smoothing": True,
        "video_speed_affects_zooming": True,
        "video_speed_affects_zooming_limit": False,
        "max_zoom": 0.0,
        "max_zoom_iterations": 0,
        "frame_offset": 0.0,
    },
    "gyro_source": {
        "filepath": gcsv_url,
        "lpf": 0.0,
        "mf": 0.0,
        "rotation": [0.0, 0.0, 0.0],
        "acc_rotation": [0.0, 0.0, 0.0],
        "imu_orientation": imu_orientation,
        "gyro_bias": [0.0, 0.0, 0.0],
        "integration_method": 1,
        "sample_index": 0,
        "detected_source": detected_source,
    },
    "offsets": {},
    "keyframes": {},
    "trim_ranges_ms": [],
}

# ── Merge preset defaults into project ───────────────────────────────
if preset_path and os.path.isfile(preset_path):
    try:
        with open(preset_path, "r", encoding="utf-8") as f:
            preset = json.load(f)
        deep_merge(project, preset)
    except (json.JSONDecodeError, OSError, UnicodeError) as e:
        print(f"Warning: could not merge preset: {e}", file=sys.stderr)

# Ensure our video-specific fields aren't clobbered by the preset
project["videofile"] = video_url
project["image_sequence_start"] = seq_start
project["image_sequence_fps"] = fps
project["calibration_data"] = calibration_data
project["gyro_source"]["filepath"] = gcsv_url
normalize_gyro_source_after_preset_merge(project["gyro_source"])
project["video_info"]["width"] = width
project["video_info"]["height"] = height
project["video_info"]["num_frames"] = dng_count
project["video_info"]["fps"] = fps
project["video_info"]["duration_ms"] = duration_ms
project["video_info"]["vfr_fps"] = fps
project["video_info"]["vfr_duration_ms"] = duration_ms

# Preset merge can carry an older root "version" (e.g. 2); match current GUI exports.
project["version"] = 3
project.setdefault("videofile_bookmark", "")
out = project.get("output")
if isinstance(out, dict):
    out.setdefault("output_folder_bookmark", "")
    out.setdefault("pixel_format", "")

# ── Write output ─────────────────────────────────────────────────────
with open(output_path, "w") as f:
    json.dump(project, f, indent=2)

print(f"Wrote {output_path} ({dng_count} frames, {width}x{height}, {fps} fps)")
PYEOF
}

# ── Helper: sync a DNG project file via ffmpeg proxy ─────────────────
# Creates a proxy .mp4 at the DNG sequence resolution (no downscaling) under
# PROJECT_FOLDER/.gyroflow_sync/, runs Gyroflow CLI on it (which auto-syncs),
# then transplants the computed sync offsets into the DNG project file.
sync_dng_project() {
    local seq_dir="$1"       # directory containing DNG files
    local fps="$2"           # frame rate
    local lens_path="$3"     # lens profile .json
    local gcsv_path="$4"     # gyro motion .gcsv
    local preset_path="$5"   # preset .gyroflow
    local project_file="$6"  # existing DNG project file to enrich
    # Motion file passed to Gyroflow for proxy sync (copy with header tweaks if needed).
    local gcsv_for_proxy="$gcsv_path"

    # ── a) First DNG, count, literal extension (canonical — gyroflow_batch_helpers) ──
    local first_dng dng_count dng_ext
    {
        read -r first_dng
        read -r dng_count
        read -r dng_ext
    } < <(python3 -c "
import json, os, sys
sys.path.insert(0, os.environ['GYROFLOW_BATCH_SCRIPT_DIR'])
from gyroflow_batch_helpers import dng_sequence_metadata
m = dng_sequence_metadata(sys.argv[1])
print(m['first_path'])
print(m['count'])
print(m['ext'])
" "$seq_dir") || {
        echo "      sync: no DNG files or metadata failed in $seq_dir" >&2
        return 1
    }

    local first_name
    first_name="$(basename "$first_dng")"

    local prefix num_suffix pad seq_start
    if [[ "$first_name" =~ ^(.*[^0-9])([0-9]+)\.[dD][nN][gG]$ ]]; then
        prefix="${BASH_REMATCH[1]}"
        num_suffix="${BASH_REMATCH[2]}"
        pad=${#num_suffix}
        seq_start=$((10#$num_suffix))
    else
        echo "      sync: cannot parse DNG numbering from $first_name" >&2
        return 1
    fi

    # Literal extension (e.g. .DNG) so ffmpeg finds frames on case-sensitive volumes.
    local ffmpeg_pattern="${seq_dir}/${prefix}%0${pad}d${dng_ext}"

    local sync_dir
    sync_dir="$(dirname "$project_file")/.gyroflow_sync"
    if ! mkdir -p "$sync_dir"; then
        echo "      sync: could not create sync directory $sync_dir" >&2
        return 1
    fi

    # ── b) Create proxy .mp4 with ffmpeg ─────────────────────────────
    # BSD mktemp (macOS) requires the template to *end* with XXXXXX; a suffix
    # like .mp4 after the X's is invalid and leaves literal "XXXXXX" in the path.
    local tmp_proxy
    tmp_proxy=$(mktemp "${sync_dir}/proxy_XXXXXX")
    mv "$tmp_proxy" "${tmp_proxy}.mp4"
    tmp_proxy="${tmp_proxy}.mp4"

    if [[ "${DNG_PROXY_SYNC_MAX_HEIGHT:-0}" =~ ^[0-9]+$ ]] && (( DNG_PROXY_SYNC_MAX_HEIGHT > 0 )); then
        echo "      syncing via proxy ($dng_count DNG frames → mp4, max height ${DNG_PROXY_SYNC_MAX_HEIGHT}px)…"
        local vf_proxy
        vf_proxy="scale=-2:min(ih\\,${DNG_PROXY_SYNC_MAX_HEIGHT}):flags=lanczos,crop=iw-mod(iw\\,2):ih-mod(ih\\,2),format=yuv420p"
    else
        echo "      syncing via proxy ($dng_count DNG frames → full-res mp4)…"
        local vf_proxy
        vf_proxy="crop=iw-mod(iw\,2):ih-mod(ih\,2),format=yuv420p"
    fi

    local ffmpeg_start
    ffmpeg_start=$(date +%s)

    # Crop at most 1px per axis if needed so yuv420p / libx264 accept odd dimensions.
    # Strip global metadata/chapters from the proxy: DNG/XMP can embed absolute paths
    # from an old project; Gyroflow may read those tags and resolve export paths there
    # (observed even when --preset is fully sanitized and -p points at .gyroflow_sync/).
    if ! ffmpeg -nostdin -hide_banner -loglevel warning \
        -framerate "$fps" -start_number "$seq_start" \
        -i "$ffmpeg_pattern" \
        -map_metadata -1 -map_chapters -1 \
        -c:v libx264 -preset ultrafast -crf 30 \
        -vf "$vf_proxy" \
        -y "$tmp_proxy" 2>&1 | sed 's/^/      ffmpeg: /'; then
        echo "      sync: ffmpeg proxy creation failed" >&2
        rm -f "$tmp_proxy"
        return 1
    fi

    if [[ ! -s "$tmp_proxy" ]]; then
        echo "      sync: ffmpeg produced empty proxy file" >&2
        rm -f "$tmp_proxy"
        return 1
    fi

    local ffmpeg_end
    ffmpeg_end=$(date +%s)
    echo "      ffmpeg: $dng_count frames encoded in $((ffmpeg_end - ffmpeg_start))s"

    # ── c) Run Gyroflow CLI on the proxy ─────────────────────────────
    # Gyroflow loads settings from a fixed path: on macOS it uses getpwuid()'s
    # home dir + Library/Application Support/... (NOT $HOME — see
    # src/core/settings.rs data_dir()). Stale renderQueue / export state there
    # forces output paths to old folders before the preset applies. Temporarily
    # replace settings.json with {} for this run, then restore the backup.
    if ! gyroflow_settings_begin_isolate "$sync_dir"; then
        echo "      sync: could not back up Gyroflow settings" >&2
        rm -f "$tmp_proxy"
        return 1
    fi

    # Pass the same sanitized preset as the video CLI path (see 5b below). Runtime
    # evidence (DNG proxy with -s only): Gyroflow finished in ~0.2s with empty
    # offsets and no autosync; video with --preset + -s gets offsets. The
    # sanitizer strips paths/bookmarks/output/render_queue so import_gyroflow_data
    # is safe (see gyroflow_sanitize_preset_file). -s still forces do_autosync
    # and max_sync_points when merged with preset sync (cli.rs).
    local tmp_preset
    tmp_preset=$(mktemp "${sync_dir}/preset_XXXXXX")
    mv "$tmp_preset" "${tmp_preset}.gyroflow"
    tmp_preset="${tmp_preset}.gyroflow"
    if ! gyroflow_sanitize_preset_file "$preset_path" "$tmp_preset"; then
        echo "      sync: failed to sanitize preset" >&2
        gyroflow_settings_end_restore
        rm -f "$tmp_proxy" "$tmp_preset"
        return 1
    fi

    # If the .gcsv header sets has_accurate_timestamps, Gyroflow skips optical-flow
    # autosync entirely (render_queue.rs:do_autosync) — proxy runs in ~0.2s with no
    # offsets. Phone exports often set this; strip it for the proxy pass only.
    gcsv_for_proxy=$(
        python3 -c 'import csv, os, re, sys, tempfile
path_in, sync_dir = sys.argv[1], sys.argv[2]
# Loose line match: phone exports may use extra columns or ;/tab (still common as one field).
_hdr_accurate = re.compile(
    r"^\s*has_accurate_timestamps\s*[,;\t]",
    re.IGNORECASE | re.MULTILINE,
)
with open(path_in, "r", encoding="utf-8", errors="replace", newline="") as f:
    content = f.read()
lines = content.splitlines(True)
out, passed_data, removed = [], False, False
for line in lines:
    if passed_data:
        out.append(line)
        continue
    stripped = line.strip()
    if not stripped:
        out.append(line)
        continue
    if _hdr_accurate.match(stripped):
        removed = True
        continue
    row = list(csv.reader([stripped]))[0]
    if len(row) == 1:
        out.append(line)
        continue
    # Any column count: first cell is the header key (telemetry-parser puts rest in Extra metadata).
    if len(row) >= 2 and row[0].strip().lower() == "has_accurate_timestamps":
        removed = True
        continue
    if len(row) >= 1 and row[0].strip() in ("t", "time"):
        passed_data = True
        out.append(line)
        continue
    out.append(line)
if not removed:
    print(path_in, end="")
else:
    fd, p = tempfile.mkstemp(suffix=".gcsv", prefix="sync_gcsv_", dir=sync_dir)
    os.close(fd)
    with open(p, "w", encoding="utf-8", newline="") as f:
        f.writelines(out)
    print(p, end="")
    print("      sync: removed has_accurate_timestamps from gcsv for proxy autosync", file=sys.stderr)
' "$gcsv_path" "$sync_dir"
    ) || gcsv_for_proxy="$gcsv_path"

    # Force export/render output next to the proxy in sync_dir (empty settings.json
    # uses default H.264 + .mp4 + _stabilized). Pass folder + filename so merge
    # cannot follow a stale preset output location.
    local out_params_json
    out_params_json=$(
        python3 -c 'import json, sys, os
from pathlib import Path
p = Path(sys.argv[1]).resolve()
d = str(p.parent)
stem = p.stem
stabilized = str(p.parent / (stem + "_stabilized.mp4"))
# RenderOptions.input_url is only set from JSON deserialization, not update_from_json.
# If it stays empty, relative output_folder resolution uses get_folder("") and can pick
# up a stale base (e.g. last GUI export path). Set input_url to the proxy file URI and
# mirror explicit output_* so merge_json cannot leave a relative output_folder.
out = {
    "output_path": stabilized,
    "output_folder": d,
    "output_filename": stem + "_stabilized.mp4",
    "input_url": p.as_uri(),
    "input_filename": p.name,
}
print(json.dumps(out))
' "$tmp_proxy"
    )

    # Merge synchronization: -s forces do_autosync and max_sync_points (first 6, then 2).
    # After each successful export, trim with MAX_SYNC_OFFSET_MS (apply-offset-policy):
    # drop |offset| > max, then first/last of those in range; may have no sync points.
    local helpers_py="${GYROFLOW_BATCH_SCRIPT_DIR}/gyroflow_batch_helpers.py"
    local sync_trim_ok=false
    local proxy_project=""
    local attempt max_pts sync_params_json gyro_output gyro_pid gyro_timed_out gyro_elapsed gyro_rc

    for attempt in 1 2; do
        if [[ $attempt -eq 1 ]]; then
            max_pts=$SYNC_MAX_POINTS_INITIAL
        else
            max_pts=$AUTO_SYNC_POINTS
        fi

        rm -f "${tmp_proxy%.mp4}.gyroflow"
        sync_params_json=$(gyroflow_sync_params_json_from_preset "$tmp_preset" "$max_pts")

        local proxy_cmd=(
            "$GYROFLOW"
            "$tmp_proxy"
            "$lens_path"
            -g "$gcsv_for_proxy"
            --preset "$tmp_preset"
            -s "$sync_params_json"
        )
        proxy_cmd+=(
            -p "$out_params_json"
            --export-project "$EXPORT_MODE"
        )

        gyro_output=$(mktemp "${sync_dir}/sync_log_XXXXXX")
        LC_ALL=C.UTF-8 LANG=C.UTF-8 "${proxy_cmd[@]}" > "$gyro_output" 2>&1 &
        gyro_pid=$!

        gyro_timed_out=false
        gyro_elapsed=0
        while kill -0 "$gyro_pid" 2>/dev/null; do
            if [[ $gyro_elapsed -ge $GYROFLOW_TIMEOUT ]]; then
                gyro_timed_out=true
                kill "$gyro_pid" 2>/dev/null || true
                sleep 2
                kill -9 "$gyro_pid" 2>/dev/null || true
                break
            fi
            sleep 1
            gyro_elapsed=$((gyro_elapsed + 1))
        done

        gyro_rc=0
        wait "$gyro_pid" 2>/dev/null || gyro_rc=$?

        if [[ -s "$gyro_output" ]]; then
            sed 's/^/      gyroflow: /' "$gyro_output"
        fi
        rm -f "$gyro_output"

        proxy_project="${tmp_proxy%.mp4}.gyroflow"
        if [[ ! -f "$proxy_project" ]]; then
            proxy_project=$(
                find "$sync_dir" -maxdepth 1 -name "$(basename "${tmp_proxy%.mp4}").gyroflow" -print -quit 2>/dev/null
            )
        fi

        if $gyro_timed_out; then
            echo "      sync: Gyroflow attempt $attempt timed out after ${GYROFLOW_TIMEOUT}s" >&2
            [[ -n "$proxy_project" && -f "$proxy_project" ]] && rm -f "$proxy_project"
            continue
        fi
        if [[ $gyro_rc -ne 0 ]]; then
            echo "      sync: Gyroflow attempt $attempt exited with error code $gyro_rc" >&2
            [[ -n "$proxy_project" && -f "$proxy_project" ]] && rm -f "$proxy_project"
            continue
        fi
        if [[ ! -f "$proxy_project" ]]; then
            echo "      sync: attempt $attempt — no proxy project file from Gyroflow" >&2
            continue
        fi

        if python3 "$helpers_py" apply-offset-policy "$proxy_project" "$MAX_SYNC_OFFSET_MS"; then
            if python3 "$helpers_py" offsets-min "$proxy_project" 2; then
                sync_trim_ok=true
                break
            fi
            echo "      sync: attempt $attempt — offset policy left fewer than 2 sync points (max_sync_points=$max_pts); retry or widen --max-offset-ms" >&2
        else
            echo "      sync: attempt $attempt — apply-offset-policy failed (max_sync_points=$max_pts)" >&2
        fi
        rm -f "$proxy_project"
        proxy_project=""
    done

    sleep 2
    gyroflow_settings_end_restore

    if ! $sync_trim_ok; then
        echo "      sync: FAILED — optical-flow sync did not yield usable offsets after 2 attempts" >&2
        rm -f "$tmp_proxy" "$tmp_preset"
        [[ "$gcsv_for_proxy" != "$gcsv_path" ]] && rm -f "$gcsv_for_proxy"
        rm -f "$project_file"
        return 1
    fi

    echo "      gyroflow: auto-sync complete"

    # ── d) Extract offsets + synchronization from proxy project and merge into DNG project
    if ! python3 "$helpers_py" "$proxy_project" "$project_file"; then
        echo "      sync: merge into DNG project failed" >&2
        rm -f "$tmp_proxy" "$proxy_project" "$tmp_preset"
        [[ "$gcsv_for_proxy" != "$gcsv_path" ]] && rm -f "$gcsv_for_proxy"
        rm -f "$project_file"
        return 1
    fi

    # ── e) Clean up ──────────────────────────────────────────────────
    rm -f "$tmp_proxy" "$proxy_project" "$tmp_preset"
    [[ "$gcsv_for_proxy" != "$gcsv_path" ]] && rm -f "$gcsv_for_proxy"

    return 0
}

# ── Build the list of footage items ──────────────────────────────────
footage_items=()
shopt -s nullglob

# DNG sequence directories first; skip standalone video files whose stem matches a
# sequence folder (same stem as 260403_…_VIDEO_25mm.dng/ + 260403_…_VIDEO_25mm.mp4).
for entry in "$VIDEO_FOLDER"/*; do
    if [[ -d "$entry" ]]; then
        if is_image_sequence_dir "$entry"; then
            footage_items+=("$entry")
        fi
    fi
done

for entry in "$VIDEO_FOLDER"/*; do
    if [[ -f "$entry" ]]; then
        ext="${entry##*.}"
        ext_lower="$(echo "$ext" | tr '[:upper:]' '[:lower:]')"
        if [[ "$ext_lower" =~ ^($VIDEO_EXTENSIONS)$ ]]; then
            vid_stem="$(basename "$entry")"
            vid_stem="${vid_stem%.*}"
            if [[ -d "$VIDEO_FOLDER/$vid_stem" ]] && is_image_sequence_dir "$VIDEO_FOLDER/$vid_stem"; then
                continue
            fi
            footage_items+=("$entry")
        fi
    fi
done

if [[ ${#footage_items[@]} -eq 0 ]]; then
    echo "No video files or DNG sequence directories found in $VIDEO_FOLDER"
    exit 0
fi

# ── Main loop ────────────────────────────────────────────────────────
total=0
success=0
skipped=0
failed=0

for item in "${footage_items[@]}"; do
    total=$((total + 1))
    # Machine-readable progress for UIs (Gyroflow Batch app parses this line).
    # Use awk+fflush so the line is not stuck in block-buffered stdout when this
    # script is piped (e.g. SwiftUI Process) — plain `echo` can defer until exit.
    awk -v c="$total" -v t="${#footage_items[@]}" \
        'BEGIN { printf "GYROFLOW_BATCH_PROGRESS %d %d\n", c, t; fflush(); exit }'
    stem="$(basename "$item")"
    is_seq=false

    # For video files, strip the extension for the matching stem
    if [[ -f "$item" ]]; then
        stem="${stem%.*}"
    elif [[ -d "$item" ]]; then
        is_seq=true
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if $is_seq; then
        echo "SEQ   $stem  (DNG image sequence)"
    else
        echo "VID   $stem"
    fi

    # ── 1. Require --fps for image sequences ─────────────────────────
    if $is_seq && [[ -z "$SEQ_FPS" ]]; then
        echo "FAIL  $stem — image sequence requires --fps but none was provided"
        failed=$((failed + 1))
        echo ""
        continue
    fi

    # ── 2. Find matching .gcsv motion file ───────────────────────────
    motion_file=""
    # Try direct match first
    for candidate in "$MOTION_FOLDER"/"$stem".gcsv "$MOTION_FOLDER"/"$stem".GCSV; do
        if [[ -f "$candidate" ]]; then
            motion_file="$candidate"
            break
        fi
    done
    # Fallback: case-insensitive find
    if [[ -z "$motion_file" ]]; then
        while IFS= read -r -d '' candidate; do
            motion_file="$candidate"
            break
        done < <(find "$MOTION_FOLDER" -maxdepth 1 -iname "${stem}.gcsv" -print0 2>/dev/null)
    fi

    if [[ -z "$motion_file" ]]; then
        echo "FAIL  $stem — no matching .gcsv in $MOTION_FOLDER"
        failed=$((failed + 1))
        echo ""
        continue
    fi

    # ── 3. Extract focal length & find lens profile ──────────────────
    focal_mm=""
    if ! focal_mm=$(extract_focal_length "$stem"); then
        echo "FAIL  $stem — no focal length in filename (expected _25mm or _114mm)"
        failed=$((failed + 1))
        echo ""
        continue
    fi

    lens_profile=""
    if ! lens_profile=$(find_lens_profile "$focal_mm"); then
        echo "FAIL  $stem — no lens profile for ${focal_mm}mm in $LENS_FOLDER"
        failed=$((failed + 1))
        echo ""
        continue
    fi

    # ── 4. Skip if project already exists ────────────────────────────
    project_file="$PROJECT_FOLDER/$stem.gyroflow"
    if [[ -f "$project_file" ]]; then
        if [[ "$FORCE_RESYNC" -ne 1 ]]; then
            echo "SKIP  $stem — project file already exists (use --force to rebuild)"
            skipped=$((skipped + 1))
            echo ""
            continue
        fi
        echo "      FORCE: replacing existing $project_file"
    fi

    echo "      motion:  $motion_file"
    echo "      lens:    $lens_profile  (${focal_mm}mm)"

    if $is_seq; then
        # ── 5a. DNG sequences: build project file with Python ────────
        # Gyroflow's CLI deadlocks on DNG sequences (its QCoreApplication
        # can't drive the async image-sequence loader). We construct the
        # .gyroflow project JSON directly instead.
        echo "      fps:     $SEQ_FPS"
        echo "      output:  $project_file"
        echo ""

        if build_dng_project "$item" "$SEQ_FPS" "$lens_profile" "$motion_file" "$PROJECT_DEFAULTS" "$project_file"; then
            if sync_dng_project "$item" "$SEQ_FPS" "$lens_profile" \
                    "$motion_file" "$PROJECT_DEFAULTS" "$project_file"; then
                echo "  OK  $stem  (synced)"
                success=$((success + 1))
            else
                echo "FAIL  $stem — DNG project sync failed (project file removed)"
                failed=$((failed + 1))
            fi
        else
            echo "FAIL  $stem — Python project builder failed"
            failed=$((failed + 1))
        fi
    else
        # ── 5b. Video files: use the Gyroflow CLI ────────────────────
        # Same isolation + sanitized preset + -p anchoring as DNG proxy sync:
        # global settings.json / macOS defaults can embed stale export paths and
        # cause IO errors even when auto-sync succeeds.
        sync_dir="$PROJECT_FOLDER/.gyroflow_sync"
        if ! mkdir -p "$sync_dir"; then
            echo "FAIL  $stem — could not create $sync_dir"
            failed=$((failed + 1))
            echo ""
            continue
        fi

        tmp_preset=$(mktemp "${sync_dir}/preset_vid_XXXXXX")
        mv "$tmp_preset" "${tmp_preset}.gyroflow"
        tmp_preset="${tmp_preset}.gyroflow"

        if ! gyroflow_sanitize_preset_file "$PROJECT_DEFAULTS" "$tmp_preset"; then
            echo "FAIL  $stem — could not sanitize preset (invalid JSON?)"
            rm -f "$tmp_preset"
            failed=$((failed + 1))
            echo ""
            continue
        fi

        if ! gyroflow_settings_begin_isolate "$sync_dir"; then
            echo "FAIL  $stem — could not back up Gyroflow settings" >&2
            rm -f "$tmp_preset"
            failed=$((failed + 1))
            echo ""
            continue
        fi

        vid_out_params_json=$(
            python3 -c 'import json, sys, os
item = sys.argv[1]
sync_dir = sys.argv[2]
stem = os.path.splitext(os.path.basename(item))[0]
p = os.path.join(sync_dir, stem + "_stabilized.mp4")
print(json.dumps({"output_path": p}))
' "$item" "$sync_dir"
        )

        # Auto-sync: try SYNC_MAX_POINTS_INITIAL then AUTO_SYNC_POINTS; apply-offset-policy
        # drops |offset| > MAX_SYNC_OFFSET_MS then keeps first/last in range (may be none).
        sync_sidecar="$sync_dir/$stem.gyroflow"
        default_location="$(dirname "$item")/$stem.gyroflow"
        vid_helpers="${GYROFLOW_BATCH_SCRIPT_DIR}/gyroflow_batch_helpers.py"
        video_export_ok=false

        echo "      output:  $project_file"
        echo ""

        for attempt in 1 2; do
            if [[ $attempt -eq 1 ]]; then
                max_pts=$SYNC_MAX_POINTS_INITIAL
            else
                max_pts=$AUTO_SYNC_POINTS
            fi

            vid_sync_params_json=$(gyroflow_sync_params_json_from_preset "$tmp_preset" "$max_pts")
            rm -f "$sync_sidecar"

            cmd=(
                "$GYROFLOW"
                "$item"                          # video file
                "$lens_profile"                  # lens profile .json (positional)
                -g "$motion_file"                # gyro / motion data
                --preset "$tmp_preset"           # sanitized — no stale paths
                -s "$vid_sync_params_json"       # force auto-sync point count
                -p "$vid_out_params_json"        # anchor export next to our sync dir
                --export-project "$EXPORT_MODE"  # export project file, don't render
            )

            echo "      attempt $attempt (max_sync_points=$max_pts)"
            echo "      cmd:     ${cmd[*]}"
            echo ""

            gyro_output=$(mktemp "${sync_dir}/gyroflow_out_XXXXXX")
            LC_ALL=C.UTF-8 LANG=C.UTF-8 "${cmd[@]}" > "$gyro_output" 2>&1 &
            gyro_pid=$!

            gyro_timed_out=false
            gyro_elapsed=0
            gyro_lines_shown=0
            while kill -0 "$gyro_pid" 2>/dev/null; do
                if [[ $gyro_elapsed -ge $GYROFLOW_TIMEOUT ]]; then
                    gyro_timed_out=true
                    kill "$gyro_pid" 2>/dev/null || true
                    sleep 2
                    kill -9 "$gyro_pid" 2>/dev/null || true
                    break
                fi
                new_lines=$(wc -l < "$gyro_output" | tr -d ' ')
                if [[ $new_lines -gt $gyro_lines_shown ]]; then
                    tail -n +$((gyro_lines_shown + 1)) "$gyro_output" | sed 's/^/      /'
                    gyro_lines_shown=$new_lines
                elif [[ $((gyro_elapsed % 15)) -eq 0 && $gyro_elapsed -gt 0 ]]; then
                    cpu_pct=$(ps -p "$gyro_pid" -o %cpu= 2>/dev/null | tr -d ' ' || echo "?")
                    open_files=$(lsof -p "$gyro_pid" 2>/dev/null | wc -l | tr -d ' ' || echo "?")
                    echo "      … waiting (${gyro_elapsed}s elapsed, cpu=${cpu_pct}%, open_files=${open_files})"
                fi
                sleep 1
                gyro_elapsed=$((gyro_elapsed + 1))
            done

            gyro_rc=0
            wait "$gyro_pid" 2>/dev/null || gyro_rc=$?

            new_lines=$(wc -l < "$gyro_output" | tr -d ' ')
            if [[ $new_lines -gt $gyro_lines_shown ]]; then
                tail -n +$((gyro_lines_shown + 1)) "$gyro_output" | sed 's/^/      /'
            fi
            rm -f "$gyro_output"

            export_src=""
            if [[ -f "$sync_sidecar" ]]; then
                export_src="$sync_sidecar"
            elif [[ -f "$default_location" ]]; then
                export_src="$default_location"
            fi

            if $gyro_timed_out; then
                echo "FAIL  $stem — Gyroflow attempt $attempt timed out after ${GYROFLOW_TIMEOUT}s (killed)" >&2
                [[ -n "$export_src" ]] && rm -f "$export_src"
                continue
            fi
            if [[ $gyro_rc -ne 0 ]]; then
                echo "FAIL  $stem — Gyroflow attempt $attempt exited with error code $gyro_rc" >&2
                [[ -n "$export_src" ]] && rm -f "$export_src"
                continue
            fi
            if [[ -z "$export_src" || ! -f "$export_src" ]]; then
                echo "      sync: attempt $attempt — Gyroflow produced no project file (checked sidecar + next to source)" >&2
                continue
            fi

            if python3 "$vid_helpers" apply-offset-policy "$export_src" "$MAX_SYNC_OFFSET_MS"; then
                if [[ "$export_src" != "$project_file" ]]; then
                    mv -f "$export_src" "$project_file"
                fi
                video_export_ok=true
                break
            fi
            echo "      sync: attempt $attempt — apply-offset-policy failed (max_sync_points=$max_pts)" >&2
            rm -f "$export_src"
        done

        sleep 2
        gyroflow_settings_end_restore
        rm -f "$tmp_preset"

        if $video_export_ok; then
            echo "  OK  $stem"
            success=$((success + 1))
        else
            echo "FAIL  $stem — video export / auto-sync failed after 2 attempts (project file removed if present)"
            rm -f "$project_file"
            failed=$((failed + 1))
        fi
    fi

    echo ""
done

# ── Summary ──────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Done.  Total: $total  |  OK: $success  |  Skipped: $skipped  |  Failed: $failed"
echo "Project files → $PROJECT_FOLDER"