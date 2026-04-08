#!/usr/bin/env python3
"""
DaVinci Resolve Studio: import footage paired with .gyroflow projects (same
stems as gyroflow_export_projects.sh), build a timeline, then per clip add the
Gyroflow OpenFX node in the clip Fusion comp (MediaIn -> Gyroflow -> MediaOut)
and set ProjectPath.

Prerequisites
-------------
- DaVinci Resolve Studio with Local scripting enabled.
- Gyroflow OpenFX installed and enabled in Resolve.
- Run while Resolve is running. Environment (macOS example):

  export RESOLVE_SCRIPT_API="/Library/Application Support/Blackmagic Design/DaVinci Resolve/Developer/Scripting"
  export RESOLVE_SCRIPT_LIB="/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/Libraries/Fusion/fusionscript.so"
  export PYTHONPATH="$RESOLVE_SCRIPT_API/Modules:$PYTHONPATH"

  Linux/Windows: see Blackmagic README in the Developer/Scripting bundle.

Typical workflow
----------------
1. Run ./gyroflow_export_projects.sh ... to generate PROJECT_FOLDER/<stem>.gyroflow
2. Run this script with the same VIDEO_FOLDER and PROJECT_FOLDER.

See RESOLVE_GYROFLOW.md for troubleshooting.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

# --- Same footage discovery rules as gyroflow_export_projects.sh (video_extensions.txt) ---


def _load_video_extensions() -> frozenset[str]:
    root = Path(__file__).resolve().parent
    path = root / "video_extensions.txt"
    exts: List[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "#" in line:
            line = line.split("#", 1)[0].strip()
        if line:
            exts.append(line.lower())
    return frozenset(exts)


VIDEO_EXTENSIONS = _load_video_extensions()

DEFAULT_GYROFLOW_OFX_ID = "ofx.xyz.gyroflow"

# Same prefix as gyroflow_export_projects.sh; Gyroflow Batch app parses stdout.
_UI_PROGRESS_PREFIX = "GYROFLOW_BATCH_PROGRESS "


def _emit_ui_progress(current: int, total: int) -> None:
    """Line-oriented progress for Swift UI (flush so a piped Process updates live)."""
    if total <= 0 or current <= 0:
        return
    print(f"{_UI_PROGRESS_PREFIX}{current} {total}", flush=True)

LogFn = Callable[[str], None]


def _log_default(msg: str) -> None:
    print(msg, file=sys.stderr)


def is_image_sequence_dir(path: str) -> bool:
    if not os.path.isdir(path):
        return False
    try:
        for name in os.listdir(path):
            if name.lower().endswith(".dng"):
                return True
    except OSError:
        return False
    return False


def stem_from_media_path(path: str) -> str:
    """Stem = basename without extension (files) or directory name (DNG folder)."""
    path = os.path.abspath(path)
    if os.path.isdir(path):
        return os.path.basename(path.rstrip(os.sep))
    base = os.path.basename(path)
    if "." in base:
        return os.path.splitext(base)[0]
    return base


def enumerate_footage_items(video_folder: str) -> List[Tuple[str, str, bool]]:
    """
    Returns list of (stem, absolute_media_path, is_dng_sequence_dir), in arbitrary
    directory iteration order (caller should sort by stem).
    """
    out: List[Tuple[str, str, bool]] = []
    video_folder = os.path.abspath(video_folder)
    try:
        entries = sorted(os.listdir(video_folder))
    except OSError as e:
        raise RuntimeError(f"Cannot read VIDEO_FOLDER {video_folder!r}: {e}") from e
    for name in entries:
        full = os.path.join(video_folder, name)
        if os.path.isdir(full):
            if is_image_sequence_dir(full):
                out.append((name, full, True))
        elif os.path.isfile(full):
            ext = os.path.splitext(name)[1].lstrip(".").lower()
            if ext in VIDEO_EXTENSIONS:
                out.append((stem_from_media_path(full), full, False))
    return out


def build_stem_pairs(
    video_folder: str,
    project_folder: str,
    *,
    require_gyroflow: bool = True,
    log: LogFn = _log_default,
) -> List[Dict[str, Any]]:
    """
    Sorted list of dicts: stem, media_path, gyroflow_path, is_sequence.
    When a stem has no matching ``.gyroflow`` file, the item is skipped after a
    warning. If ``require_gyroflow`` is True and no pairs remain (every stem
    was missing a project), raises ``FileNotFoundError`` with a detail message.
    When ``require_gyroflow`` is False, entries without a project file are still
    listed but ``gyroflow_path`` may be None; such entries are dropped unless
    they have a project path.
    """
    project_folder = os.path.abspath(project_folder)
    items = enumerate_footage_items(video_folder)
    items.sort(key=lambda t: t[0].lower())
    pairs: List[Dict[str, Any]] = []
    missing: List[str] = []
    for stem, media_path, is_seq in items:
        gf = os.path.join(project_folder, stem + ".gyroflow")
        if not os.path.isfile(gf):
            missing.append(stem)
            log(f"WARN: no project file for stem {stem!r}: expected {gf}")
            if require_gyroflow:
                continue
        pairs.append(
            {
                "stem": stem,
                "media_path": os.path.abspath(media_path),
                "gyroflow_path": os.path.abspath(gf) if os.path.isfile(gf) else None,
                "is_sequence": is_seq,
            }
        )
    # Drop entries with no gyroflow when not requiring
    if not require_gyroflow:
        pairs = [p for p in pairs if p["gyroflow_path"]]
    if require_gyroflow and not pairs:
        detail = (
            f"Missing .gyroflow for stem(s): {', '.join(missing[:20])}"
            + (" ..." if len(missing) > 20 else "")
            if missing
            else "no footage items with matching projects"
        )
        raise FileNotFoundError(detail)
    return pairs


# --- DaVinci Resolve connection -------------------------------------------------


def ensure_project(resolve, project_name: Optional[str], log: LogFn = _log_default):
    """
    If project_name is set, LoadProject or CreateProject; else require a current project.
    """
    pm = resolve.GetProjectManager()
    if not project_name:
        p = pm.GetCurrentProject()
        if not p:
            raise RuntimeError(
                "No project is open in Resolve. Open a project or pass --project-name."
            )
        return p
    p = pm.LoadProject(project_name)
    if p:
        return p
    p = pm.CreateProject(project_name)
    if p:
        log(f"INFO: created project {project_name!r}")
        return p
    p = pm.LoadProject(project_name)
    if p:
        return p
    raise RuntimeError(
        f"Could not load or create project {project_name!r} (name may already exist)."
    )


def _parse_timeline_fps(project) -> float:
    """Project timeline frame rate as float (e.g. 24, 25, 29.97)."""
    try:
        s = project.GetSetting("timelineFrameRate")
    except Exception:
        return 24.0
    if not isinstance(s, str) or not s.strip():
        return 24.0
    s = s.strip()
    for suf in (" DF", " df"):
        if s.endswith(suf):
            s = s[: -len(suf)].strip()
            break
    try:
        return float(s)
    except ValueError:
        return 24.0


def _fps_to_frame_field_count(fps: float) -> int:
    """Frames in the last HH:MM:SS:FF field for Resolve-style timecode."""
    if fps <= 0:
        return 24
    if abs(fps - 23.976) < 0.02 or abs(fps - 23.976024) < 0.001:
        return 24
    if abs(fps - 24.0) < 0.001:
        return 24
    if abs(fps - 25.0) < 0.001:
        return 25
    if abs(fps - 29.97) < 0.02:
        return 30
    if abs(fps - 30.0) < 0.001:
        return 30
    if abs(fps - 50.0) < 0.001:
        return 50
    if abs(fps - 59.94) < 0.02:
        return 60
    if abs(fps - 47.952) < 0.02:
        return 48
    r = int(round(fps))
    return max(1, min(r, 120))


def _timeline_frame_to_timecode(frame: int, fps: float) -> str:
    """Convert timeline frame index to HH:MM:SS:FF for SetCurrentTimecode."""
    n = _fps_to_frame_field_count(fps)
    if frame < 0:
        frame = 0
    h = frame // (n * 3600)
    frame %= n * 3600
    m = frame // (n * 60)
    frame %= n * 60
    s = frame // n
    f = frame % n
    return f"{h:02d}:{m:02d}:{s:02d}:{f:02d}"


def _parse_timecode_hhmmssff(tc: str) -> Tuple[int, int, int, int]:
    """Parse Resolve-style timecode; supports ';' as last separator (drop-frame display)."""
    tc = tc.strip()
    if not tc:
        return (0, 0, 0, 0)
    tc = tc.replace(";", ":")
    parts = tc.split(":")
    if len(parts) != 4:
        raise ValueError(f"invalid timecode: {tc!r}")
    return (int(parts[0]), int(parts[1]), int(parts[2]), int(parts[3]))


def _total_frames_from_timecode(tc: str, fps_n: int) -> int:
    h, m, s, f = _parse_timecode_hhmmssff(tc)
    return ((h * 60 + m) * 60 + s) * fps_n + f


def _timecode_from_total_frames(total: int, fps_n: int) -> str:
    if total < 0:
        total = 0
    f = total % fps_n
    sec_total = total // fps_n
    s = sec_total % 60
    m = (sec_total // 60) % 60
    h = sec_total // 3600
    return f"{h:02d}:{m:02d}:{s:02d}:{f:02d}"


def _timeline_frame_to_absolute_timecode(
    timeline,
    frame: int,
    fps: float,
    log: LogFn = _log_default,
) -> str:
    """
    Map a timeline item frame position to the timecode string SetCurrentTimecode expects.

    Resolve timelines may use a non-zero start timecode; seeking with 00:00:00:00
    derived only from *frame* leaves the playhead on the wrong clip.
    """
    n = _fps_to_frame_field_count(fps)
    base_frame = 0
    base_tc_str = "00:00:00:00"
    try:
        base_frame = int(timeline.GetStartFrame())
    except Exception as e:
        log(f"WARN: timeline.GetStartFrame(): {e}")
    try:
        st = timeline.GetStartTimecode()
        if isinstance(st, str) and st.strip():
            base_tc_str = st.strip()
    except Exception as e:
        log(f"WARN: timeline.GetStartTimecode(): {e}")
    try:
        base_total = _total_frames_from_timecode(base_tc_str, n)
    except Exception as e:
        log(f"WARN: parsing timeline start timecode {base_tc_str!r}: {e}")
        base_total = 0
    delta = int(frame) - base_frame
    return _timecode_from_total_frames(base_total + delta, n)


def _seek_timeline_to_clip(
    resolve,
    timeline,
    clip,
    log: LogFn = _log_default,
) -> None:
    """
    Move playhead to the start of *clip* on the Edit page.

    On the Fusion page, host operations follow the clip under the playhead; if
    the playhead never moves, every clip is edited as the first clip.
    SetCurrentTimecode is only valid on Cut/Edit/Color/Fairlight/Deliver — not
    Fusion — so we switch to Edit, seek, then the caller opens Fusion.
    """
    try:
        project = resolve.GetProjectManager().GetCurrentProject()
        fps = _parse_timeline_fps(project) if project else 24.0
        try:
            start = clip.GetStart()
        except Exception as e:
            log(f"WARN: clip.GetStart(): {e}")
            return
        if isinstance(start, float):
            start = int(round(start))
        else:
            start = int(start)
        tc = _timeline_frame_to_absolute_timecode(timeline, start, fps, log=log)
        ok = False
        for page in ("cut", "edit"):
            try:
                resolve.OpenPage(page)
            except Exception as e:
                log(f"WARN: OpenPage({page!r}): {e}")
                continue
            try:
                ok = bool(timeline.SetCurrentTimecode(tc))
            except Exception as e:
                log(f"WARN: SetCurrentTimecode({tc!r}) on {page!r}: {e}")
                continue
            if ok:
                log(f"INFO: seek playhead to {tc!r} ({page} page) for Fusion clip")
                break
        if not ok:
            log(f"WARN: SetCurrentTimecode({tc!r}) failed on cut and edit pages")
        try:
            cur = timeline.GetCurrentVideoItem()
            if cur is not None:
                try:
                    if int(cur.GetStart()) != int(start):
                        log(
                            "WARN: GetCurrentVideoItem() start frame "
                            f"{cur.GetStart()!r} != target {start!r}; "
                            "Fusion may still target the wrong clip."
                        )
                except Exception:
                    pass
        except Exception as e:
            log(f"WARN: GetCurrentVideoItem(): {e}")
    except Exception as e:
        log(f"WARN: seek timeline for Fusion clip: {e}")


def _timeline_max_end_frame_all_video_tracks(timeline) -> Optional[int]:
    """
    Latest end frame among clips on any video track (Resolve's timeline
    GetEndFrame() can follow only one track; append must clear all tracks).
    """
    max_end: Optional[int] = None
    try:
        n = timeline.GetTrackCount("video")
    except Exception:
        return None
    for i in range(1, int(n) + 1):
        try:
            items = timeline.GetItemListInTrack("video", i)
        except Exception:
            continue
        if not items:
            continue
        for item in items:
            try:
                end = item.GetEnd()
            except Exception:
                continue
            if isinstance(end, float):
                end = int(round(end))
            else:
                end = int(end)
            if max_end is None or end > max_end:
                max_end = end
    return max_end


def _seek_timeline_to_end_for_append(
    resolve,
    timeline,
    *,
    log: LogFn = _log_default,
) -> None:
    """
    Move playhead to the timeline end so MediaPool.AppendToTimeline places new
    clips after existing edits (Cut/Edit page; same constraints as seek-to-clip).
    """
    try:
        project = resolve.GetProjectManager().GetCurrentProject()
        fps = _parse_timeline_fps(project) if project else 24.0
        end_frame: Optional[int] = _timeline_max_end_frame_all_video_tracks(timeline)
        if end_frame is None:
            try:
                end_frame = int(timeline.GetEndFrame())
            except Exception as e:
                log(f"WARN: timeline.GetEndFrame(): {e}")
                return
        tc = _timeline_frame_to_absolute_timecode(timeline, end_frame, fps, log=log)
        ok = False
        for page in ("cut", "edit"):
            try:
                resolve.OpenPage(page)
            except Exception as e:
                log(f"WARN: OpenPage({page!r}): {e}")
                continue
            try:
                ok = bool(timeline.SetCurrentTimecode(tc))
            except Exception as e:
                log(f"WARN: SetCurrentTimecode({tc!r}) on {page!r}: {e}")
                continue
            if ok:
                log(f"INFO: seek playhead to timeline end {tc!r} ({page} page) for append")
                break
        if not ok:
            log(
                f"WARN: SetCurrentTimecode({tc!r}) failed; "
                "AppendToTimeline may insert at the wrong position"
            )
    except Exception as e:
        log(f"WARN: seek timeline to end for append: {e}")


def _activate_fusion_comp(fusion, comp, log: LogFn = _log_default) -> None:
    """
    Ensure Fusion's active composition matches *comp* before AddTool.

    Some Resolve builds route node creation through GetCurrentComp(); without this,
    every AddTool can land on the first clip's comp even when *comp* is correct.
    """
    if fusion is None or comp is None:
        return
    for name in ("SetCurrentComp", "setCurrentComp", "SetComp", "ActivateComp"):
        fn = getattr(fusion, name, None)
        if callable(fn):
            try:
                fn(comp)
                log(f"INFO: Fusion.{name}(comp) OK")
                return
            except Exception as e:
                log(f"WARN: Fusion.{name}(comp): {e}")
    try:
        fusion.CurrentComp = comp  # type: ignore[attr-defined]
        log("INFO: Fusion.CurrentComp = comp OK")
    except Exception as e:
        log(f"WARN: Fusion.CurrentComp = comp: {e}")


def get_resolve():
    """Return Resolve app object (scriptapp('Resolve'))."""
    try:
        import DaVinciResolveScript as bmd  # type: ignore
    except ImportError:
        if sys.platform.startswith("darwin"):
            expected = (
                "/Library/Application Support/Blackmagic Design/DaVinci Resolve/"
                "Developer/Scripting/Modules/"
            )
        elif sys.platform.startswith("win") or sys.platform.startswith("cygwin"):
            expected = (
                os.getenv("PROGRAMDATA", "")
                + "\\Blackmagic Design\\DaVinci Resolve\\Support\\Developer\\Scripting\\Modules\\"
            )
        elif sys.platform.startswith("linux"):
            expected = "/opt/resolve/libs/Fusion/Modules/"
        else:
            expected = ""
        _log_default(
            "DaVinciResolveScript not on PYTHONPATH. Set RESOLVE_SCRIPT_API and:\n"
            f'  export PYTHONPATH="$RESOLVE_SCRIPT_API/Modules:$PYTHONPATH"\n'
            f"Expected module location (macOS): {expected}"
        )
        sys.exit(1)
    resolve = bmd.scriptapp("Resolve")
    if resolve is None:
        raise RuntimeError(
            "DaVinci Resolve is not running. Open the DaVinci Resolve app, then try again."
        )
    return resolve


def discover_gyroflow_tool_id(fusion, log: LogFn = _log_default) -> str:
    """Prefer ofx.xyz.gyroflow; scan GetRegList() for gyroflow-related OFX IDs."""
    if fusion is None:
        return DEFAULT_GYROFLOW_OFX_ID
    getter = getattr(fusion, "GetRegList", None)
    if not callable(getter):
        return DEFAULT_GYROFLOW_OFX_ID
    try:
        reg = getter()
    except Exception as e:
        log(f"WARN: GetRegList() failed ({e}); using default {DEFAULT_GYROFLOW_OFX_ID!r}")
        return DEFAULT_GYROFLOW_OFX_ID
    if not reg:
        return DEFAULT_GYROFLOW_OFX_ID
    for entry in reg:
        s = entry if isinstance(entry, str) else str(entry)
        if s == DEFAULT_GYROFLOW_OFX_ID:
            return s
    for entry in reg:
        s = entry if isinstance(entry, str) else str(entry)
        if "ofx.xyz.gyroflow" in s:
            return s.split()[0]
    for entry in reg:
        s = entry if isinstance(entry, str) else str(entry)
        low = s.lower()
        if "gyroflow" in low and "ofx" in low:
            log(f"INFO: using Gyroflow registry id from GetRegList: {s!r}")
            return s.split()[0] if s.split() else s
    return DEFAULT_GYROFLOW_OFX_ID


def _pair_stem_from_clip_path(path: str, pairs: List[Dict[str, Any]]) -> Optional[str]:
    """
    Map a Resolve-reported filesystem path to our batch stem.

    For DNG sequence folders the batch stem is the *directory* name, but Resolve
    exposes the first frame file path — stem_from_media_path would use the frame
    basename and miss the folder stem. Match by parent dir or path prefix.
    """
    path = os.path.abspath(os.path.normpath(path.strip()))
    try:
        rp = os.path.realpath(path)
    except OSError:
        rp = path
    parent = os.path.dirname(path)
    try:
        rparent = os.path.realpath(parent)
    except OSError:
        rparent = parent

    for p in pairs:
        mp = os.path.abspath(os.path.normpath(p["media_path"]))
        try:
            rmp = os.path.realpath(mp)
        except OSError:
            rmp = mp
        if p.get("is_sequence"):
            if (
                parent == mp
                or rparent == rmp
                or path.startswith(mp + os.sep)
            ):
                return str(p["stem"])
        else:
            if path == mp or rp == rmp:
                return str(p["stem"])
    return None


def stem_from_media_pool_item(
    mpi,
    pairs: Optional[List[Dict[str, Any]]] = None,
) -> Optional[str]:
    """Derive batch stem from MediaPoolItem clip properties.

    When ``pairs`` is the same list passed to ``import_and_build_timeline``,
    stems match ``build_stem_pairs`` even for DNG folders (folder stem vs first
    frame path from Resolve).
    """
    try:
        props = mpi.GetClipProperty()
    except Exception:
        props = None
    path: Optional[str] = None
    if isinstance(props, dict):
        for key in (
            "File Path",
            "Clip File Path",
            "Import File Path",
            "Path",
        ):
            raw = props.get(key)
            if isinstance(raw, str) and raw.strip():
                path = os.path.abspath(raw.strip())
                break
    if path and pairs:
        st = _pair_stem_from_clip_path(path, pairs)
        if st:
            return st
    if path:
        return stem_from_media_path(path)
    if isinstance(props, dict):
        fn = props.get("File Name")
        if isinstance(fn, str) and fn.strip():
            return stem_from_media_path(fn)
    try:
        name = mpi.GetName()
        if isinstance(name, str) and name.strip():
            return stem_from_media_path(name)
    except Exception:
        pass
    return None


def _fusion_find_tool(comp, names: Sequence[str]):
    fn = getattr(comp, "FindTool", None)
    if callable(fn):
        for n in names:
            try:
                t = fn(n)
                if t:
                    return t
            except Exception:
                continue
    return None


def _fusion_iter_tools(comp):
    gl = getattr(comp, "GetToolList", None)
    if not callable(gl):
        return []
    try:
        tools = gl(False)
        if tools:
            return list(tools)
    except TypeError:
        try:
            tools = gl(False, None)
            if tools:
                return list(tools)
        except Exception:
            pass
    except Exception:
        pass
    return []


def _tool_matches_id(tool, reg_id: str) -> bool:
    for attr in ("ID", "GetAttrs", "Name"):
        g = getattr(tool, attr, None)
        if callable(g):
            try:
                if attr == "GetAttrs":
                    a = g()
                else:
                    a = g()
                if isinstance(a, dict) and "TOOLS_RegID" in a:
                    return a.get("TOOLS_RegID") == reg_id
            except Exception:
                pass
        elif isinstance(g, str) and reg_id in g:
            return True
    try:
        sid = str(tool)
        if reg_id in sid:
            return True
    except Exception:
        pass
    return False


def find_mediain_mediaout(comp, log: LogFn = _log_default):
    mediain = _fusion_find_tool(comp, ("MediaIn1", "MediaIn2", "MediaIn"))
    mediaout = _fusion_find_tool(comp, ("MediaOut1", "MediaOut2", "MediaOut"))
    if mediain and mediaout:
        return mediain, mediaout
    tools = _fusion_iter_tools(comp)
    for t in tools:
        try:
            tid = getattr(t, "GetAttrs", None)
            reg = None
            if callable(tid):
                attrs = tid()
                if isinstance(attrs, dict):
                    reg = attrs.get("TOOLS_RegID", "")
            s = (reg or "") + str(t)
            if not mediain and "MediaIn" in s:
                mediain = t
            if not mediaout and "MediaOut" in s:
                mediaout = t
        except Exception:
            continue
    if not mediain or not mediaout:
        log(
            "WARN: could not resolve MediaIn/MediaOut by name; "
            "Fusion wiring may need manual adjustment."
        )
    return mediain, mediaout


def _connect_attempt(dst, input_name: str, src) -> bool:
    cn = getattr(dst, "ConnectInput", None)
    if not callable(cn) or src is None:
        return False
    try:
        cn(input_name, src)
        return True
    except Exception:
        pass
    # Some hosts require the source tool's output name (third argument), not only a numeric index.
    for out_name in _fusion_output_candidates(src):
        try:
            cn(input_name, src, out_name)
            return True
        except Exception:
            continue
    try:
        cn(input_name, src, 0)
        return True
    except Exception:
        return False


def _connect_attempt_numeric(dst, upstream_src) -> bool:
    """Some Resolve/Fusion builds accept a 1-based input index as the first argument."""
    cn = getattr(dst, "ConnectInput", None)
    if not callable(cn) or upstream_src is None:
        return False
    outs = [None] + list(_fusion_output_candidates(upstream_src))
    for idx in range(1, 16):
        for out_name in outs:
            try:
                if out_name is None:
                    cn(idx, upstream_src)
                else:
                    cn(idx, upstream_src, out_name)
                return True
            except Exception:
                continue
    return False


def _fusion_find_main_input_links(tool):
    """Yield (index, link) for FindMainInput(1..n) while links exist."""
    fm = getattr(tool, "FindMainInput", None)
    if not callable(fm):
        return
    for i in range(1, 24):
        try:
            link = fm(i)
        except Exception:
            break
        if link is None:
            break
        yield i, link


def _fusion_find_main_input_names(tool) -> List[str]:
    """Names of main image inputs from FindMainInput(1..n), if the host exposes it."""
    names: List[str] = []
    for _i, link in _fusion_find_main_input_links(tool):
        nm = _fusion_link_name_from_object(link)
        if nm and _is_usable_fusion_link_name(nm):
            names.append(nm)
        else:
            break
    return names


def _connect_input_link_to_upstream(dst_input_link, src_tool) -> bool:
    """Connect a Fusion input Link (e.g. FindMainInput) to *src_tool*'s output — reliable for OFX in Resolve."""
    if dst_input_link is None or src_tool is None:
        return False
    ct = getattr(dst_input_link, "ConnectTo", None)
    if not callable(ct):
        return False
    go = getattr(src_tool, "GetOutput", None)
    if not callable(go):
        return False
    for out_name in _fusion_output_candidates(src_tool):
        try:
            out = go(out_name)
            if not out:
                continue
            ct(out)
            return True
        except Exception:
            continue
    return False


