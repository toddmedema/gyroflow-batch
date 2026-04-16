"""
Shared helpers for gyroflow_export_projects.sh (DNG discovery, JSON merge).

DNG ordering: ``canonical_dng_filenames`` must stay in sync with any bash logic
that picks the “first” frame for ffmpeg — use this module as the single source.
"""

from __future__ import annotations

import json
import os
import re
from typing import Any, Dict, Iterable, List, MutableMapping, Tuple


def file_url_from_local_path(local_path: str) -> str:
    """
    Return a ``file://`` URL for *local_path* (absolute path after ``abspath``).

    Encode each ``%`` as ``%25`` so Qt's URL layer does not interpret sequences
    like ``%06d`` (printf image patterns) or ``%`` in real pathnames as
    percent-encoded bytes, which breaks loading projects in Gyroflow.
    """
    p = os.path.abspath(local_path)
    enc = p.replace("%", "%25")
    return "file://" + enc


def canonical_dng_filenames(seq_dir: str) -> List[str]:
    """
    Basenames of all *.dng files in seq_dir (case-insensitive), sorted
    lexicographically. Matches ``sort`` on those basenames (e.g. ``find … | sort``).
    """
    try:
        names = [f for f in os.listdir(seq_dir) if f.lower().endswith(".dng")]
    except OSError:
        return []
    return sorted(names)


def dng_sequence_videofile_url(seq_dir: str) -> Tuple[str, int]:
    """
    Build the ``file://`` URL Gyroflow expects for a DNG image sequence.

    The GUI resets ``image_sequence_fps`` and prompts for FPS when the path
    is a literal first-frame file (no ``%0`` in the name). Exporting a
    ``prefix_%04d.dng``-style pattern matches Gyroflow's own project files and
    avoids that dialog. The ``%`` in that pattern is written as ``%25`` in the
    stored URL so Qt does not corrupt the path. Returns
    ``(videofile_url, image_sequence_start)``.
    """
    names = canonical_dng_filenames(seq_dir)
    if not names:
        raise ValueError(f"no .dng files in {seq_dir!r}")
    first = names[0]
    folder = os.path.abspath(seq_dir)
    m = re.match(r"^(.*?)(\d+)\.([dD][nN][gG])$", first)
    if not m:
        literal = os.path.join(folder, first)
        return file_url_from_local_path(literal), 0
    prefix, num_str, ext = m.group(1), m.group(2), m.group(3)
    pad = len(num_str)
    seq_start = int(num_str)
    pattern = f"{prefix}%0{pad}d.{ext}"
    return file_url_from_local_path(os.path.join(folder, pattern)), seq_start


def dng_sequence_metadata(seq_dir: str) -> Dict[str, Any]:
    """
    Metadata for proxy sync / validation: first file path, frame count, literal
    extension (``.dng`` vs ``.DNG``) for ffmpeg patterns on case-sensitive FS.
    """
    seq_dir = os.path.abspath(seq_dir)
    names = canonical_dng_filenames(seq_dir)
    if not names:
        raise ValueError(f"no .dng files in {seq_dir!r}")
    first_name = names[0]
    first_path = os.path.join(seq_dir, first_name)
    _, ext = os.path.splitext(first_name)
    return {
        "first_path": first_path,
        "first_basename": first_name,
        "count": len(names),
        "ext": ext if ext else ".dng",
    }


def lens_profile_json_looks_valid(obj: Any) -> bool:
    """
    Rough check that JSON matches Gyroflow's LensProfile expectations.
    If this fails, import_gyroflow_data may skip loading calibration_data silently.
    """
    if not isinstance(obj, dict):
        return False
    fp = obj.get("fisheye_params")
    if not isinstance(fp, dict):
        return False
    cm = fp.get("camera_matrix")
    if not isinstance(cm, list) or len(cm) == 0:
        return False
    cd = obj.get("calib_dimension")
    if not isinstance(cd, dict):
        return False
    w, h = cd.get("w"), cd.get("h")
    if not isinstance(w, (int, float)) or not isinstance(h, (int, float)):
        return False
    if w <= 0 or h <= 0:
        return False
    cv = obj.get("calibrator_version")
    if not isinstance(cv, str) or not cv.strip():
        return False
    return True


