"""Fixtures communes : chaque test travaille dans un dossier temporaire, sans matériel ni Internet."""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest
from PIL import Image, ImageDraw

from app import create_app
from config import load_config

ROOT = Path(__file__).resolve().parents[1]
ADMIN_PIN = "2468"
SERVER_TOKEN = "token-de-test-0123456789"


def make_photo(path: Path, size: tuple[int, int] = (1920, 1280), color: tuple[int, int, int] = (30, 120, 200)) -> Path:
    """Photo de test : fond uni et carré jaune au centre."""
    image = Image.new("RGB", size, color)
    center_x, center_y = size[0] // 2, size[1] // 2
    ImageDraw.Draw(image).rectangle((center_x - 50, center_y - 50, center_x + 50, center_y + 50), fill=(255, 230, 0))
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format="JPEG", quality=92)
    return path


def make_frame(
    folder: Path, size: tuple[int, int] = (1200, 1800), border: int = 60, config: dict[str, Any] | None = None
) -> Path:
    """Cadre de test : bordure rouge opaque, centre transparent."""
    folder.mkdir(parents=True, exist_ok=True)
    frame = Image.new("RGBA", size, (255, 0, 0, 255))
    ImageDraw.Draw(frame).rectangle((border, border, size[0] - border - 1, size[1] - border - 1), fill=(0, 0, 0, 0))
    frame.save(folder / "frame.png")
    if config is not None:
        (folder / "config.json").write_text(json.dumps(config), encoding="utf-8")
    return folder


def decode_qr(image: Image.Image) -> str:
    """Décode un QR code avec OpenCV (marge blanche ajoutée pour une détection fiable)."""
    import cv2
    import numpy as np

    gray = np.array(image.convert("L"))
    padded = np.pad(gray, 40, constant_values=255)
    value, _points, _ = cv2.QRCodeDetector().detectAndDecode(padded)
    return value


@pytest.fixture
def config(tmp_path: Path):
    frames_dir = tmp_path / "frames"
    make_frame(frames_dir / "rouge", config={"name": "Cadre rouge", "order": 1})
    return load_config(
        env_file=None,
        data_dir=tmp_path / "data",
        database_path=tmp_path / "db" / "photobooth.db",
        log_dir=tmp_path / "logs",
        frames_dir=frames_dir,
        test_photo=make_photo(tmp_path / "assets" / "test_photo.jpg"),
        camera_mode="mock",
        printer_mode="null",
        printer_simulated_delay=0.0,
        upload_enabled=False,
        admin_pin=ADMIN_PIN,
        secret_key="cle-de-test",
        public_photo_url="https://photos.example.com",
        event_name="Événement de test",
        event_slug="evenement-test",
        event_date="2027-07-05",
        print_max_copies=3,
    )


@pytest.fixture
def app(config):
    application = create_app(config)
    application.testing = True
    yield application
    application.extensions["photobooth"].close()


@pytest.fixture
def client(app):
    return app.test_client()


@pytest.fixture
def services(app):
    return app.extensions["photobooth"]


@pytest.fixture
def admin_client(client):
    response = client.post("/admin/login", json={"pin": ADMIN_PIN})
    assert response.status_code == 200
    return client


def take_photo(client, frame_id: str = "rouge") -> dict[str, Any]:
    """Session complète via l'API de la borne ; renvoie la photo finale."""
    session = client.post("/api/session/start", json={"frame_id": frame_id}).get_json()["session"]
    while True:
        result = client.post("/api/capture", json={"session_id": session["id"]}).get_json()
        assert result["ok"], result
        if result["done"]:
            return result["photo"]


def load_upload_server() -> ModuleType:
    """Charge upload_server/app.py sous un nom unique (pas de conflit avec app.py de la borne)."""
    name = "photobooth_upload_server"
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, ROOT / "upload_server" / "app.py")
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name]


@pytest.fixture
def upload_server(tmp_path: Path):
    module = load_upload_server()
    server_config = module.ServerConfig(
        api_token=SERVER_TOKEN,
        upload_dir=tmp_path / "server" / "uploads",
        database_path=tmp_path / "server" / "photos.db",
        max_upload_mb=2,
        retention_days=30,
        site_name="Photos de test",
        public_base_url="https://photos.example.com",
        lookup_limit=5,
        lookup_window=600,
    )
    server_app = module.create_app(server_config)
    server_app.testing = True
    return module, server_app, server_config
