"""Appareils photo : simulation et commande externe (comme un logiciel Canon/Nikon)."""

import sys
from dataclasses import replace
from pathlib import Path

import pytest
from PIL import Image

from services.camera import ExternalCommandCamera, MockCamera, create_camera, render_command
from services.errors import CameraError
from tests.conftest import make_photo

PYTHON = f'"{sys.executable}"'


def test_mock_camera_capture_and_preview(tmp_path: Path):
    camera = MockCamera(make_photo(tmp_path / "test.jpg"))
    output = camera.capture(tmp_path / "out" / "photo.jpg")
    with Image.open(output) as image:
        assert image.size == (1920, 1280)
    assert camera.preview_jpeg()[:2] == b"\xff\xd8"
    assert camera.check().ok


def test_mock_camera_generates_missing_test_photo(tmp_path: Path):
    camera = MockCamera(tmp_path / "absente.jpg")
    camera.capture(tmp_path / "photo.jpg")
    assert (tmp_path / "absente.jpg").is_file()


def test_render_command_replaces_variables(tmp_path: Path):
    output = tmp_path / "originals" / "A7K4Q92XB3LM.jpg"
    command = render_command('capture.exe --output "{output}" --dir "{output_dir}" --name {filename} {stem}', output)
    assert command == f'capture.exe --output "{output}" --dir "{output.parent}" --name A7K4Q92XB3LM.jpg A7K4Q92XB3LM'


def test_external_command_camera(tmp_path: Path):
    source = make_photo(tmp_path / "appareil.jpg")
    command = f'{PYTHON} -c "import shutil, sys; shutil.copy(sys.argv[1], sys.argv[2])" "{source}" "{{output}}"'
    camera = ExternalCommandCamera(command, timeout=30)
    output = camera.capture(tmp_path / "originals" / "photo.jpg")
    assert output.read_bytes() == source.read_bytes()
    assert camera.check().ok


def test_external_command_with_watch_folder(tmp_path: Path):
    source = make_photo(tmp_path / "appareil.jpg")
    watch = tmp_path / "hotfolder"
    watch.mkdir()
    command = (
        f'{PYTHON} -c "import shutil, sys; shutil.copy(sys.argv[1], sys.argv[2])" "{source}" "{watch / "IMG_0001.JPG"}"'
    )
    camera = ExternalCommandCamera(command, timeout=30, watch_dir=watch)
    output = camera.capture(tmp_path / "originals" / "photo.jpg")
    assert output.is_file() and not (watch / "IMG_0001.JPG").exists()


def test_external_command_failure_raises_camera_error(tmp_path: Path):
    camera = ExternalCommandCamera(f'{PYTHON} -c "import sys; sys.exit(2)"', timeout=30)
    with pytest.raises(CameraError, match="code 2"):
        camera.capture(tmp_path / "photo.jpg")


def test_external_command_without_image_raises_camera_error(tmp_path: Path):
    command = f"{PYTHON} -c \"import sys; open(sys.argv[1], 'w').write('pas une image')\" \"{{output}}\""
    camera = ExternalCommandCamera(command, timeout=10)
    with pytest.raises(CameraError):
        camera.capture(tmp_path / "photo.jpg")


def test_unconfigured_external_camera(tmp_path: Path):
    camera = ExternalCommandCamera("", timeout=10)
    assert camera.check().ok is False
    with pytest.raises(CameraError, match="CAMERA_CAPTURE_COMMAND"):
        camera.capture(tmp_path / "photo.jpg")


def test_unknown_camera_mode_falls_back_to_simulation(config):
    assert create_camera(replace(config, camera_mode="canon-inexistant")).mode == "mock"
