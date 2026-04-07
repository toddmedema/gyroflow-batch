"""Unit tests for resolve_gyroflow_timeline stem mapping (no Resolve required)."""

from __future__ import annotations

import os
import tempfile

import pytest

from resolve_gyroflow_timeline import (
    _fusion_flatten_link_names,
    _fusion_link_name_from_object,
    _fusion_parse_flow_pos,
    _is_usable_fusion_link_name,
    _pair_stem_from_clip_path,
    _timecode_from_total_frames,
    _timeline_frame_to_timecode,
    _total_frames_from_timecode,
)


def test_pair_stem_dng_first_frame_inside_folder():
    with tempfile.TemporaryDirectory() as td:
        folder = os.path.join(td, "260403_145021_VIDEO_25mm")
        os.makedirs(folder)
        first = os.path.join(folder, "clip_0001.dng")
        open(first, "wb").close()
        pairs = [
            {
                "stem": "260403_145021_VIDEO_25mm",
                "media_path": os.path.abspath(folder),
                "gyroflow_path": "/tmp/x.gyroflow",
                "is_sequence": True,
            }
        ]
        assert _pair_stem_from_clip_path(first, pairs) == "260403_145021_VIDEO_25mm"


def test_pair_stem_video_file_exact():
    with tempfile.TemporaryDirectory() as td:
        mp4 = os.path.join(td, "scene_25mm_001.mp4")
        open(mp4, "wb").close()
        ap = os.path.abspath(mp4)
        pairs = [
            {
                "stem": "scene_25mm_001",
                "media_path": ap,
                "gyroflow_path": "/tmp/x.gyroflow",
                "is_sequence": False,
            }
        ]
        assert _pair_stem_from_clip_path(ap, pairs) == "scene_25mm_001"


def test_fusion_flatten_link_names_lua_indexed_dict():
    """GetInputList/GetOutputList may return indexed tables {1.0: 'Source', 2.0: 'Mask'}."""
    assert _fusion_flatten_link_names({1.0: "Source", 2.0: "EffectMask"}) == [
        "Source",
        "EffectMask",
    ]
    assert _fusion_flatten_link_names({1: "Output"}) == ["Output"]


def test_fusion_flatten_link_names_string_keys():
    assert _fusion_flatten_link_names({"Source": None, "Mask": None}) == ["Source", "Mask"]


class _FakeFusionLink:
    """Standalone-in test stand-in for Resolve Fusion input Link objects (dict keys)."""

    def __init__(self, name: str):
        self.Name = name


def test_fusion_flatten_link_names_link_object_keys_like_resolve():
    """Resolve may return GetInputList as {Link: ...}; str(key) is unusable — read .Name."""
    a = _FakeFusionLink("Source")
    b = _FakeFusionLink("EffectMask")
    assert _fusion_flatten_link_names({a: None, b: None}) == ["Source", "EffectMask"]


def test_fusion_link_name_from_object():
    assert _fusion_link_name_from_object(_FakeFusionLink("Input")) == "Input"
    assert _fusion_link_name_from_object("Clip") == "Clip"


def test_is_usable_fusion_link_name_rejects_str_link_repr():
    bad = "Input (0x0x393ee1d00) [App: 'Resolve' on 127.0.0.1, UUID: 33099bc7]"
    assert not _is_usable_fusion_link_name(bad)
    assert _is_usable_fusion_link_name("Source")


def test_fusion_parse_flow_pos_lua_tuple_dict():
    """Lua multi-value tables often appear as {1.0: x, 2.0: y} in Fusion Python."""
    assert _fusion_parse_flow_pos({1.0: -6.0, 2.0: 0.0}) == (-6.0, 0.0)
    assert _fusion_parse_flow_pos({1: 10, 2: 20}) == (10.0, 20.0)


def test_fusion_parse_flow_pos_xy_keys():
    assert _fusion_parse_flow_pos({"X": 1.5, "Y": -2.5}) == (1.5, -2.5)


def test_timeline_frame_to_timecode_24fps():
    assert _timeline_frame_to_timecode(0, 24.0) == "00:00:00:00"
    assert _timeline_frame_to_timecode(24, 24.0) == "00:00:01:00"
    assert _timeline_frame_to_timecode(25, 24.0) == "00:00:01:01"


def test_timeline_frame_to_timecode_25fps():
    assert _timeline_frame_to_timecode(25, 25.0) == "00:00:01:00"


def test_timecode_roundtrip_and_hour_boundary():
    assert _total_frames_from_timecode("00:00:00:00", 24) == 0
    assert _timecode_from_total_frames(24, 24) == "00:00:01:00"
    assert _total_frames_from_timecode("01:00:00:00", 24) == 86400
    assert _timecode_from_total_frames(86400, 24) == "01:00:00:00"
    assert _timecode_from_total_frames(86400 + 24, 24) == "01:00:01:00"


def test_pair_stem_no_match():
    pairs = [
        {
            "stem": "a",
            "media_path": "/other/path",
            "gyroflow_path": "/tmp/x.gyroflow",
            "is_sequence": False,
        }
    ]
    assert _pair_stem_from_clip_path("/nowhere/file.mp4", pairs) is None