def _wire_via_find_main_input(dst_tool, src_tool, log: LogFn, edge_label: str) -> bool:
    """Try FindMainInput(1).ConnectTo(src.Output) for each main input until one succeeds."""
    for idx, link in _fusion_find_main_input_links(dst_tool):
        if _connect_input_link_to_upstream(link, src_tool):
            nm = _fusion_link_name_from_object(link) or f"main[{idx}]"
            log(f"INFO: {edge_label} via FindMainInput({idx}).ConnectTo (→ {nm!r})")
            return True
    return False


def _fusion_ordered_input_names(tool, fallback: Sequence[str]) -> List[str]:
    """Prefer FindMainInput order, then GetInputList, then *fallback*."""
    seen: set[str] = set()
    out: List[str] = []
    for n in _fusion_find_main_input_names(tool):
        if n and n not in seen and _is_usable_fusion_link_name(n):
            seen.add(n)
            out.append(n)
    gl = getattr(tool, "GetInputList", None)
    if callable(gl):
        try:
            for n in _fusion_flatten_link_names(gl()):
                if n and n not in seen and _is_usable_fusion_link_name(n):
                    seen.add(n)
                    out.append(n)
        except Exception:
            pass
    for n in fallback:
        if n and n not in seen and _is_usable_fusion_link_name(n):
            seen.add(n)
            out.append(n)
    return out