def deep_merge(base: MutableMapping[str, Any], override: Dict[str, Any]) -> None:
    """Recursively merge override dict into base dict (mutates base)."""
    for key, val in override.items():
        if (
            key in base
            and isinstance(base[key], dict)
            and isinstance(val, dict)
        ):
            deep_merge(base[key], val)  # type: ignore[arg-type]
        else:
            base[key] = val


def normalize_gyro_source_after_preset_merge(gyro_source: Any) -> None:
    """
    Gyroflow presets often store ``null`` for unused gyro correction fields.
    For projects that load motion from an external ``.gcsv``, those nulls can
    prevent IMU data from loading (arrays are expected). Preset deep-merge runs
    after the DNG builder fills ``gyro_source``, so we repair after merge.
    """
    if not isinstance(gyro_source, dict):
        return
    array_defaults = (
        ("rotation", [0.0, 0.0, 0.0]),
        ("acc_rotation", [0.0, 0.0, 0.0]),
        ("gyro_bias", [0.0, 0.0, 0.0]),
    )
    for key, default in array_defaults:
        if gyro_source.get(key) is None:
            gyro_source[key] = list(default)
    for key, default in (("lpf", 0.0), ("mf", 0.0)):
        if gyro_source.get(key) is None:
            gyro_source[key] = default


def _parse_offsets_dict(offsets: Any) -> Dict[str, float]:
    """Coerce Gyroflow ``offsets`` to string keys and float values; skip bad entries."""
    if not isinstance(offsets, dict):
        return {}
    out: Dict[str, float] = {}
    for k, v in offsets.items():
        sk = k if isinstance(k, str) else str(k)
        try:
            out[sk] = float(v)
        except (TypeError, ValueError):
            continue
    return out


def _offset_keys_sorted(keys: Iterable[str]) -> List[str]:
    def sort_key(key: str) -> Tuple[int, Any]:
        try:
            return (0, int(key))
        except ValueError:
            return (1, key)

    return sorted(keys, key=sort_key)


def trim_offsets_by_max_abs_ms(offsets: Any, max_abs_offset_ms: float) -> Dict[str, float]:
    """
    Drop sync points whose offset magnitude exceeds ``max_abs_offset_ms``.
    **Project ``offsets`` values are in milliseconds** (Gyroflow convention).

    Among points still in range, keep only the **first and last** by sync-point
    key order (integer keys numerically, then other keys lexicographically).
    If exactly one point remains, that single entry is returned (same as first
    and last). If none remain, returns ``{}``.
    """
    if not isinstance(offsets, dict) or max_abs_offset_ms < 0:
        return {}

    limit_ms = float(max_abs_offset_ms)
    parsed = _parse_offsets_dict(offsets)
    filtered = {
        k: v for k, v in parsed.items() if -limit_ms <= v <= limit_ms
    }
    if not filtered:
        return {}
    keys_sorted = _offset_keys_sorted(filtered.keys())
    if not keys_sorted:
        return {}
    first, last = keys_sorted[0], keys_sorted[-1]
    return {first: filtered[first], last: filtered[last]}


def gyroflow_offsets_meet_minimum(path: str, minimum: int = 1) -> bool:
    """
    Return True if ``path`` is readable JSON with ``offsets`` a dict containing
    at least ``minimum`` entries. Used after apply-offset-policy to ensure the
    proxy export actually has usable sync points (policy can succeed with zero).
    """
    if minimum < 1:
        return False
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return False
    if not isinstance(data, dict):
        return False
    off = data.get("offsets")
    if not isinstance(off, dict):
        return False
    return len(off) >= minimum


