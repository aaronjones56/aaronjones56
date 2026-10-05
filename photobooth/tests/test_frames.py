"""Cadres : détection automatique des dossiers, config.json, emplacements multiples."""

import json
from pathlib import Path

from services.assets import generate_sample_frames, generate_test_photo
from services.frames import NO_FRAME_ID, FrameLibrary
from tests.conftest import ROOT, make_frame


def test_frames_are_detected_and_sorted(tmp_path: Path):
    frames_dir = tmp_path / "frames"
    make_frame(frames_dir / "cadre1")
    make_frame(frames_dir / "festicoat", config={"name": "Festi'Coat", "order": 1})
    make_frame(frames_dir / "masque", config={"enabled": False})

    frames = FrameLibrary(frames_dir, (1200, 1800)).scan()

    assert [frame.id for frame in frames] == ["festicoat", "cadre1"]
    assert frames[0].name == "Festi'Coat"
    assert frames[1].name == "Cadre 1"
    assert frames[1].shots == 1 and frames[1].orientation == "portrait"


def test_adding_a_folder_is_enough(tmp_path: Path):
    frames_dir = tmp_path / "frames"
    make_frame(frames_dir / "cadre1")
    library = FrameLibrary(frames_dir, (1200, 1800))
    assert len(library.scan()) == 1
    for index in range(2, 11):
        make_frame(frames_dir / f"cadre{index}")
    assert len(library.scan()) == 10
    assert library.get("cadre7") is not None


def test_size_comes_from_config_or_png(tmp_path: Path):
    frames_dir = tmp_path / "frames"
    make_frame(frames_dir / "paysage", size=(1800, 1200))
    (frames_dir / "config-seule").mkdir(parents=True)
    (frames_dir / "config-seule" / "config.json").write_text(json.dumps({"orientation": "landscape"}), encoding="utf-8")

    frames = {frame.id: frame for frame in FrameLibrary(frames_dir, (1200, 1800)).scan()}

    assert frames["paysage"].size == (1800, 1200) and frames["paysage"].orientation == "landscape"
    assert frames["config-seule"].size == (1800, 1200) and frames["config-seule"].overlay_path is None


def test_photo_slots_define_a_photo_strip(tmp_path: Path):
    slots = [{"x": 40, "y": 40 + index * 500, "width": 520, "height": 480, "shot": index % 3 + 1} for index in range(3)]
    slots += [
        {"x": 640, "y": 40 + index * 500, "width": 520, "height": 480, "shot": index % 3 + 1} for index in range(3)
    ]
    make_frame(tmp_path / "frames" / "bande", config={"photo_slots": slots})

    frame = FrameLibrary(tmp_path / "frames", (1200, 1800)).scan()[0]

    assert frame.shots == 3
    assert len(frame.slots) == 6
    assert frame.shot_size(0) == (520, 480)
    assert frame.to_public_dict()["shot_sizes"] == [[520, 480]] * 3


def test_invalid_frames_are_reported_not_fatal(tmp_path: Path):
    frames_dir = tmp_path / "frames"
    make_frame(frames_dir / "correct")
    (frames_dir / "json-casse").mkdir()
    (frames_dir / "json-casse" / "config.json").write_text("{ name: ", encoding="utf-8")
    make_frame(frames_dir / "hors-cadre", config={"photo_slots": [{"x": 900, "y": 0, "width": 600, "height": 600}]})
    (frames_dir / "vide").mkdir()

    library = FrameLibrary(frames_dir, (1200, 1800))
    frames = library.scan()

    assert [frame.id for frame in frames] == ["correct"]
    assert len(library.errors) == 3


def test_plain_frame_when_no_frame_exists(tmp_path: Path):
    frames = FrameLibrary(tmp_path / "absent", (1200, 1800)).scan()
    assert [frame.id for frame in frames] == [NO_FRAME_ID]
    assert frames[0].overlay_path is None


def test_bundled_sample_frames_are_valid():
    library = FrameLibrary(ROOT / "static" / "frames", (1200, 1800))
    frames = {frame.id: frame for frame in library.scan()}
    assert library.errors == []
    assert {"cadre1", "cadre2", "cadre3", "photomaton"} <= set(frames)
    assert frames["photomaton"].shots == 3
    assert all(frame.preview_path is not None for frame in frames.values())


def test_sample_frames_can_be_regenerated(tmp_path: Path):
    test_photo = generate_test_photo(tmp_path / "test_photo.jpg")
    created = generate_sample_frames(tmp_path / "frames", test_photo)
    library = FrameLibrary(tmp_path / "frames", (1200, 1800))
    assert sorted(created) == ["cadre1", "cadre2", "cadre3", "photomaton"]
    assert len(library.scan()) == 4 and library.errors == []