def _try_disconnect_input(tool, input_name: str) -> bool:
    for meth in ("DisconnectInput", "disconnectInput"):
        di = getattr(tool, meth, None)
        if not callable(di):
            continue
        try:
            di(input_name)
            return True
        except Exception:
            continue
    return False


def _disconnect_mediaout_for_insert(mediaout, log: LogFn = _log_default) -> None:
    """
    Break MediaOut's incoming link before inserting an effect.

    A direct MediaIn→MediaOut pipe is often left in place if we only call
    ConnectInput on Gyroflow/MediaOut — the host does not detach MediaOut for us.
    """
    if not mediaout:
        return
    fallback = ("Input", "Source", "Video", "Image", "Clip")
    for name in _fusion_ordered_input_names(mediaout, fallback):
        if _try_disconnect_input(mediaout, name):
            log(f"INFO: disconnected MediaOut.{name!r} so Gyroflow can be inserted")
            return


def _is_fusion_index_key(k) -> bool:
    """True if *k* looks like a Lua 1-based index (Fusion tables from Python)."""
    if isinstance(k, bool):
        return False
    if isinstance(k, (int, float)):
        return True
    if isinstance(k, str) and k.isdigit():
        return True
    return False


def _fusion_link_name_from_object(obj) -> Optional[str]:
    """Resolve/Fusion Link-like objects: real name from .Name / .ID — never str(obj) (host repr garbage)."""
    if obj is None:
        return None
    if isinstance(obj, str):
        s = obj.strip()
        return s if s else None
    for attr in ("Name", "ID"):
        nm = getattr(obj, attr, None)
        if callable(nm):
            try:
                nm = nm()
            except Exception:
                nm = None
        if isinstance(nm, str) and nm.strip():
            return nm.strip()
    return None


