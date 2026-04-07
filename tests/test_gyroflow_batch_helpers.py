"""Unit tests for gyroflow_batch_helpers (no Gyroflow/Resolve required)."""

from __future__ import annotations

import json
import os
import tempfile

from gyroflow_batch_helpers import (
    gyroflow_offsets_meet_minimum,
    apply_sync_offset_policy_to_gyroflow_file,
    normalize_gyro_source_after_preset_merge,
    canonical_dng_filenames,
    deep_merge,
    dng_sequence_metadata,
    dng_sequence_videofile_url,
    file_url_from_local_path,
    lens_profile_json_looks_valid,
    trim_offsets_by_max_abs_ms,
)


def test_deep_merge_nested():
    base = {"a": 1, "b": {"x": 1}}
    deep_merge(base, {"b": {"y": 2}, "c": 3})
    assert base == {"a": 1, "b": {"x": 1, "y": 2}, "c": 3}


def test_canonical_dng_ordering():
    with tempfile.TemporaryDirectory() as td:
        for name in ("z_last.DNG", "a_first.dng", "m_mid.Dng"):
            open(os.path.join(td, name), "wb").close()
        names = canonical_dng_filenames(td)
        assert names == ["a_first.dng", "m_mid.Dng", "z_last.DNG"]


def test_file_url_from_local_path_encodes_percent_sign():
    url = file_url_from_local_path("/tmp/foo%bar.dng")
    assert url == "file:///tmp/foo%25bar.dng"


def test_dng_sequence_videofile_url_uses_percent_pattern():
    with tempfile.TemporaryDirectory() as td:
        open(os.path.join(td, "scene_0001.dng"), "wb").close()
        open(os.path.join(td, "scene_0002.dng"), "wb").close()
        url, start = dng_sequence_videofile_url(td)
        # printf token must be %2504d in the URL so Qt does not decode %04
        assert "%2504d" in url
        assert "%04d" not in url
        assert "scene_" in url
        assert start == 1
        assert url.startswith("file://")


def test_dng_sequence_metadata_ext():
    with tempfile.TemporaryDirectory() as td:
        open(os.path.join(td, "shot_001.DNG"), "wb").close()
        m = dng_sequence_metadata(td)
        assert m["count"] == 1
        assert m["ext"] == ".DNG"
        assert m["first_basename"] == "shot_001.DNG"


def test_merge_proxy_offsets_writes(tmp_path):
    proxy = {
        "offsets": {"0": 1.5},
        "synchronization": {"do_autosync": True},
        "gyro_source": {"filepath": "file:///proxy", "file_metadata": "{}"},
    }
    project = {
        "version": 3,
        "gyro_source": {"filepath": "file:///real.gcsv"},
        "offsets": {},
    }
    proxy_path = tmp_path / "p.gyroflow"
    proj_path = tmp_path / "out.gyroflow"
    proxy_path.write_text(json.dumps(proxy), encoding="utf-8")
    proj_path.write_text(json.dumps(project), encoding="utf-8")

    from gyroflow_batch_helpers import merge_proxy_offsets_main

    merge_proxy_offsets_main(str(proxy_path), str(proj_path))
    out = json.loads(proj_path.read_text(encoding="utf-8"))
    assert out["offsets"] == {"0": 1.5}
    assert out["gyro_source"]["filepath"] == "file:///real.gcsv"
    assert out["gyro_source"]["file_metadata"] == "{}"
    assert out["synchronization"]["do_autosync"] is True


def test_merge_proxy_offsets_copies_file_metadata_not_other_gyro_fields(tmp_path):
    proxy = {
        "offsets": {"0": 1.0},
        "gyro_source": {
            "filepath": "file:///proxy.mp4",
            "file_metadata": "would_break_dng_import",
            "imu_orientation": "WRONG",
            "lpf": 99.0,
        },
    }
    project = {
        "version": 3,
        "gyro_source": {
            "filepath": "file:///clip.gcsv",
            "imu_orientation": "XYZ",
            "lpf": 0.0,
        },
        "offsets": {},
    }
    (tmp_path / "px.gyroflow").write_text(json.dumps(proxy), encoding="utf-8")
    outp = tmp_path / "pr.gyroflow"
    outp.write_text(json.dumps(project), encoding="utf-8")

    from gyroflow_batch_helpers import merge_proxy_offsets_main

    merge_proxy_offsets_main(str(tmp_path / "px.gyroflow"), str(outp))
    gs = json.loads(outp.read_text(encoding="utf-8"))["gyro_source"]
    assert gs["filepath"] == "file:///clip.gcsv"
    assert gs["imu_orientation"] == "XYZ"
    assert gs["lpf"] == 0.0
    assert gs["file_metadata"] == "would_break_dng_import"


def test_lens_profile_json_looks_valid_minimal():
    assert not lens_profile_json_looks_valid({})
    assert lens_profile_json_looks_valid(
        {
            "calibrator_version": "1.6.3",
            "calib_dimension": {"w": 1920, "h": 1080},
            "fisheye_params": {"camera_matrix": [[1, 0, 0], [0, 1, 0], [0, 0, 1]]},
        }
    )


