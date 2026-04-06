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
#   --sync-search-ms <N>  optical-flow sync search window in milliseconds per
#                      sync point (default 500; Gyroflow default without override
#                      is 5000)
#
# Example:
#   ./gyroflow_export_projects.sh \
#       ./projects ./motion ./videos ./lenses ./defaults.gyroflow --fps 24
#
# CLI reference: https://docs.gyroflow.xyz/app/advanced-usage/command-line-cli

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────
GYROFLOW="/Applications/Gyroflow.app/Contents/MacOS/gyroflow"

# Export-project mode:
#   1 = default project
#   2 = with gyro data
#   3 = with processed gyro data
#   4 = video + project file
EXPORT_MODE=2

VIDEO_EXTENSIONS="mp4|mov|avi|mkv|mxf|braw|r3d|insv"

# Maximum seconds to wait for a single Gyroflow invocation before killing it.
GYROFLOW_TIMEOUT=300

# Optical-flow auto-sync: number of sync points (synchronization.max_sync_points).
AUTO_SYNC_POINTS=2

# Per-sync-point search window for optical-flow sync (seconds). Gyroflow default is 5s.
SYNC_SEARCH_SIZE_SECONDS=0.5

# ── Parse arguments ──────────────────────────────────────────────────
if [[ $# -lt 5 ]]; then
    cat <<'EOF'
Usage:
  gyroflow_export_projects.sh \
      <PROJECT_FOLDER> <MOTION_FOLDER> <VIDEO_FOLDER> \
      <LENS_FOLDER> <PROJECT_DEFAULTS> \
      [--fps <FPS>] [--force] [--sync-search-ms <MS>]

  --fps              Frame rate for DNG image sequences (required when sequences exist)
  --force            Rebuild .gyroflow files even if they already exist (needed after
                     changing sync behavior or to re-run DNG proxy merge)
  --sync-search-ms   Auto-sync search window in ms per point (default 500; omit to use
                     built-in default)
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
        --sync-search-ms)
            if [[ $# -lt 2 ]]; then
                echo "Error: --sync-search-ms requires a value (milliseconds)"
                exit 1
            fi
            if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: --sync-search-ms must be a non-negative integer (milliseconds)"
                exit 1
            fi
            if (( 10#$2 < 1 || 10#$2 > 600000 )); then
                echo "Error: --sync-search-ms must be between 1 and 600000"
                exit 1
            fi
            SYNC_SEARCH_SIZE_SECONDS=$(
                python3 -c "import sys; print(int(sys.argv[1]) / 1000.0)" "$2"
            )
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
    local count
    count=$(find "$dir" -maxdepth 1 -iname "*.dng" -print -quit 2>/dev/null | wc -l)
    [[ $count -gt 0 ]]
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
# max_sync_points, and search_size (preset value 0 disables autosync — we always
# use AUTO_SYNC_POINTS; default Gyroflow search_size is 5s — we use SYNC_SEARCH_SIZE_SECONDS).
gyroflow_sync_params_json_from_preset() {
    local preset_file="$1"
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
tp = sync.get("time_per_syncpoint", 1.0)
try:
    tp = float(tp)
except (TypeError, ValueError):
    tp = 1.0
if tp < 0.1:
    sync["time_per_syncpoint"] = 1.0
print(json.dumps(sync, separators=(",", ":")))
' "$preset_file" "$AUTO_SYNC_POINTS" "$SYNC_SEARCH_SIZE_SECONDS"
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
import json, sys, os, struct, re
from datetime import date

seq_dir     = sys.argv[1]
fps         = float(sys.argv[2])
lens_path   = sys.argv[3]
gcsv_path   = sys.argv[4]
preset_path = sys.argv[5]
output_path = sys.argv[6]


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


def deep_merge(base, override):
    """Recursively merge override dict into base dict."""
    for key, val in override.items():
        if key in base and isinstance(base[key], dict) and isinstance(val, dict):
            deep_merge(base[key], val)
        else:
            base[key] = val


# ── Discover DNG files ───────────────────────────────────────────────
dng_files = sorted(
    f for f in os.listdir(seq_dir)
    if f.lower().endswith(".dng")
)
if not dng_files:
    print("Error: no .dng files found in " + seq_dir, file=sys.stderr)
    sys.exit(1)

first_dng_name = dng_files[0]
first_dng_path = os.path.join(seq_dir, first_dng_name)
dng_count = len(dng_files)

# ── Extract sequence start frame number from filename ────────────────
seq_start = 0
m = re.search(r"(\d+)\.dng$", first_dng_name, re.IGNORECASE)
if m:
    seq_start = int(m.group(1))

# ── Read DNG dimensions ─────────────────────────────────────────────
width, height = read_dng_dimensions(first_dng_path)

# ── Duration ─────────────────────────────────────────────────────────
duration_ms = (dng_count / fps) * 1000.0

# ── Read lens profile ────────────────────────────────────────────────
with open(lens_path, "r") as f:
    calibration_data = json.load(f)

# ── Read .gcsv header ────────────────────────────────────────────────
gcsv_header = read_gcsv_header(gcsv_path)
imu_orientation = gcsv_header.get("orientation", "XYZ")
detected_source = gcsv_header.get("vendor", gcsv_header.get("id", ""))

# ── Build file:// URLs ───────────────────────────────────────────────
first_dng_abs = os.path.realpath(first_dng_path)
gcsv_abs = os.path.realpath(gcsv_path)

# Gyroflow uses file:// URLs (three slashes for absolute paths on macOS)
video_url = "file://" + first_dng_abs
gcsv_url  = "file://" + gcsv_abs

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
        with open(preset_path, "r") as f:
            preset = json.load(f)
        deep_merge(project, preset)
    except Exception as e:
        print(f"Warning: could not merge preset: {e}", file=sys.stderr)

# Ensure our video-specific fields aren't clobbered by the preset
project["videofile"] = video_url
project["image_sequence_start"] = seq_start
project["image_sequence_fps"] = fps
project["calibration_data"] = calibration_data
project["gyro_source"]["filepath"] = gcsv_url
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

    # ── a) Determine ffmpeg input pattern from first DNG ─────────────
    local first_dng
    first_dng=$(find "$seq_dir" -maxdepth 1 -iname "*.dng" 2>/dev/null \
        | sort | head -n1)
    if [[ -z "$first_dng" ]]; then
        echo "      sync: no DNG files found in $seq_dir" >&2
        return 1
    fi

    local first_name
    first_name="$(basename "$first_dng")"

    local prefix num_suffix pad seq_start
    if [[ "$first_name" =~ ^(.*[^0-9])([0-9]+)\.dng$ ]] || \
       [[ "$first_name" =~ ^(.*[^0-9])([0-9]+)\.DNG$ ]]; then
        prefix="${BASH_REMATCH[1]}"
        num_suffix="${BASH_REMATCH[2]}"
        pad=${#num_suffix}
        seq_start=$((10#$num_suffix))
    else
        echo "      sync: cannot parse DNG numbering from $first_name" >&2
        return 1
    fi

    local ffmpeg_pattern="${seq_dir}/${prefix}%0${pad}d.dng"
    local dng_count
    dng_count=$(find "$seq_dir" -maxdepth 1 -iname "*.dng" 2>/dev/null | wc -l | tr -d ' ')

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

    echo "      syncing via proxy ($dng_count DNG frames → full-res mp4)…"

    local ffmpeg_start
    ffmpeg_start=$(date +%s)

    # Full resolution (no scale down). Crop at most 1px per axis if needed so
    # yuv420p / libx264 accept odd dimensions; even-sized sources are unchanged.
    # Strip global metadata/chapters from the proxy: DNG/XMP can embed absolute paths
    # from an old project; Gyroflow may read those tags and resolve export paths there
    # (observed even when --preset is fully sanitized and -p points at .gyroflow_sync/).
    if ! ffmpeg -nostdin -hide_banner -loglevel warning \
        -framerate "$fps" -start_number "$seq_start" \
        -i "$ffmpeg_pattern" \
        -map_metadata -1 -map_chapters -1 \
        -c:v libx264 -preset ultrafast -crf 30 \
        -vf "crop=iw-mod(iw\,2):ih-mod(ih\,2),format=yuv420p" \
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

    # Merge synchronization: -s forces do_autosync and max_sync_points on top of the
    # sanitized preset (same as video export). Gyroflow's render queue runs optical-flow
    # autosync only when sync_settings contains "do_autosync": true (render_queue.rs).
    # Force max_sync_points to AUTO_SYNC_POINTS (preset 0 would disable autosync).
    local sync_params_json=""
    sync_params_json=$(gyroflow_sync_params_json_from_preset "$tmp_preset")

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

    local gyro_output
    gyro_output=$(mktemp "${sync_dir}/sync_log_XXXXXX")
    # Avoid Qt/macOS bookmark issues when locale is "C" (US-ASCII); Gyroflow warns otherwise.
    LC_ALL=C.UTF-8 LANG=C.UTF-8 "${proxy_cmd[@]}" > "$gyro_output" 2>&1 &
    local gyro_pid=$!

    local gyro_timed_out=false
    local gyro_elapsed=0
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

    local gyro_rc=0
    wait "$gyro_pid" 2>/dev/null || gyro_rc=$?

    # Allow Gyroflow's deferred settings flush to finish before we restore the file.
    sleep 2
    gyroflow_settings_end_restore

    # Print Gyroflow output
    if [[ -s "$gyro_output" ]]; then
        sed 's/^/      gyroflow: /' "$gyro_output"
    fi
    rm -f "$gyro_output"

    # Locate the proxy's exported .gyroflow file (same directory as tmp_proxy)
    local proxy_project="${tmp_proxy%.mp4}.gyroflow"
    if [[ ! -f "$proxy_project" ]]; then
        proxy_project=$(
            find "$sync_dir" -maxdepth 1 -name "$(basename "${tmp_proxy%.mp4}").gyroflow" -print -quit 2>/dev/null
        )
    fi

    if $gyro_timed_out; then
        echo "      sync: Gyroflow timed out after ${GYROFLOW_TIMEOUT}s" >&2
        rm -f "$tmp_proxy" "$tmp_preset"
        [[ "$gcsv_for_proxy" != "$gcsv_path" ]] && rm -f "$gcsv_for_proxy"
        [[ -n "$proxy_project" ]] && rm -f "$proxy_project"
        return 1
    fi

    if [[ $gyro_rc -ne 0 ]]; then
        echo "      sync: Gyroflow exited with error code $gyro_rc" >&2
        rm -f "$tmp_proxy" "$tmp_preset"
        [[ "$gcsv_for_proxy" != "$gcsv_path" ]] && rm -f "$gcsv_for_proxy"
        [[ -n "$proxy_project" ]] && rm -f "$proxy_project"
        return 1
    fi

    if [[ ! -f "$proxy_project" ]]; then
        echo "      sync: Gyroflow did not produce a proxy project file" >&2
        rm -f "$tmp_proxy" "$tmp_preset"
        [[ "$gcsv_for_proxy" != "$gcsv_path" ]] && rm -f "$gcsv_for_proxy"
        return 1
    fi

    echo "      gyroflow: auto-sync complete"

    # ── d) Extract offsets + synchronization from proxy project and merge into DNG project
    python3 - "$proxy_project" "$project_file" <<'PYEOF'
import json, os, sys

proxy_path   = sys.argv[1]
project_path = sys.argv[2]


def deep_merge(base, override):
    for key, val in override.items():
        if key in base and isinstance(base[key], dict) and isinstance(val, dict):
            deep_merge(base[key], val)
        else:
            base[key] = val


with open(proxy_path, "r") as f:
    proxy = json.load(f)

with open(project_path, "r") as f:
    project = json.load(f)

offsets = proxy.get("offsets") or {}
if not offsets:
    keys = list(proxy.keys())[:15]
    print(
        "      sync: warning — proxy project has no offsets "
        f"(if do_autosync is false in preset or has_accurate_timestamps is set in .gcsv, autosync is skipped; top keys: {keys})",
        file=sys.stderr,
    )
    sys.exit(0)

project["offsets"] = offsets

# Gyroflow GUI expects synchronization settings alongside offsets (same as a full CLI export).
psync = proxy.get("synchronization")
if isinstance(psync, dict) and psync:
    tgt = project.setdefault("synchronization", {})
    if isinstance(tgt, dict):
        deep_merge(tgt, psync)
    else:
        project["synchronization"] = dict(psync)

# Use the full gyro_source from the CLI export (same gcsv + lens + autosync as proxy).
# The Python DNG builder only fills a minimal stub; cherry-picking fields leaves out
# fields Gyroflow expects for sync UI / project_has_motion_data (file_metadata, IMU
# transforms, etc.). Keep the DNG project's filepath URL to the real .gcsv (and
# filepath_bookmark if the builder added one).
proxy_gyro = proxy.get("gyro_source") or {}
project_gyro = project.get("gyro_source") or {}
merged = dict(proxy_gyro)
for k in ("filepath", "filepath_bookmark"):
    if k in project_gyro and project_gyro[k]:
        merged[k] = project_gyro[k]
project["gyro_source"] = merged

project["version"] = 3
project.setdefault("videofile_bookmark", "")
out = project.get("output")
if isinstance(out, dict):
    out.setdefault("output_folder_bookmark", "")
    out.setdefault("pixel_format", "")

with open(project_path, "w") as f:
    json.dump(project, f, indent=2)

try:
    sz = os.path.getsize(project_path)
except OSError:
    sz = 0

fm = merged.get("file_metadata")
has_fm = (isinstance(fm, str) and fm.strip()) or (isinstance(fm, dict) and fm)
extra = " + full gyro_source from CLI" + (" (incl. file_metadata)" if has_fm else "")
print(
    f"      sync: merged {len(offsets)} offset(s) + synchronization{extra} into project ({sz} bytes)"
)
PYEOF

    local merge_rc=$?

    # ── e) Clean up ──────────────────────────────────────────────────
    rm -f "$tmp_proxy" "$proxy_project" "$tmp_preset"
    [[ "$gcsv_for_proxy" != "$gcsv_path" ]] && rm -f "$gcsv_for_proxy"

    return $merge_rc
}

# ── Build the list of footage items ──────────────────────────────────
footage_items=()
shopt -s nullglob

for entry in "$VIDEO_FOLDER"/*; do
    if [[ -d "$entry" ]]; then
        if is_image_sequence_dir "$entry"; then
            footage_items+=("$entry")
        fi
    elif [[ -f "$entry" ]]; then
        ext="${entry##*.}"
        ext_lower="$(echo "$ext" | tr '[:upper:]' '[:lower:]')"
        if [[ "$ext_lower" =~ ^($VIDEO_EXTENSIONS)$ ]]; then
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
            else
                echo "WARN  $stem — project built but sync failed (usable, sync manually in GUI)"
            fi
            success=$((success + 1))
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

        # Same sync overrides as DNG proxy: do_autosync + exactly AUTO_SYNC_POINTS
        # sync points (sanitized preset may omit or zero max_sync_points).
        vid_sync_params_json=$(gyroflow_sync_params_json_from_preset "$tmp_preset")

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

        echo "      output:  $project_file"
        echo ""
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
            # Stream new Gyroflow output in real time
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

        # Print any remaining output not yet shown
        new_lines=$(wc -l < "$gyro_output" | tr -d ' ')
        if [[ $new_lines -gt $gyro_lines_shown ]]; then
            tail -n +$((gyro_lines_shown + 1)) "$gyro_output" | sed 's/^/      /'
        fi
        rm -f "$gyro_output"

        sleep 2
        gyroflow_settings_end_restore
        rm -f "$tmp_preset"

        if $gyro_timed_out; then
            echo "FAIL  $stem — Gyroflow timed out after ${GYROFLOW_TIMEOUT}s (killed)"
            failed=$((failed + 1))
        elif [[ $gyro_rc -eq 0 ]]; then
            # Prefer next to source; else next to -p output in .gyroflow_sync/
            default_location="$(dirname "$item")/$stem.gyroflow"
            sync_sidecar="$sync_dir/$stem.gyroflow"
            found=""
            if [[ -f "$default_location" ]]; then
                found="$default_location"
            elif [[ -f "$sync_sidecar" ]]; then
                found="$sync_sidecar"
            fi
            if [[ -n "$found" && "$found" != "$project_file" ]]; then
                mv "$found" "$project_file"
            fi

            if [[ -f "$project_file" ]]; then
                echo "  OK  $stem"
                success=$((success + 1))
            else
                echo "WARN  $stem — Gyroflow exited OK but project file not found"
                echo "      Check if Gyroflow wrote it to an unexpected location."
                failed=$((failed + 1))
            fi
        else
            echo "FAIL  $stem — Gyroflow exited with error code $gyro_rc"
            failed=$((failed + 1))
        fi
    fi

    echo ""
done

# ── Summary ──────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Done.  Total: $total  |  OK: $success  |  Skipped: $skipped  |  Failed: $failed"
echo "Project files → $PROJECT_FOLDER"