def _is_usable_fusion_link_name(name: str) -> bool:
    """
    Reject str(link) host reprs mistaken for names, e.g.
    'Input (0x0x...) [App: \\'Resolve\\' on ...]'.
    """
    if not name or not name.strip():
        return False
    s = name.strip()
    if len(s) > 72:
        return False
    if "(0x" in s or "[App:" in s or "UUID:" in s or " on 127.0.0.1" in s:
        return False
    return True


def _fusion_flatten_link_names(raw) -> List[str]:
    """Normalize GetInputList/GetOutputList results from Fusion Python."""
    if raw is None:
        return []
    if isinstance(raw, str):
        return [raw] if raw.strip() else []
    if isinstance(raw, dict):
        keys = [k for k in raw.keys() if k is not None]
        if not keys:
            return []
        # Lua arrays often appear as {1.0: "Source", 2.0: "EffectMask"} — link *names* are the values.
        if keys and all(_is_fusion_index_key(k) for k in keys):
            ordered = sorted(keys, key=lambda x: float(x) if not isinstance(x, str) else float(x))
            out: List[str] = []
            for k in ordered:
                v = raw[k]
                if v is None:
                    continue
                if isinstance(v, str):
                    s = v.strip()
                    if s:
                        out.append(s)
                else:
                    nm = _fusion_link_name_from_object(v)
                    if nm and _is_usable_fusion_link_name(nm):
                        out.append(nm)
            if out:
                return out
        # Dict keys may be Link objects — do not use str(key); read .Name.
        out_keys: List[str] = []
        for k in keys:
            if isinstance(k, str) and _is_usable_fusion_link_name(k):
                out_keys.append(k.strip())
                continue
            nm = _fusion_link_name_from_object(k)
            if nm and _is_usable_fusion_link_name(nm):
                out_keys.append(nm)
        return out_keys
    if isinstance(raw, (list, tuple, set)):
        out: List[str] = []
        for x in raw:
            if x is None:
                continue
            if isinstance(x, str) and _is_usable_fusion_link_name(x):
                out.append(x.strip())
                continue
            nm = _fusion_link_name_from_object(x)
            if nm and _is_usable_fusion_link_name(nm):
                out.append(nm)
        return out
    return []


