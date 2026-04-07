# DaVinci Resolve + Gyroflow (batch stage 2)

After [`gyroflow_export_projects.sh`](gyroflow_export_projects.sh) writes `PROJECT_FOLDER/<stem>.gyroflow`, run [`resolve_gyroflow_timeline.py`](resolve_gyroflow_timeline.py) **inside DaVinci Resolve Studio** to import the same footage, build a timeline, and add the **Gyroflow OpenFX** node on each clip’s Fusion **composition** (MediaIn → Gyroflow → MediaOut) with **`ProjectPath`** set to the matching `.gyroflow` file.

## Prerequisites

- **DaVinci Resolve Studio** (scripting API).
- **Preferences → General → External scripting**: **Local** enabled.
- **Gyroflow OpenFX** installed (e.g. macOS: `/Library/OFX/Plugins`) and enabled under **Preferences → Video plugins**.
- Resolve running with a project open (or pass `--project-name`).

## Environment (macOS)

```bash
export RESOLVE_SCRIPT_API="/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting"
export RESOLVE_SCRIPT_LIB="/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fusionscript.so"
export PYTHONPATH="$RESOLVE_SCRIPT_API/Modules:$PYTHONPATH"
```

Linux and Windows paths are documented in Blackmagic’s **Developer/Scripting** README.

## Usage

```bash
python3 resolve_gyroflow_timeline.py /path/to/VIDEO_FOLDER /path/to/PROJECT_FOLDER
```

Optional flags:

| Flag | Meaning |
|------|--------|
| `--project-name NAME` | Load or create this Resolve project |
| `--timeline-name NAME` | New timeline name (default: `Gyroflow batch`) |
| `--dry-run` | List stem / media / `.gyroflow` pairs only (no Resolve calls) |
| `--export-mapping FILE.json` | Write the same mapping as JSON |
| `--skip-fusion` | Import media + timeline only (no Fusion automation) |
| `--fusion-comp-index N` | 1-based Fusion comp index (default: 1) |

## Workflow

1. Run `./gyroflow_export_projects.sh` with the same `VIDEO_FOLDER` and `PROJECT_FOLDER` you use here.
2. Start Resolve, open or create a project.
3. Run the Python command above (external script with env set, or add the script to Resolve’s script menu).

## Troubleshooting

- **`DaVinciResolveScript` import error**: Fix `PYTHONPATH` to include `…/Developer/Scripting/Modules`.
- **Missing `.gyroflow`**: The script requires `PROJECT_FOLDER/<stem>.gyroflow` for every stem found under `VIDEO_FOLDER` (same rules as the bash script: video extensions + DNG sequence folders).
- **Gyroflow OFX ID**: The script defaults to `ofx.xyz.gyroflow` and scans `Fusion.GetRegList()` if needed. If a future Gyroflow build changes the ID, update [`resolve_gyroflow_timeline.py`](resolve_gyroflow_timeline.py) or the smoke test.
- **Fusion wiring warnings**: If **MediaIn ↔ MediaOut** connection names differ in your build, check the Fusion comp manually; the script tries several common input names.
- **Frame rate**: Align Resolve **timeline / project frame rate** with the `.gyroflow` / source footage to avoid Gyroflow “timeline FPS mismatch” warnings ([Gyroflow Resolve docs](https://docs.gyroflow.xyz/app/video-editor-plugins/davinci-resolve-openfx)).
- **BRAW / R3D / INSV / DNG**: Resolve must import the same media paths Gyroflow expects. For DNG folders, the batch script and the `.gyroflow` `videofile` URL must stay consistent with what you import.

## Smoke test

`resolve_gyroflow_strategy_a_smoke_test.py` checks **AddTool** + **`ProjectPath`** on the first clip of the current timeline. Optional argument: path to a `.gyroflow` file.

```bash
python3 resolve_gyroflow_strategy_a_smoke_test.py /path/to/test.gyroflow
```

There is no CI for Resolve; run this manually after installing or upgrading Gyroflow OFX.
