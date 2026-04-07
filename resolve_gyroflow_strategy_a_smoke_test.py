#!/usr/bin/env python3
"""
Manual smoke test for Resolve 20.x + Gyroflow OFX (Strategy A: Fusion per clip).

Run inside DaVinci Resolve with a project open and at least one video clip on
the timeline with a Fusion composition (or the script will add one).

Validates:
  - resolve.Fusion().GetRegList() path for Gyroflow id (default ofx.xyz.gyroflow)
  - clip.GetFusionCompByIndex(1) after LoadFusionCompByName
  - Composition.AddTool(gyroflow_id, x, y)
  - tool.SetInput("ProjectPath", absolute_path) and GetInput("ProjectPath")

Usage (from Workspace > Scripts or external Python with env set):
  python3 resolve_gyroflow_strategy_a_smoke_test.py /path/to/test.gyroflow

If no path is given, uses a non-existent path (tests SetInput only).

Exit codes: 0 = success, 1 = failure (Resolve not running or API error).
"""

from __future__ import annotations

import os
import sys

# Reuse discovery + defaults from the main automation script
from resolve_gyroflow_timeline import (
    DEFAULT_GYROFLOW_OFX_ID,
    discover_gyroflow_tool_id,
    add_gyroflow_tool,
    ensure_project,
    get_resolve,
    set_gyroflow_project_path,
)


def _first_video_clip(timeline):
    try:
        n = timeline.GetTrackCount("video")
    except Exception:
        return None
    for i in range(1, int(n) + 1):
        try:
            items = timeline.GetItemListInTrack("video", i)
        except Exception:
            continue
        if items:
            return items[0]
    return None


def main() -> int:
    test_path = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else "/tmp/gyroflow_smoke_test.gyroflow"

    resolve = get_resolve()
    ensure_project(resolve, None, log=print)

    project = resolve.GetProjectManager().GetCurrentProject()
    timeline = project.GetCurrentTimeline()
    if not timeline:
        print("ERROR: no current timeline — open a timeline with at least one clip.")
        return 1

    clip = _first_video_clip(timeline)
    if not clip:
        print("ERROR: no video clips on timeline.")
        return 1

    if clip.GetFusionCompCount() < 1:
        clip.AddFusionComp()

    names = clip.GetFusionCompNameList()
    if names:
        clip.LoadFusionCompByName(names[0])

    comp = clip.GetFusionCompByIndex(1)
    if not comp:
        print("ERROR: GetFusionCompByIndex(1) is None")
        return 1

    resolve.OpenPage("fusion")
    fusion = resolve.Fusion()
    tool_id = discover_gyroflow_tool_id(fusion, log=print)
    print(f"INFO: registry id for AddTool: {tool_id!r} (default {DEFAULT_GYROFLOW_OFX_ID!r})")

    gyro = add_gyroflow_tool(comp, tool_id, log=print)
    if not gyro:
        print("ERROR: AddTool returned None")
        return 1

    if not set_gyroflow_project_path(gyro, test_path, log=print):
        return 1

    gi = getattr(gyro, "GetInput", None)
    if callable(gi):
        try:
            v = gi("ProjectPath")
            print(f"OK: GetInput('ProjectPath') -> {v!r}")
        except Exception as e:
            print(f"WARN: GetInput('ProjectPath'): {e}")

    print("OK: smoke test passed (AddTool + ProjectPath).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