def _fusion_output_candidates(src_tool) -> List[str]:
    gol = getattr(src_tool, "GetOutputList", None)
    if callable(gol):
        try:
            names = _fusion_flatten_link_names(gol())
            if names:
                return names
        except Exception:
            pass
    return ["Output", "Data", "Image", "Clip"]


def _gyroflow_input_candidates(gyro_tool) -> List[str]:
    """Host-specific OFX input names first, then common fallbacks."""
    fallback = (
        "Input",
        "Source",
        "SourceImage",
        "Video",
        "Image",
        "Clip",
        "Foreground",
        "Main",
        "OfxInput",
        "OFXInput",
        "Input1",
        "source_clip",
    )
    return _fusion_ordered_input_names(gyro_tool, fallback)


def _mediaout_input_candidates(mediaout_tool) -> List[str]:
    return _fusion_ordered_input_names(
        mediaout_tool,
        ("Input", "Source", "Video", "Image", "Clip"),
    )


def _connect_via_input_output_links(dst_tool, input_name: str, src_tool) -> bool:
    """
    Connect using Fusion Link API: dst.GetInput(name).ConnectTo(src.GetOutput(...)).
    OpenFX nodes often need this path; ConnectInput(name, tool) may not attach.
    """
    gi = getattr(dst_tool, "GetInput", None)
    go = getattr(src_tool, "GetOutput", None)
    if not callable(gi) or not callable(go):
        return False
    try:
        inp = gi(input_name)
    except Exception:
        inp = None
    if inp is None:
        return False
    ct = getattr(inp, "ConnectTo", None)
    if not callable(ct):
        return False
    for out_name in _fusion_output_candidates(src_tool):
        try:
            out = go(out_name)
            if not out:
                continue
            ct(out)
            return True
        except Exception:
            continue
    return False


def wire_gyroflow_between_mediain_out(
    comp,
    gyro_tool,
    mediain,
    mediaout,
    log: LogFn = _log_default,
) -> bool:
    """Connect MediaIn -> Gyroflow -> MediaOut using common Fusion input names."""
    if not gyro_tool:
        return False
    if mediaout:
        _disconnect_mediaout_for_insert(mediaout, log=log)
    ok_g = False
    if mediain:
        ok_g = _wire_via_find_main_input(
            gyro_tool, mediain, log, "connected MediaIn -> Gyroflow"
        )
    for inp in () if ok_g else _gyroflow_input_candidates(gyro_tool):
        if _connect_attempt(gyro_tool, inp, mediain):
            ok_g = True
            log(f"INFO: connected MediaIn -> Gyroflow via ConnectInput({inp!r})")
            break
        if _connect_via_input_output_links(gyro_tool, inp, mediain):
            ok_g = True
            log(f"INFO: connected MediaIn -> Gyroflow via Input.ConnectTo (input={inp!r})")
            break
    if not ok_g and mediain:
        if _connect_attempt_numeric(gyro_tool, mediain):
            ok_g = True
            log("INFO: connected MediaIn -> Gyroflow via ConnectInput(inputIndex, MediaIn, ...)")
    if not ok_g:
        log(
            "WARN: could not connect MediaIn to Gyroflow; "
            "check OFX input names in Fusion or connect manually."
        )
    ok_m = False
    if gyro_tool:
        ok_m = _wire_via_find_main_input(
            mediaout, gyro_tool, log, "connected Gyroflow -> MediaOut"
        )
    for inp in () if ok_m else _mediaout_input_candidates(mediaout):
        if _connect_attempt(mediaout, inp, gyro_tool):
            ok_m = True
            log(f"INFO: connected Gyroflow -> MediaOut via ConnectInput({inp!r})")
            break
        if _connect_via_input_output_links(mediaout, inp, gyro_tool):
            ok_m = True
            log(f"INFO: connected Gyroflow -> MediaOut via Input.ConnectTo (input={inp!r})")
            break
    if not ok_m and gyro_tool:
        if _connect_attempt_numeric(mediaout, gyro_tool):
            ok_m = True
            log("INFO: connected Gyroflow -> MediaOut via ConnectInput(inputIndex, Gyroflow, ...)")
    if not ok_m:
        log("WARN: could not connect Gyroflow to MediaOut.")
    return ok_g and ok_m