def apply_sync_offset_policy_to_gyroflow_file(path: str, max_abs_offset_ms: float) -> bool:
    """
    Load a ``.gyroflow`` JSON, replace ``offsets`` with
    ``trim_offsets_by_max_abs_ms``, and write back atomically.
    ``max_abs_offset_ms`` removes autosync points with ``|offset|`` greater
    than this (values in the file are ms), then keeps only the first/last
    remaining sync point (or a single survivor). The result may have no sync points.
    Returns ``True`` on success, ``False`` on load/save error.
    """
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return False
    if not isinstance(data, dict):
        return False

    new_offsets = trim_offsets_by_max_abs_ms(data.get("offsets"), max_abs_offset_ms)
    data["offsets"] = new_offsets
    tmp = path + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False
    return True


def merge_proxy_offsets_main(proxy_path: str, project_path: str) -> None:
    """CLI entry for merging proxy Gyroflow export into DNG project (offsets, sync)."""
    import sys

    with open(proxy_path, "r") as f:
        proxy = json.load(f)

    with open(project_path, "r") as f:
        project = json.load(f)

    raw_off = proxy.get("offsets")
    offsets = raw_off if isinstance(raw_off, dict) else {}
    if not offsets:
        keys = list(proxy.keys())[:15]
        print(
            "      sync: warning — proxy project has no sync offsets "
            f"(trimmed or autosync skipped; do_autosync/has_accurate_timestamps may apply; top keys: {keys})",
            file=sys.stderr,
        )

    project["offsets"] = offsets

    psync = proxy.get("synchronization")
    if isinstance(psync, dict) and psync:
        tgt = project.setdefault("synchronization", {})
        if isinstance(tgt, dict):
            deep_merge(tgt, psync)
        else:
            project["synchronization"] = dict(psync)

    # Merge only ``file_metadata`` from the proxy Gyroflow export: it holds the
    # parsed IMU/quaternion payload Gyroflow expects (base91 CBOR or thin JSON).
    # Without it, ``project_has_motion_data`` is false and import can fail to load
    # motion for image-sequence + sidecar .gcsv projects. Keep the DNG project's
    # ``filepath`` (real .gcsv) and IMU transform fields—do not copy other proxy
    # ``gyro_source`` keys (CLI exports carry nulls/wrong paths).
    proxy_gs = proxy.get("gyro_source")
    tgt_gs = project.get("gyro_source")
    if isinstance(proxy_gs, dict) and isinstance(tgt_gs, dict):
        fm = proxy_gs.get("file_metadata")
        if fm not in (None, "", {}):
            tgt_gs["file_metadata"] = fm

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

    has_fm = (
        isinstance(project.get("gyro_source"), dict)
        and project["gyro_source"].get("file_metadata") not in (None, "", {})
    )
    print(
        f"      sync: merged {len(offsets)} offset(s) + synchronization into project "
        f"({'with' if has_fm else 'without'} file_metadata; {sz} bytes)"
    )


if __name__ == "__main__":
    import sys

    if len(sys.argv) >= 2 and sys.argv[1] == "offsets-min":
        if len(sys.argv) != 4:
            print(
                "usage: gyroflow_batch_helpers.py offsets-min "
                "<path.gyroflow> <minimum_count>",
                file=sys.stderr,
            )
            sys.exit(2)
        ok = gyroflow_offsets_meet_minimum(sys.argv[2], int(sys.argv[3]))
        sys.exit(0 if ok else 1)

    if len(sys.argv) >= 2 and sys.argv[1] == "apply-offset-policy":
        if len(sys.argv) != 4:
            print(
                "usage: gyroflow_batch_helpers.py apply-offset-policy "
                "<path.gyroflow> <max_abs_offset_ms>",
                file=sys.stderr,
            )
            sys.exit(2)
        ok = apply_sync_offset_policy_to_gyroflow_file(sys.argv[2], float(sys.argv[3]))
        sys.exit(0 if ok else 1)

    if len(sys.argv) != 3:
        print("usage: gyroflow_batch_helpers.py <proxy.gyroflow> <project.gyroflow>", file=sys.stderr)
        sys.exit(2)
    merge_proxy_offsets_main(sys.argv[1], sys.argv[2])
