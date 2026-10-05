"""Configuration du photobooth.

Les valeurs sont lues dans le fichier ``.env`` (voir ``.env.example``) puis dans
les variables d'environnement, qui sont prioritaires. Une valeur invalide ne
bloque jamais le démarrage : elle est remplacée par sa valeur par défaut et un
avertissement est écrit dans les journaux.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Any

from dotenv import load_dotenv

from services.utils import is_valid_slug, slugify

APP_NAME = "Photobooth"
APP_VERSION = "1.0.0"
BASE_DIR = Path(__file__).resolve().parent
DEFAULT_ENV_FILE = BASE_DIR / ".env"

CAMERA_BACKENDS = ("auto", "dshow", "msmf", "v4l2", "any")
PRINTER_MODES = ("null", "windows")
PRINT_FIT_MODES = ("fill", "fit")
QR_POSITIONS = ("bottom-right", "bottom-left", "top-right", "top-left")
LOG_LEVELS = ("debug", "info", "warning", "error")

_TRUE_VALUES = {"1", "true", "yes", "on", "oui", "vrai"}
_FALSE_VALUES = {"0", "false", "no", "off", "non", "faux"}
_HEX_COLOR = re.compile(r"^#[0-9a-fA-F]{6}$")


class _EnvReader:
    """Lit des variables d'environnement typées et mémorise les valeurs rejetées."""

    def __init__(self) -> None:
        self.warnings: list[str] = []

    def text(self, name: str, default: str = "") -> str:
        value = os.environ.get(name)
        if value is None or not value.strip():
            return default
        return value.strip()

    def boolean(self, name: str, default: bool) -> bool:
        value = self.text(name).lower()
        if not value:
            return default
        if value in _TRUE_VALUES:
            return True
        if value in _FALSE_VALUES:
            return False
        self.warnings.append(f"{name}={value!r} n'est pas un booléen (true/false) : valeur par défaut {default}.")
        return default

    def integer(self, name: str, default: int, minimum: int, maximum: int) -> int:
        value = self.text(name)
        if not value:
            return default
        try:
            number = int(value)
        except ValueError:
            self.warnings.append(f"{name}={value!r} n'est pas un nombre entier : valeur par défaut {default}.")
            return default
        if not minimum <= number <= maximum:
            self.warnings.append(
                f"{name}={number} doit être compris entre {minimum} et {maximum} : valeur par défaut {default}."
            )
            return default
        return number

    def decimal(self, name: str, default: float, minimum: float, maximum: float) -> float:
        value = self.text(name)
        if not value:
            return default
        try:
            number = float(value.replace(",", "."))
        except ValueError:
            self.warnings.append(f"{name}={value!r} n'est pas un nombre : valeur par défaut {default}.")
            return default
        if not minimum <= number <= maximum:
            self.warnings.append(
                f"{name}={number} doit être compris entre {minimum} et {maximum} : valeur par défaut {default}."
            )
            return default
        return number

    def choice(self, name: str, default: str, choices: tuple[str, ...]) -> str:
        value = self.text(name, default).lower()
        if value not in choices:
            self.warnings.append(f"{name}={value!r} invalide (valeurs possibles : {', '.join(choices)}).")
            return default
        return value

    def path(self, name: str, default: str) -> Path:
        path = Path(self.text(name, default)).expanduser()
        return path if path.is_absolute() else (BASE_DIR / path).resolve()

    def optional_path(self, name: str) -> Path | None:
        value = self.text(name)
        return self.path(name, value) if value else None