def _fusion_flow_view(comp):
    """Return the FlowView for the current frame (Fusion node graph layout)."""
    if not comp:
        return None
    for frame_attr in ("CurrentFrame", "currentFrame"):
        frame = getattr(comp, frame_attr, None)
        if frame is None:
            continue
        for fv_attr in ("FlowView", "flowView"):
            fv = getattr(frame, fv_attr, None)
            if fv is not None:
                return fv
    return None


def _fusion_parse_flow_pos(p) -> Optional[Tuple[float, float]]:
    if p is None:
        return None
    if isinstance(p, (list, tuple)) and len(p) >= 2:
        try:
            return float(p[0]), float(p[1])
        except (TypeError, ValueError):
            return None
    if isinstance(p, dict):
        # Fusion Python: Lua tuples become dicts with 1-based numeric keys, e.g. {1.0: x, 2.0: y}
        num_keys = sorted(
            (k for k in p.keys() if isinstance(k, (int, float))),
            key=float,
        )
        if len(num_keys) >= 2:
            try:
                return float(p[num_keys[0]]), float(p[num_keys[1]])
            except (TypeError, ValueError, KeyError):
                pass
        for kx, ky in (("x", "y"), ("X", "Y")):
            if kx in p and ky in p:
                try:
                    return float(p[kx]), float(p[ky])
                except (TypeError, ValueError):
                    pass
    return None


def _fusion_tool_flow_pos(flow, tool) -> Optional[Tuple[float, float]]:
    if not flow or not tool:
        return None
    # GetPosTable returns full (x, y); GetPos in Python often returns only X (Lua multi-return).
    gpt = getattr(flow, "GetPosTable", None)
    if callable(gpt):
        try:
            xy = _fusion_parse_flow_pos(gpt(tool))
            if xy:
                return xy
        except Exception:
            pass
    gp = getattr(flow, "GetPos", None)
    if callable(gp):
        try:
            xy = _fusion_parse_flow_pos(gp(tool))
            if xy:
                return xy
        except Exception:
            pass
    return None


def _fusion_tool_grid_pos_from_attrs(tool) -> Optional[Tuple[float, float]]:
    ga = getattr(tool, "GetAttrs", None)
    if not callable(ga):
        return None
    try:
        a = ga()
    except Exception:
        return None
    if not isinstance(a, dict):
        return None
    for key in ("TOOLS_Position", "TOOLS_Pos", "TOOLST_Position"):
        if key in a:
            xy = _fusion_parse_flow_pos(a[key])
            if xy:
                return xy
    return None


def gyroflow_grid_pos_between_mediain_out(
    comp,
    mediain,
    mediaout,
) -> Optional[Tuple[int, int]]:
    """
    Grid coordinates halfway between MediaIn and MediaOut on the FlowView.
    Used so AddTool / SetPos place Gyroflow between the clip I/O nodes.
    """
    if not mediain or not mediaout:
        return None
    flow = _fusion_flow_view(comp)
    p1 = _fusion_tool_flow_pos(flow, mediain) if flow else None
    p2 = _fusion_tool_flow_pos(flow, mediaout) if flow else None
    if not p1:
        p1 = _fusion_tool_grid_pos_from_attrs(mediain)
    if not p2:
        p2 = _fusion_tool_grid_pos_from_attrs(mediaout)
    if not p1 or not p2:
        return None
    mx = int(round((p1[0] + p2[0]) / 2.0))
    my = int(round((p1[1] + p2[1]) / 2.0))
    return mx, my


def _fusion_set_tool_flow_pos(comp, tool, x: int, y: int) -> bool:
    flow = _fusion_flow_view(comp)
    sp = getattr(flow, "SetPos", None) if flow else None
    if not callable(sp):
        return False
    try:
        sp(tool, x, y)
        return True
    except Exception:
        try:
            sp(tool, float(x), float(y))
            return True
        except Exception:
            return False


def add_gyroflow_tool(
    comp,
    reg_id: str,
    log: LogFn = _log_default,
    *,
    grid_xy: Optional[Tuple[int, int]] = None,
):
    """
    Add Gyroflow OFX to the comp. When ``grid_xy`` is set (typically the
    midpoint between MediaIn and MediaOut), try that first and then
    ``FlowView:SetPos`` so the node sits between them instead of a fixed corner.
    """
    add = getattr(comp, "AddTool", None)
    if not callable(add):
        log("ERROR: composition has no AddTool")
        return None
    attempts: List[Tuple[int, int]] = []
    if grid_xy is not None:
        attempts.append(grid_xy)
    for xy in ((100, 400), (200, 400), (100, 300)):
        if grid_xy is not None and xy == grid_xy:
            continue
        attempts.append(xy)
    t = None
    for x, y in attempts:
        try:
            t = add(reg_id, x, y)
            if t:
                break
        except Exception as e:
            log(f"WARN: AddTool({reg_id!r}) at ({x},{y}): {e}")
    if not t:
        return None
    if grid_xy is not None:
        gx, gy = grid_xy
        if _fusion_set_tool_flow_pos(comp, t, gx, gy):
            log(f"INFO: Gyroflow node placed at ({gx}, {gy}) between MediaIn and MediaOut.")
        else:
            log(
                "WARN: could not SetPos for Gyroflow; if the node is off-grid, "
                "drag it between MediaIn and MediaOut."
            )
    return t


def set_gyroflow_project_path(tool, gyroflow_path: str, log: LogFn = _log_default) -> bool:
    path = os.path.abspath(gyroflow_path)
    si = getattr(tool, "SetInput", None)
    if not callable(si):
        log("ERROR: tool has no SetInput")
        return False
    try:
        si("ProjectPath", path)
    except Exception as e:
        log(f"ERROR: SetInput('ProjectPath', ...): {e}")
        return False
    gi = getattr(tool, "GetInput", None)
    if callable(gi):
        try:
            v = gi("ProjectPath")
            log(f"INFO: ProjectPath now {v!r}")
        except Exception:
            pass
    return True


