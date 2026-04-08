# gyroflow-batch

**[Download the latest release](https://github.com/toddmedema/gyroflow-batch/releases/latest)**

Batch-generates [Gyroflow](https://gyroflow.xyz/) **`.gyroflow` project files** from a folder of footage, and optionally insert them directly into Davinci Resolve with the Gyroflow Fusion Plugin pre-wired.

For each clip or DNG-sequence folder, it matches `.gcsv` motion data, a lens profile, and a shared preset, then writes projects into your output folder.

## Requirements (macOS)

The workflow is written for **macOS** (default Gyroflow path is the `.app` bundle). On Linux or Windows, set `GYROFLOW` near the top of [`gyroflow_export_projects.sh`](gyroflow_export_projects.sh) to your CLI binary.

| Need | Why |
|------|-----|
| **Python 3** | Builds DNG sequence projects; merges FPS into presets (`gyroflow_batch_helpers.py` must sit next to the script) |
| **[Gyroflow](https://gyroflow.xyz/)** | CLI for video exports; proxy sync for DNG (see below) |
| **ffmpeg** | For DNG sequences only: Renders lightweight proxy `.mp4` from DNG sequences (Gyroflow CLI currently hangs on image sequences) |

No `pip install` for batch export. Optional: `pytest` for helper tests ([Tests](#tests)).

## Layout

| Path | Role |
|------|------|
| [`gyroflow_export_projects.sh`](gyroflow_export_projects.sh) | Main batch export |
| [`gyroflow_batch_helpers.py`](gyroflow_batch_helpers.py) | DNG ordering, JSON merge |
| [`video_extensions.txt`](video_extensions.txt) | Allowed video extensions (one per line); shared with Resolve helpers |
| [`RESOLVE_GYROFLOW.md`](RESOLVE_GYROFLOW.md) | Optional DaVinci Resolve Studio + Fusion Gyroflow OFX |
| [`resolve_gyroflow_timeline.py`](resolve_gyroflow_timeline.py) | Resolve automation |

## Usage

```bash
chmod +x gyroflow_export_projects.sh
./gyroflow_export_projects.sh \
  <PROJECT_FOLDER> \
  <MOTION_FOLDER> \
  <VIDEO_FOLDER> \
  <LENS_FOLDER> \
  <PROJECT_DEFAULTS> \
  [--fps <FPS>] [--force] [--max-offset-ms <MS>]
```

### Arguments

| Argument | Description |
|----------|-------------|
| `PROJECT_FOLDER` | Output dir for `<stem>.gyroflow` (created if missing) |
| `MOTION_FOLDER` | `.gcsv` motion files |
| `VIDEO_FOLDER` | Videos and/or **subfolders** containing `.dng` sequences |
| `LENS_FOLDER` | Lens `.json` files whose **names include** the focal length (e.g. `…_25mm_…`) |
| `PROJECT_DEFAULTS` | `.gyroflow` preset applied to every export |

### Flags

| Flag | Description |
|------|-------------|
| `--fps <FPS>` | **Required** if any DNG sequence folders exist under `VIDEO_FOLDER` |
| `--force` | Rebuild even when `<stem>.gyroflow` already exists |
| `--max-offset-ms <N>` | Remove autosync points whose **absolute offset (ms)** exceeds `N` (default **5000**). Gyroflow optical-flow `search_size` is always **5s** in this script. |

Example:

```bash
./gyroflow_export_projects.sh \
  ./projects ./motion ./videos ./lenses ./defaults.gyroflow --fps 24
```

CLI reference: [Gyroflow command-line (CLI)](https://docs.gyroflow.xyz/app/advanced-usage/command-line-cli).

## Matching

- **Stem**: `scene_25mm_001.mp4` → `scene_25mm_001.gcsv` in `MOTION_FOLDER` (case-insensitive). DNG sequences use the **folder name** as the stem.
- **Focal length**: `_<N>mm` or `-<N>mm` in the stem (e.g. `_25mm`, `-50mm`).
- **Lens**: First `.json` in `LENS_FOLDER` matching that `N` mm (word-boundary-style separators).
- **Skip**: Existing `PROJECT_FOLDER/<stem>.gyroflow` is skipped unless `--force`.
- **Formats**: Only extensions listed in [`video_extensions.txt`](video_extensions.txt).

## Video vs DNG

- **Video**: Gyroflow CLI export; project moved into `PROJECT_FOLDER`. Auto-sync applies where the CLI does.
- **DNG folders**: At least one `.dng` in a subfolder of `VIDEO_FOLDER`. Project JSON is built in Python (CLI is unreliable on DNG sequences). The script encodes a proxy under `PROJECT_FOLDER/.gyroflow_sync/`, runs CLI sync on it, and merges offsets into the DNG project. Sync failure still leaves a usable `.gyroflow` for manual sync in the GUI.

**Batch run:** close the Gyroflow GUI—the script swaps Application Support `settings.json` briefly; an open app can race that state. DNG proxy sync uses a **sanitized** copy of your preset (strips output paths, queues, bookmarks, and many path-like strings). Details and caveats: [`AGENTS.md`](AGENTS.md).

## Optional: DaVinci Resolve

**DaVinci Resolve Studio**: [`resolve_gyroflow_timeline.py`](resolve_gyroflow_timeline.py) and [`RESOLVE_GYROFLOW.md`](RESOLVE_GYROFLOW.md).

## Tests

```bash
python3 -m venv .venv
.venv/bin/pip install pytest
.venv/bin/pytest
```

More behavior and extension points: [`AGENTS.md`](AGENTS.md).
