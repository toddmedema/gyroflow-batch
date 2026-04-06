# AGENTS.md — gyroflow-batch

## What this project is

A single Bash script (`gyroflow_export_projects.sh`) that batch-generates
[Gyroflow](https://gyroflow.xyz/) `.gyroflow` project files from a folder of
footage. It does **not** render/stabilize video — it only exports project files
that can later be opened in Gyroflow or processed by its CLI.

For each piece of footage the script automatically matches three companion
files by filename conventions, applies a shared preset, and invokes the
[Gyroflow CLI](https://docs.gyroflow.xyz/app/advanced-usage/command-line-cli).

## File layout

```
gyroflow-batch/
├── AGENTS.md                        ← this file
└── gyroflow_export_projects.sh      ← the entire codebase (one Bash script)
```

No dependencies to install, no build step, no tests.

## How the script works (pipeline per footage item)

```
footage item (video file or DNG sequence dir)
  │
  ├── 1. Match a .gcsv motion file   (by stem name, case-insensitive)
  ├── 2. Extract focal length         (regex: _<N>mm or -<N>mm in filename)
  ├── 3. Find lens profile .json      (filename contains <N>mm in LENS_FOLDER)
  ├── 4. Skip if .gyroflow already exists in PROJECT_FOLDER
  │
  ├── 5a. DNG sequences → build .gyroflow JSON directly with python3
  │       → auto-sync via ffmpeg proxy (see below)
  │
  └── 5b. Video files → run Gyroflow CLI (auto-synced) → move to PROJECT_FOLDER
```

**Why DNG sequences bypass the CLI**: Gyroflow's CLI (v1.6.x) deadlocks on
DNG image sequences. Its `cli.rs` creates a `QCoreApplication` which cannot
drive the async image-sequence loader — the `processing_done` callback never
fires and `qApp->quit()` is never reached. The Python builder constructs the
same project JSON that `export_gyroflow_data()` would produce, using the same
root `version` (3 for Gyroflow 1.6.x GUI) as current app exports.

### Invocation

```bash
./gyroflow_export_projects.sh \
    <PROJECT_FOLDER> \
    <MOTION_FOLDER> \
    <VIDEO_FOLDER> \
    <LENS_FOLDER> \
    <PROJECT_DEFAULTS> \
    [--fps <FPS>]
```

| Argument           | Description |
|--------------------|-------------|
| `PROJECT_FOLDER`   | Output dir for `.gyroflow` project files (created if missing) |
| `MOTION_FOLDER`    | Dir containing `.gcsv` gyro/motion data files |
| `VIDEO_FOLDER`     | Dir containing video files and/or subdirectories of DNG sequences |
| `LENS_FOLDER`      | Dir containing lens profile `.json` files with focal length in name |
| `PROJECT_DEFAULTS` | Path to a `.gyroflow` preset file applied to every export |
| `--fps <FPS>`      | Frame rate for DNG image sequences (required if any are present) |

## Key conventions and matching rules

- **Stem matching**: A video `scene_25mm_001.mp4` looks for `scene_25mm_001.gcsv`
  in `MOTION_FOLDER`. For DNG sequences, the directory name is the stem.
- **Focal length**: Extracted from the stem via regex `[_-]([0-9]+)mm([_.-]|$)`.
  Examples: `_25mm`, `_114mm`, `-50mm`.
- **Lens profile**: First `.json` in `LENS_FOLDER` whose filename matches
  `(^|[_-])<N>mm([_.-]|$)`.
- **Idempotent**: Skips any item where `PROJECT_FOLDER/<stem>.gyroflow` exists.
- **Supported video extensions**: `mp4`, `mov`, `avi`, `mkv`, `mxf`, `braw`,
  `r3d`, `insv` (case-insensitive).
- **DNG sequences**: A subdirectory of `VIDEO_FOLDER` containing at least one
  `.dng` file. Project files are built directly with an embedded Python script
  (no Gyroflow CLI involved), then automatically synced via an ffmpeg proxy
  `.mp4` under `PROJECT_FOLDER/.gyroflow_sync/`. The Python builder reads the first DNG's TIFF header for
  dimensions, counts frames, reads the lens profile JSON and .gcsv header,
  merges the preset, and writes the project JSON. The `videofile` URL in the
  output points to the original first DNG in the sequence directory.

## Hardcoded configuration (top of script)

| Variable           | Default | Notes |
|--------------------|---------|-------|
| `GYROFLOW`         | `/Applications/Gyroflow.app/Contents/MacOS/gyroflow` | macOS path; change for other OS |
| `EXPORT_MODE`      | `2` | 1=default, 2=with gyro data, 3=processed gyro, 4=video+project |
| `VIDEO_EXTENSIONS` | `mp4\|mov\|avi\|mkv\|mxf\|braw\|r3d\|insv` | Pipe-delimited regex alternation |
| `GYROFLOW_TIMEOUT` | `300` | Max seconds per Gyroflow invocation before killing |

## Dependencies

| Dependency | Required | Purpose |
|------------|----------|---------|
| `bash` (3.2+) | Yes | Script runtime; avoids `${var,,}` for macOS compat |
| `python3` | Yes | Builds DNG sequence project files; merges fps into presets |
| Gyroflow app | Yes | CLI for video files and DNG proxy sync |
| `ffmpeg` | Yes | Creates proxy .mp4 from DNG sequences for auto-sync |
| Standard Unix tools | Yes | `find`, `sort`, `head`, `sed`, `mktemp`, `tr`, `wc`, `basename`, `dirname` |

## Gyroflow CLI invocation (video files)

Official reference: [Command Line (CLI)](https://docs.gyroflow.xyz/app/advanced-usage/command-line-cli).

For **video files** (not DNG sequences), the script invokes the Gyroflow CLI:

```bash
gyroflow <video_file> <lens.json> \
    -g <motion.gcsv> \
    --preset <defaults.gyroflow> \
    --export-project <EXPORT_MODE>
```

After Gyroflow writes the project file (next to the source by default), the
script moves it into `PROJECT_FOLDER`. Video files are **auto-synced by
default** — the Gyroflow CLI has `auto_sync_points: true` in its
`setup_defaults()`, so the exported project includes computed sync offsets.

## DNG sequence project builder (Python)

For **DNG image sequences**, the script constructs the `.gyroflow` project
JSON directly via an embedded Python script (`build_dng_project()`), bypassing
the Gyroflow CLI entirely. It:

1. Parses the first DNG's TIFF IFD0 header for image width/height
2. Counts `.dng` files and extracts the sequence start frame number
3. Reads the lens profile `.json` as `calibration_data`
4. Reads the `.gcsv` header for IMU orientation / detected source
5. Deep-merges the preset `.gyroflow` into the project, then restores
   video-specific fields so the preset can't clobber them
6. Writes the project JSON with root `version` 3 (matches 1.6.x GUI exports)

## DNG proxy sync (`sync_dng_project`)

After building the DNG project file, the script automatically syncs it by
encoding an ffmpeg proxy and running Gyroflow's CLI on it. The proxy video,
sanitized preset copy, Gyroflow log capture, and Gyroflow `settings.json` backup
for the run all live under **`PROJECT_FOLDER/.gyroflow_sync/`** (not `/tmp`), so
bookmarks and export paths stay consistent with where files are written.

The preset is sanitized before the CLI run: root keys **`output`**, **`render_queue`**
/ **`renderQueue`**, **`recent_files`**, any **`*_bookmark`** key, known path-field
keys, and path-like strings (including **`/tmp/`** and **`/var/folders/`** on
macOS) are removed so a dirty `PROJECT_DEFAULTS` cannot steer exports to old
folders.

The Gyroflow invocation passes **`-p`** JSON with **`output_path`**, **`output_folder`**, and
**`output_filename`** derived from the proxy `.mp4` path so the export target is
the same directory as the proxy inside `.gyroflow_sync/`.

```
DNG sequence dir
  │
  ├── 1. Parse DNG filename numbering (prefix, zero-padding, start number)
  ├── 2. ffmpeg: encode DNG sequence → proxy .mp4 in PROJECT_FOLDER/.gyroflow_sync/
  │      (ultrafast preset, CRF 30 — quality doesn't matter for sync; full-res,
  │      cropped to even dimensions for yuv420p)
  ├── 3. Create sanitized preset (strip stale paths, output, queues, bookmarks)
  ├── 4. Gyroflow CLI: load proxy .mp4 → auto-sync → export project
  │      (auto_sync_points: true by default in setup_defaults())
  ├── 5. Python: extract "offsets" from proxy project → merge into DNG project
  └── 6. Clean up proxy .mp4, proxy .gyroflow, and sanitized preset in .gyroflow_sync/
       (the directory itself is left in place)
```

**Why this works**: Sync offsets are time-based and resolution-independent, so
offsets computed from the proxy encode are identical to what you'd get from the
full-resolution DNGs. The Gyroflow CLI works fine on regular .mp4 files — it
only deadlocks on DNG sequences directly.

Sync failure is a warning, not a hard error — the DNG project file is still
valid and can be synced manually in the Gyroflow GUI.

## Common modification points

- **Add video formats**: Append to `VIDEO_EXTENSIONS`.
- **Change Gyroflow path**: Edit `GYROFLOW`.
- **Change export mode**: Edit `EXPORT_MODE` (applies to video files only).
- **Change focal-length regex**: Edit `extract_focal_length()`.
- **Change lens matching logic**: Edit `find_lens_profile()`.
- **Change DNG project schema**: Edit the Python heredoc in `build_dng_project()`.
- **Change proxy sync settings**: Edit `sync_dng_project()` (ffmpeg flags, proxy resolution, offset merge logic).

## Portability notes

- Uses `tr '[:upper:]' '[:lower:]'` instead of `${var,,}` for bash 3.2
  compatibility (macOS ships bash 3.2).
- The `GYROFLOW` path is macOS-specific; Linux/Windows users must change it.
- `set -euo pipefail` is active — the script exits on any unhandled error.