def apply_gyroflow_to_clip(
    resolve,
    clip,
    gyroflow_path: str,
    reg_id: str,
    *,
    timeline: Optional[Any] = None,
    fusion_comp_index: int = 1,
    log: LogFn = _log_default,
) -> bool:
    """
    Open Fusion page, load comp, AddTool Gyroflow, wire, SetInput ProjectPath.

    Pass *timeline* (current timeline) so the playhead can be moved to *clip*
    before Fusion opens; otherwise Fusion targets whichever clip is under the
    playhead (often the first clip only).
    """
    if timeline is not None:
        _seek_timeline_to_clip(resolve, timeline, clip, log=log)
    try:
        resolve.OpenPage("fusion")
    except Exception as e:
        log(f"WARN: OpenPage('fusion'): {e}")

    if clip.GetFusionCompCount() < 1:
        try:
            clip.AddFusionComp()
        except Exception as e:
            log(f"ERROR: AddFusionComp: {e}")
            return False

    names = clip.GetFusionCompNameList()
    comp_name = None
    if isinstance(names, list) and len(names) >= fusion_comp_index:
        comp_name = names[fusion_comp_index - 1]

    comp = None
    if comp_name:
        try:
            loaded = clip.LoadFusionCompByName(comp_name)
            # Some hosts return only a success flag; ignore non-comp values.
            if loaded is not None and not isinstance(loaded, bool):
                comp = loaded
        except Exception as e:
            log(f"WARN: LoadFusionCompByName({comp_name!r}): {e}")
    if not comp:
        try:
            comp = clip.GetFusionCompByIndex(fusion_comp_index)
        except Exception as e:
            log(f"ERROR: GetFusionCompByIndex({fusion_comp_index}): {e}")
            return False
    if not comp:
        log(f"ERROR: no Fusion composition for index {fusion_comp_index}")
        return False

    fusion = resolve.Fusion()
    _activate_fusion_comp(fusion, comp, log=log)
    tool_id = reg_id if reg_id else discover_gyroflow_tool_id(fusion, log=log)

    mediain, mediaout = find_mediain_mediaout(comp, log=log)
    grid_xy = gyroflow_grid_pos_between_mediain_out(comp, mediain, mediaout)

    gyro = add_gyroflow_tool(comp, tool_id, log=log, grid_xy=grid_xy)
    if not gyro:
        log(f"ERROR: AddTool failed for {tool_id!r}")
        return False

    # Remove duplicate Gyroflow if we re-run: keep the one we just added (last matching)
    tools = _fusion_iter_tools(comp)
    gyro_tools = [t for t in tools if _tool_matches_id(t, tool_id)]
    if len(gyro_tools) > 1:
        log(
            f"WARN: multiple Gyroflow tools in comp ({len(gyro_tools)}); "
            "using the last AddTool result."
        )

    wire_gyroflow_between_mediain_out(comp, gyro, mediain, mediaout, log=log)

    if not set_gyroflow_project_path(gyro, gyroflow_path, log=log):
        return False
    return True


def collect_timeline_video_clips(timeline) -> List:
    clips_out: List = []
    try:
        n = timeline.GetTrackCount("video")
    except Exception:
        return clips_out
    for i in range(1, int(n) + 1):
        try:
            items = timeline.GetItemListInTrack("video", i)
        except Exception:
            continue
        if items:
            clips_out.extend(items)
    return clips_out


def _timeline_items_for_batch_stems(
    timeline,
    pairs: List[Dict[str, Any]],
    *,
    log: LogFn = _log_default,
) -> List[Any]:
    """
    Timeline items for this batch's stems in pair order. Last match wins per stem
    (covers append fallback when AppendToTimeline does not return item handles).
    """
    want = [p["stem"] for p in pairs]
    want_set = frozenset(want)
    by_stem: Dict[str, Any] = {}
    for clip in collect_timeline_video_clips(timeline):
        mpi = clip.GetMediaPoolItem()
        stem = stem_from_media_pool_item(mpi, pairs) if mpi else None
        if stem and stem in want_set:
            by_stem[stem] = clip
    out: List[Any] = []
    missing: List[str] = []
    for st in want:
        if st in by_stem:
            out.append(by_stem[st])
        else:
            missing.append(st)
    if missing:
        log(f"WARN: could not find timeline items for stems: {missing}")
    return out


def _folder_subfolders(folder) -> List[Any]:
    """Resolve Folder API has used different method names across versions."""
    for meth in ("GetSubFolderList", "GetSubFolders"):
        if hasattr(folder, meth):
            try:
                out = getattr(folder, meth)()
            except Exception:
                continue
            if out:
                return list(out)
            return []
    return []


def get_or_create_root_bin(mediapool, root, name: str, *, log: LogFn = _log_default):
    """Return a root-level Media Pool folder by name, or create it. `name` must be non-empty."""
    stripped = name.strip()
    if not stripped:
        return root
    for sub in _folder_subfolders(root):
        try:
            if sub.GetName() == stripped:
                log(f"INFO: using existing Media Pool bin {stripped!r}")
                return sub
        except Exception:
            continue
    created = mediapool.AddSubFolder(root, stripped)
    if not created:
        raise RuntimeError(f"AddSubFolder({stripped!r}) failed")
    log(f"INFO: created Media Pool bin {stripped!r}")
    return created


def find_timeline_by_name(project, name: str, *, log: LogFn = _log_default):
    """
    Return an existing project timeline whose GetName() matches *name* (stripped),
    or None. If multiple timelines share the name, the lowest index wins.
    """
    stripped = name.strip()
    if not stripped:
        return None
    try:
        count = project.GetTimelineCount()
    except Exception as e:
        log(f"WARN: GetTimelineCount(): {e}")
        return None
    for i in range(1, int(count) + 1):
        try:
            tl = project.GetTimelineByIndex(i)
            if tl and tl.GetName() == stripped:
                return tl
        except Exception:
            continue
    return None