def test_trim_offsets_drops_above_max_abs_keeps_endpoints_of_in_range():
    o = {"0": 100.0, "1": 10000.0, "2": -200.0, "3": 50.0}
    assert trim_offsets_by_max_abs_ms(o, 500.0) == {"0": 100.0, "3": 50.0}


def test_trim_offsets_all_in_range_drops_middle():
    o = {"0": 100.0, "1": 200.0, "2": 300.0}
    assert trim_offsets_by_max_abs_ms(o, 500.0) == {"0": 100.0, "2": 300.0}


def test_normalize_gyro_source_after_preset_merge():
    gs = {
        "filepath": "file:///x.gcsv",
        "rotation": None,
        "acc_rotation": None,
        "gyro_bias": None,
        "lpf": None,
        "mf": 0,
    }
    normalize_gyro_source_after_preset_merge(gs)
    assert gs["rotation"] == [0.0, 0.0, 0.0]
    assert gs["acc_rotation"] == [0.0, 0.0, 0.0]
    assert gs["gyro_bias"] == [0.0, 0.0, 0.0]
    assert gs["lpf"] == 0.0
    assert gs["mf"] == 0
    gs2 = {"rotation": [1.0, 2.0, 3.0]}
    normalize_gyro_source_after_preset_merge(gs2)
    assert gs2["rotation"] == [1.0, 2.0, 3.0]


def test_trim_offsets_all_outside_returns_empty():
    assert trim_offsets_by_max_abs_ms({"0": 2000.0, "1": -3000.0}, 500.0) == {}


def test_trim_offsets_negative_within_max():
    assert trim_offsets_by_max_abs_ms({"0": -400.0, "1": 400.0}, 500.0) == {
        "0": -400.0,
        "1": 400.0,
    }


def test_trim_offsets_single_survivor_returns_empty():
    assert trim_offsets_by_max_abs_ms({"2": 100.0, "0": 9000.0, "1": 8000.0}, 500.0) == {}


def test_trim_offsets_non_int_keys_endpoints():
    o = {"0": 100.0, "x": 200.0, "2": 150.0}
    assert trim_offsets_by_max_abs_ms(o, 500.0) == {"0": 100.0, "x": 200.0}


def test_apply_sync_offset_policy_to_gyroflow_file(tmp_path):
    p = tmp_path / "x.gyroflow"
    p.write_text(
        json.dumps({"version": 3, "offsets": {"0": 100.0, "1": 9000.0, "2": 200.0}}),
        encoding="utf-8",
    )
    assert apply_sync_offset_policy_to_gyroflow_file(str(p), 500.0) is True
    out = json.loads(p.read_text(encoding="utf-8"))
    assert out["offsets"] == {"0": 100.0, "2": 200.0}


def test_apply_sync_offset_policy_all_outside_yields_empty_offsets(tmp_path):
    p = tmp_path / "y.gyroflow"
    p.write_text(
        json.dumps({"version": 3, "offsets": {"0": 600.0}}),
        encoding="utf-8",
    )
    assert apply_sync_offset_policy_to_gyroflow_file(str(p), 500.0) is True
    assert json.loads(p.read_text(encoding="utf-8"))["offsets"] == {}


def test_apply_sync_offset_policy_one_in_window_yields_empty_offsets(tmp_path):
    p = tmp_path / "z.gyroflow"
    p.write_text(
        json.dumps({"version": 3, "offsets": {"0": 100.0, "1": 9000.0}}),
        encoding="utf-8",
    )
    assert apply_sync_offset_policy_to_gyroflow_file(str(p), 500.0) is True
    assert json.loads(p.read_text(encoding="utf-8"))["offsets"] == {}


def test_gyroflow_offsets_meet_minimum(tmp_path):
    p = tmp_path / "x.gyroflow"
    p.write_text(
        json.dumps({"version": 3, "offsets": {"0": 1.0, "1": 2.0}}),
        encoding="utf-8",
    )
    assert gyroflow_offsets_meet_minimum(str(p), 2) is True
    assert gyroflow_offsets_meet_minimum(str(p), 3) is False
    p.write_text(json.dumps({"offsets": {"0": 1.0}}), encoding="utf-8")
    assert gyroflow_offsets_meet_minimum(str(p), 2) is False


def test_merge_proxy_offsets_empty_exits_clean(tmp_path, capsys):
    proxy = {"offsets": {}}
    project = {"version": 3, "offsets": {}}
    proxy_path = tmp_path / "p.gyroflow"
    proj_path = tmp_path / "out.gyroflow"
    proxy_path.write_text(json.dumps(proxy), encoding="utf-8")
    proj_path.write_text(json.dumps(project), encoding="utf-8")

    from gyroflow_batch_helpers import merge_proxy_offsets_main

    merge_proxy_offsets_main(str(proxy_path), str(proj_path))
    err = capsys.readouterr().err
    assert "no sync offsets" in err.lower()
    out = json.loads(proj_path.read_text(encoding="utf-8"))
    assert out["offsets"] == {}
