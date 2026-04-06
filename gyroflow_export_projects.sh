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

# ── Parse arguments ──────────────────────────────────────────────────
if [[ $# -lt 5 ]]; then
    cat <<'EOF'
Usage:
  gyroflow_export_projects.sh \
      <PROJECT_FOLDER> <MOTION_FOLDER> <VIDEO_FOLDER> \
      <LENS_FOLDER> <PROJECT_DEFAULTS> [--fps <FPS>]

  --fps  Frame rate for DNG image sequences (required when sequences exist)
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
while [[ $# -gt 0 ]]; do
    case "$1" in
        --fps)
            SEQ_FPS="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ── Validate paths ───────────────────────────────────────────────────
HAVE_GYROFLOW=true
if [[ ! -x "$GYROFLOW" ]]; then
    echo "Warning: Gyroflow not found at $GYROFLOW"
    echo "         Video files will fail; DNG sequences still work (built with Python)."
    HAVE_GYROFLOW=false
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

# ── Construct project JSON (matches Gyroflow v1.6 schema) ───────────
project = {
    "title": "Gyroflow data file",
    "version": 4,
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

# ── Write output ─────────────────────────────────────────────────────
with open(output_path, "w") as f:
    json.dump(project, f, indent=2)

print(f"Wrote {output_path} ({dng_count} frames, {width}x{height}, {fps} fps)")
PYEOF
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
        echo "SKIP  $stem — project file already exists"
        skipped=$((skipped + 1))
        echo ""
        continue
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
            echo "  OK  $stem"
            success=$((success + 1))
        else
            echo "FAIL  $stem — Python project builder failed"
            failed=$((failed + 1))
        fi
    else
        # ── 5b. Video files: use the Gyroflow CLI ────────────────────
        if ! $HAVE_GYROFLOW; then
            echo "FAIL  $stem — Gyroflow binary not found; cannot process video files"
            failed=$((failed + 1))
            echo ""
            continue
        fi
        active_preset="$PROJECT_DEFAULTS"

        cmd=(
            "$GYROFLOW"
            "$item"                          # video file
            "$lens_profile"                  # lens profile .json (positional)
            -g "$motion_file"                # gyro / motion data
            --preset "$active_preset"        # settings defaults
            --export-project "$EXPORT_MODE"  # export project file, don't render
        )

        echo "      output:  $project_file"
        echo ""
        echo "      cmd:     ${cmd[*]}"
        echo ""

        gyro_output=$(mktemp /tmp/gyroflow_out_XXXXXX)
        "${cmd[@]}" > "$gyro_output" 2>&1 &
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

        if $gyro_timed_out; then
            echo "FAIL  $stem — Gyroflow timed out after ${GYROFLOW_TIMEOUT}s (killed)"
            failed=$((failed + 1))
        elif [[ $gyro_rc -eq 0 ]]; then
            # Gyroflow writes the project file next to the source by default.
            default_location="$(dirname "$item")/$stem.gyroflow"
            if [[ -f "$default_location" && "$default_location" != "$project_file" ]]; then
                mv "$default_location" "$project_file"
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