def import_and_build_timeline(
    resolve,
    pairs: List[Dict[str, Any]],
    timeline_name: str,
    *,
    bin_name: Optional[str] = None,
    log: LogFn = _log_default,
) -> Tuple[Any, List[Any]]:
    """AddItemListToMediaPool, map stems, then create or append to a timeline.

    If a timeline with the same name (after stripping) already exists, new clips
    are appended at the end after seeking the playhead there. Otherwise a new
    timeline is created with CreateTimelineFromClips.

    Returns ``(timeline, timeline_items_for_fusion)``: the latter lists only
    clips from this run (append return value or full timeline for a new timeline).
    """
    project = resolve.GetProjectManager().GetCurrentProject()
    if not project:
        raise RuntimeError("No current project after ensure_project().")
    tl_name = timeline_name.strip()
    if not tl_name:
        raise RuntimeError("timeline name is empty")

    storage = resolve.GetMediaStorage()
    mediapool = project.GetMediaPool()
    root = mediapool.GetRootFolder()
    if not root:
        raise RuntimeError("GetRootFolder() failed")

    target_folder = root
    if bin_name and bin_name.strip():
        target_folder = get_or_create_root_bin(mediapool, root, bin_name, log=log)
    prev_folder = None
    try:
        prev_folder = mediapool.GetCurrentFolder()
    except Exception:
        prev_folder = None

    if not mediapool.SetCurrentFolder(target_folder):
        raise RuntimeError("SetCurrentFolder(target bin) failed")

    paths = [p["media_path"] for p in pairs]
    imported = storage.AddItemListToMediaPool(paths)
    if not imported:
        raise RuntimeError("AddItemListToMediaPool returned no clips — check file paths and permissions.")

    stem_to_mpi: Dict[str, Any] = {}
    for mpi in imported:
        st = stem_from_media_pool_item(mpi, pairs)
        if st:
            stem_to_mpi[st] = mpi
        else:
            log(f"WARN: could not determine stem for media pool item {mpi!r}")

    ordered = []
    missing = []
    for p in pairs:
        st = p["stem"]
        m = stem_to_mpi.get(st)
        if not m:
            missing.append(st)
        else:
            ordered.append(m)
    if missing:
        raise RuntimeError(f"Could not map stems to imported clips: {missing}")

    existing = find_timeline_by_name(project, tl_name, log=log)
    fusion_clips: List[Any] = []

    if existing:
        log(f"INFO: timeline {tl_name!r} exists — appending {len(ordered)} clip(s) at end")
        if not project.SetCurrentTimeline(existing):
            raise RuntimeError(f"SetCurrentTimeline(existing {tl_name!r}) failed")
        _seek_timeline_to_end_for_append(resolve, existing, log=log)
        appended = mediapool.AppendToTimeline(ordered)
        if appended is False or appended is None:
            raise RuntimeError(f"AppendToTimeline({tl_name!r}) failed")
        if isinstance(appended, list) and appended:
            fusion_clips = list(appended)
        else:
            log(
                "WARN: AppendToTimeline did not return a non-empty timeline item list; "
                "matching batch stems on the timeline (last match per stem)"
            )
            fusion_clips = _timeline_items_for_batch_stems(existing, pairs, log=log)
        if not fusion_clips:
            raise RuntimeError(f"AppendToTimeline({tl_name!r}) produced no usable timeline items")
        timeline = existing
    else:
        timeline = mediapool.CreateTimelineFromClips(tl_name, ordered)
        if not timeline:
            raise RuntimeError(f"CreateTimelineFromClips({tl_name!r}) failed")
        project.SetCurrentTimeline(timeline)
        fusion_clips = collect_timeline_video_clips(timeline)

    if prev_folder is not None:
        mediapool.SetCurrentFolder(prev_folder)
    else:
        mediapool.SetCurrentFolder(root)

    return timeline, fusion_clips


def run_automation(
    video_folder: str,
    project_folder: str,
    *,
    project_name: Optional[str] = None,
    timeline_name: str = "Gyroflow batch",
    bin_name: Optional[str] = None,
    dry_run: bool = False,
    export_mapping: Optional[str] = None,
    skip_fusion: bool = False,
    fusion_comp_index: int = 1,
    log: LogFn = _log_default,
) -> int:
    pairs = build_stem_pairs(video_folder, project_folder, require_gyroflow=True, log=log)
    if not pairs:
        log("No footage / gyroflow pairs to process.")
        return 1

    if export_mapping:
        with open(export_mapping, "w", encoding="utf-8") as f:
            json.dump(pairs, f, indent=2)
        log(f"Wrote mapping JSON: {export_mapping}")

    if dry_run:
        for p in pairs:
            log(f"DRY: {p['stem']}: {p['media_path']} -> {p['gyroflow_path']}")
        return 0

    resolve = get_resolve()
    ensure_project(resolve, project_name, log=log)
    fusion = resolve.Fusion()
    tool_id = discover_gyroflow_tool_id(fusion, log=log)
    log(f"INFO: Gyroflow OFX registry id: {tool_id!r}")

    timeline, fusion_clips = import_and_build_timeline(
        resolve, pairs, timeline_name, bin_name=bin_name, log=log
    )

    if skip_fusion:
        log("INFO: --skip-fusion: media pool + timeline only.")
        return 0

    project = resolve.GetProjectManager().GetCurrentProject()
    if not timeline:
        log("ERROR: no timeline after import")
        return 1
    if project:
        try:
            project.SetCurrentTimeline(timeline)
        except Exception:
            pass

    stem_to_gf = {p["stem"]: p["gyroflow_path"] for p in pairs}
    clips = fusion_clips
    ok = 0
    failed = 0
    n_clips = len(clips)
    for idx, clip in enumerate(clips, start=1):
        _emit_ui_progress(idx, n_clips)
        mpi = clip.GetMediaPoolItem()
        stem = stem_from_media_pool_item(mpi, pairs) if mpi else None
        if not stem or stem not in stem_to_gf:
            log(f"WARN: skip timeline clip (stem={stem!r})")
            failed += 1
            continue
        gf_path = stem_to_gf[stem]
        log(f"━━ Fusion: stem={stem!r} ━━")
        if apply_gyroflow_to_clip(
            resolve,
            clip,
            gf_path,
            tool_id,
            timeline=timeline,
            fusion_comp_index=fusion_comp_index,
            log=log,
        ):
            ok += 1
        else:
            failed += 1

    log(f"Done. Fusion OK: {ok}, failed/skipped: {failed}")
    return 0 if failed == 0 else 1


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Resolve: import paired footage + .gyroflow, timeline, Fusion Gyroflow OFX per clip."
    )
    parser.add_argument("video_folder", help="Same VIDEO_FOLDER as gyroflow_export_projects.sh")
    parser.add_argument("project_folder", help="Folder containing <stem>.gyroflow files")
    parser.add_argument(
        "--project-name",
        metavar="NAME",
        help="Resolve project to load or create (default: use current project)",
    )
    parser.add_argument(
        "--timeline-name",
        default="Gyroflow batch",
        help="Timeline name: reuse if it already exists and append new clips at the end "
        "(default: %(default)s)",
    )
    parser.add_argument(
        "--bin-name",
        metavar="NAME",
        default=None,
        help="Media Pool bin name (root level); use existing bin if present, else create",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Only list stem pairs; do not call Resolve",
    )
    parser.add_argument(
        "--export-mapping",
        metavar="FILE",
        help="Write stem/media_path/gyroflow_path JSON to FILE",
    )
    parser.add_argument(
        "--skip-fusion",
        action="store_true",
        help="Import media and create timeline only (no Fusion automation)",
    )
    parser.add_argument(
        "--fusion-comp-index",
        type=int,
        default=1,
        help="Fusion composition index (1-based, default: %(default)s)",
    )
    parser.add_argument(
        "-q",
        "--quiet",
        action="store_true",
        help="Less stderr output",
    )
    args = parser.parse_args(list(argv) if argv is not None else None)

    log: LogFn = (lambda _m: None) if args.quiet else _log_default

    if args.fusion_comp_index < 1:
        log("ERROR: --fusion-comp-index must be >= 1")
        return 1

    try:
        return run_automation(
            args.video_folder,
            args.project_folder,
            project_name=args.project_name,
            timeline_name=args.timeline_name,
            bin_name=args.bin_name,
            dry_run=args.dry_run,
            export_mapping=args.export_mapping,
            skip_fusion=args.skip_fusion,
            fusion_comp_index=args.fusion_comp_index,
            log=log,
        )
    except (FileNotFoundError, RuntimeError) as e:
        log(str(e))
        return 1


if __name__ == "__main__":
    sys.exit(main())