@dataclass(frozen=True)
class Config:
    """Configuration complète et typée de la borne."""

    base_dir: Path
    secret_key: str
    admin_pin: str
    host: str
    port: int
    # Appareil photo
    camera_mode: str
    camera_device: int
    camera_backend: str
    camera_width: int
    camera_height: int
    camera_capture_command: str
    camera_capture_timeout: int
    camera_watch_dir: Path | None
    camera_preview_url: str
    test_photo: Path
    preview_mirror: bool
    crop_focus_x: float
    crop_focus_y: float
    # Impression
    printer_mode: str
    printer_name: str
    print_enabled: bool
    print_fit_mode: str
    print_max_copies: int
    print_limit_per_photo: int
    printer_simulated_delay: float
    auto_print: bool
    # Événement par défaut (créé au premier démarrage)
    event_name: str
    event_slug: str
    event_date: str
    # Partage et upload
    public_photo_url: str
    upload_enabled: bool
    upload_api_url: str
    upload_api_token: str
    upload_timeout: int
    photo_retention_days: int
    # Interface
    session_timeout: int
    countdown_seconds: int
    kiosk_title: str
    accent_color: str
    sound_enabled: bool
    # Rendu des photos
    output_width: int
    output_height: int
    jpeg_quality: int
    qr_on_print: bool
    qr_print_size: int
    qr_print_position: str
    # Dossiers et journaux
    data_dir: Path
    frames_dir: Path
    log_dir: Path
    database_path: Path
    log_level: str
    supervised: bool
    warnings: tuple[str, ...] = ()

    @property
    def output_size(self) -> tuple[int, int]:
        return (self.output_width, self.output_height)

    @property
    def crop_centering(self) -> tuple[float, float]:
        return (self.crop_focus_x, self.crop_focus_y)


def load_config(env_file: Path | None = DEFAULT_ENV_FILE, **overrides: Any) -> Config:
    """Charge la configuration depuis ``env_file`` et l'environnement.

    ``overrides`` remplace n'importe quel champ (utilisé par les tests et la ligne
    de commande). ``env_file=None`` ignore le fichier .env.
    """
    env = _EnvReader()
    if env_file is not None and Path(env_file).is_file():
        try:
            load_dotenv(env_file, override=False, encoding="utf-8")
        except UnicodeDecodeError:
            # Fichier enregistré en « ANSI » par un ancien Bloc-notes : on le relit en Windows-1252.
            load_dotenv(env_file, override=False, encoding="cp1252")
            env.warnings.append("Le fichier .env n'est pas en UTF-8 : enregistrez-le en UTF-8 dans le Bloc-notes.")

    event_name = env.text("EVENT_NAME", "Photobooth Test")
    values: dict[str, Any] = {
        "base_dir": BASE_DIR,
        "secret_key": env.text("FLASK_SECRET_KEY"),
        "admin_pin": env.text("ADMIN_PIN", "1234"),
        "host": env.text("HOST", "127.0.0.1"),
        "port": env.integer("PORT", 5000, 1, 65535),
        "camera_mode": env.text("CAMERA_MODE", "mock").lower(),
        "camera_device": env.integer("CAMERA_DEVICE", 0, 0, 20),
        "camera_backend": env.choice("CAMERA_BACKEND", "auto", CAMERA_BACKENDS),
        "camera_width": env.integer("CAMERA_WIDTH", 1920, 160, 8000),
        "camera_height": env.integer("CAMERA_HEIGHT", 1080, 120, 8000),
        "camera_capture_command": env.text("CAMERA_CAPTURE_COMMAND"),
        "camera_capture_timeout": env.integer("CAMERA_CAPTURE_TIMEOUT", 30, 3, 300),
        "camera_watch_dir": env.optional_path("CAMERA_WATCH_DIR"),
        "camera_preview_url": env.text("CAMERA_PREVIEW_URL"),
        "test_photo": env.path("TEST_PHOTO", "static/assets/test_photo.jpg"),
        "preview_mirror": env.boolean("PREVIEW_MIRROR", True),
        "crop_focus_x": env.decimal("CROP_FOCUS_X", 0.5, 0.0, 1.0),
        "crop_focus_y": env.decimal("CROP_FOCUS_Y", 0.5, 0.0, 1.0),
        "printer_mode": env.choice("PRINTER_MODE", "null", PRINTER_MODES),
        "printer_name": env.text("PRINTER_NAME"),
        "print_enabled": env.boolean("PRINT_ENABLED", True),
        "print_fit_mode": env.choice("PRINT_FIT_MODE", "fill", PRINT_FIT_MODES),
        "print_max_copies": env.integer("PRINT_MAX_COPIES", 2, 1, 10),
        "print_limit_per_photo": env.integer("PRINT_LIMIT_PER_PHOTO", 0, 0, 100),
        "printer_simulated_delay": env.decimal("PRINTER_SIMULATED_DELAY", 1.5, 0.0, 30.0),
        "auto_print": env.boolean("AUTO_PRINT", False),
        "event_name": event_name,
        "event_slug": env.text("EVENT_SLUG") or slugify(event_name) or "photobooth",
        "event_date": env.text("EVENT_DATE", date.today().isoformat()),
        "public_photo_url": env.text("PUBLIC_PHOTO_URL", "https://photos.example.com").rstrip("/"),
        "upload_enabled": env.boolean("UPLOAD_ENABLED", False),
        "upload_api_url": env.text("UPLOAD_API_URL"),
        "upload_api_token": env.text("UPLOAD_API_TOKEN"),
        "upload_timeout": env.integer("UPLOAD_TIMEOUT", 60, 5, 600),
        "photo_retention_days": env.integer("PHOTO_RETENTION_DAYS", 30, 0, 3650),
        "session_timeout": env.integer("SESSION_TIMEOUT", 45, 10, 600),
        "countdown_seconds": env.integer("COUNTDOWN_SECONDS", 3, 1, 10),
        "kiosk_title": env.text("KIOSK_TITLE", "PHOTOBOOTH")[:40],
        "accent_color": env.text("ACCENT_COLOR", "#ff3d7f"),
        "sound_enabled": env.boolean("SOUND_ENABLED", True),
        "output_width": env.integer("OUTPUT_WIDTH", 1200, 200, 8000),
        "output_height": env.integer("OUTPUT_HEIGHT", 1800, 200, 8000),
        "jpeg_quality": env.integer("JPEG_QUALITY", 95, 60, 100),
        "qr_on_print": env.boolean("QR_ON_PRINT", False),
        "qr_print_size": env.integer("QR_PRINT_SIZE", 240, 80, 1000),
        "qr_print_position": env.choice("QR_PRINT_POSITION", "bottom-right", QR_POSITIONS),
        "data_dir": env.path("DATA_DIR", "data"),
        "frames_dir": env.path("FRAMES_DIR", "static/frames"),
        "log_dir": env.path("LOG_DIR", "logs"),
        "database_path": env.path("DATABASE_PATH", "database/photobooth.db"),
        "log_level": env.choice("LOG_LEVEL", "info", LOG_LEVELS).upper(),
        "supervised": env.boolean("PHOTOBOOTH_SUPERVISED", False),
    }
    values.update(overrides)
    warnings = [*env.warnings, *_validate(values)]
    values["warnings"] = tuple(warnings)
    return Config(**values)


def _validate(values: dict[str, Any]) -> list[str]:
    """Corrige les valeurs incohérentes et renvoie les avertissements correspondants."""
    warnings: list[str] = []
    pin = str(values["admin_pin"])
    if not pin.isdigit() or not 4 <= len(pin) <= 12:
        warnings.append("ADMIN_PIN doit contenir de 4 à 12 chiffres : le PIN par défaut 1234 est utilisé.")
        values["admin_pin"] = "1234"
    if values["admin_pin"] == "1234":
        warnings.append("Le PIN administrateur est 1234 : changez ADMIN_PIN dans le fichier .env.")
    if not _HEX_COLOR.fullmatch(str(values["accent_color"])):
        warnings.append("ACCENT_COLOR doit être une couleur hexadécimale (#ff3d7f) : couleur par défaut utilisée.")
        values["accent_color"] = "#ff3d7f"
    if not is_valid_slug(str(values["event_slug"])):
        slug = slugify(str(values["event_slug"])) or "photobooth"
        warnings.append(f"EVENT_SLUG invalide : « {slug} » est utilisé à la place.")
        values["event_slug"] = slug
    try:
        date.fromisoformat(str(values["event_date"]))
    except ValueError:
        warnings.append("EVENT_DATE doit être au format AAAA-MM-JJ : la date du jour est utilisée.")
        values["event_date"] = date.today().isoformat()
    if not str(values["public_photo_url"]).startswith(("https://", "http://")):
        warnings.append("PUBLIC_PHOTO_URL doit commencer par https:// : les QR codes risquent d'être inutilisables.")
    return warnings
