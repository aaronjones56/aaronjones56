"""Détection automatique des cadres présents dans ``static/frames/``.

Chaque sous-dossier est un cadre :

    static/frames/festicoat/
        frame.png      calque transparent posé sur la photo (facultatif)
        preview.jpg    vignette affichée sur la borne (générée si absente)
        config.json    réglages (facultatif)

Exemple de config.json :

    {
        "name": "Festi'Coat",
        "enabled": true,
        "order": 10,
        "orientation": "portrait",
        "width": 1200,
        "height": 1800,
        "photo_slots": [{"x": 60, "y": 60, "width": 1080, "height": 1440}],
        "qr": {"x": 940, "y": 1540, "size": 220}
    }

Sans ``photo_slots``, la photo occupe toute la surface (sous le PNG). Avec
plusieurs emplacements, la borne prend plusieurs photos (mode photomaton) ;
``shot`` (1, 2, 3…) indique quelle photo va dans quel emplacement.
"""

from __future__ import annotations

import json
import logging
import re
import threading
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from PIL import Image, UnidentifiedImageError

logger = logging.getLogger(__name__)

FRAME_FILE = "frame.png"
PREVIEW_FILES = ("preview.jpg", "preview.jpeg", "preview.png")
CONFIG_FILE = "config.json"
NO_FRAME_ID = "sans-cadre"
MAX_SHOTS = 6
QR_POSITIONS = ("bottom-right", "bottom-left", "top-right", "top-left")
_FRAME_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")


class FrameConfigError(ValueError):
    """config.json ou frame.png incorrect : le cadre est ignoré et l'erreur affichée dans l'admin."""


@dataclass(frozen=True)
class Slot:
    """Emplacement d'une photo dans le cadre (pixels) ; ``shot`` commence à 0."""

    x: int
    y: int
    width: int
    height: int
    shot: int = 0

    def to_dict(self) -> dict[str, int]:
        return asdict(self)


@dataclass(frozen=True)
class QrSpec:
    """Position du QR code sur le tirage : coordonnées fixes ou coin de l'image."""

    size: int
    x: int | None = None
    y: int | None = None
    position: str = "bottom-right"


@dataclass(frozen=True)
class Frame:
    id: str
    name: str
    width: int
    height: int
    slots: tuple[Slot, ...]
    folder: Path | None = None
    overlay_path: Path | None = None
    preview_path: Path | None = None
    qr: QrSpec | None = None
    order: int = 100
    version: str = "0"

    @property
    def size(self) -> tuple[int, int]:
        return (self.width, self.height)

    @property
    def shots(self) -> int:
        """Nombre de photos à prendre pour ce cadre."""
        return max(slot.shot for slot in self.slots) + 1

    @property
    def orientation(self) -> str:
        if self.width == self.height:
            return "square"
        return "portrait" if self.height > self.width else "landscape"

    def shot_size(self, shot: int) -> tuple[int, int]:
        """Taille du premier emplacement d'une photo (sert au cadrage de l'aperçu)."""
        slot = next(slot for slot in self.slots if slot.shot == shot)
        return (slot.width, slot.height)

    def to_public_dict(self) -> dict[str, Any]:
        """Description envoyée à l'interface de la borne."""
        return {
            "id": self.id,
            "name": self.name,
            "width": self.width,
            "height": self.height,
            "orientation": self.orientation,
            "shots": self.shots,
            "slots": [slot.to_dict() for slot in self.slots],
            "shot_sizes": [list(self.shot_size(shot)) for shot in range(self.shots)],
            "preview_url": f"/frames/{self.id}/preview?v={self.version}",
            "overlay_url": f"/frames/{self.id}/overlay?v={self.version}" if self.overlay_path else None,
        }


class FrameLibrary:
    """Analyse le dossier des cadres ; ajouter un dossier suffit, sans toucher au code."""

    def __init__(self, frames_dir: Path, default_size: tuple[int, int]) -> None:
        self.frames_dir = frames_dir
        self.default_size = default_size
        self.errors: list[str] = []
        self._frames: dict[str, Frame] = {}
        self._lock = threading.Lock()

    def scan(self) -> list[Frame]:
        """Relit le dossier ; renvoie les cadres actifs triés (ordre puis nom)."""
        frames: list[Frame] = []
        errors: list[str] = []
        if self.frames_dir.is_dir():
            for folder in sorted(path for path in self.frames_dir.iterdir() if path.is_dir()):
                if folder.name.startswith((".", "_")):
                    continue
                try:
                    frame = self._load_frame(folder)
                except FrameConfigError as exc:
                    errors.append(f"{folder.name} : {exc}")
                    logger.warning("Cadre ignoré (%s) : %s", folder.name, exc)
                    continue
                if frame is not None:
                    frames.append(frame)
        if not frames:
            frames.append(self._plain_frame())
        frames.sort(key=lambda item: (item.order, item.name.lower()))
        with self._lock:
            self._frames = {frame.id: frame for frame in frames}
            self.errors = errors
        return frames

    def list(self) -> list[Frame]:
        with self._lock:
            frames = list(self._frames.values())
        return frames or self.scan()

    def get(self, frame_id: str, rescan: bool = True) -> Frame | None:
        """Cadre par identifiant ; s'il est inconnu, le dossier est relu (cadre ajouté entre-temps)."""
        with self._lock:
            frame = self._frames.get(frame_id)
        if frame is None and rescan:
            frame = next((item for item in self.scan() if item.id == frame_id), None)
        return frame

    def _plain_frame(self) -> Frame:
        width, height = self.default_size
        return Frame(id=NO_FRAME_ID, name="Sans cadre", width=width, height=height, slots=(Slot(0, 0, width, height),))

    def _load_frame(self, folder: Path) -> Frame | None:
        if not _FRAME_ID_PATTERN.fullmatch(folder.name):
            raise FrameConfigError("nom de dossier invalide (lettres, chiffres, - et _ uniquement)")
        config_path = folder / CONFIG_FILE
        config = _read_config(config_path)
        if not config.get("enabled", True):
            return None
        overlay = folder / FRAME_FILE
        overlay_path = overlay if overlay.is_file() else None
        preview_path = next((folder / name for name in PREVIEW_FILES if (folder / name).is_file()), None)
        if overlay_path is None and not config_path.is_file():
            raise FrameConfigError(f"ni {FRAME_FILE} ni {CONFIG_FILE} dans le dossier")

        overlay_size = _overlay_size(overlay_path) if overlay_path else None
        width, height = self._resolve_size(config, overlay_size)
        files = [path for path in (overlay_path, preview_path, config_path) if path and path.is_file()]
        version = str(max(int(path.stat().st_mtime) for path in files)) if files else "0"
        return Frame(
            id=folder.name,
            name=str(config.get("name") or _prettify(folder.name))[:60],
            width=width,
            height=height,
            slots=_parse_slots(config.get("photo_slots"), width, height),
            folder=folder,
            overlay_path=overlay_path,
            preview_path=preview_path,
            qr=_parse_qr(config.get("qr"), width, height),
            order=_as_int(config.get("order", 100), "order"),
            version=version,
        )

    def _resolve_size(self, config: dict[str, Any], overlay_size: tuple[int, int] | None) -> tuple[int, int]:
        """Taille du montage : config.json, sinon taille de frame.png, sinon OUTPUT_WIDTH x OUTPUT_HEIGHT."""
        if "width" in config or "height" in config:
            width = _as_int(config.get("width"), "width")
            height = _as_int(config.get("height"), "height")
        elif overlay_size is not None:
            width, height = overlay_size
        else:
            width, height = self.default_size
            orientation = config.get("orientation")
            if (orientation == "landscape" and width < height) or (orientation == "portrait" and width > height):
                width, height = height, width
        if not (100 <= width <= 8000 and 100 <= height <= 8000):
            raise FrameConfigError("dimensions hors limites (100 à 8000 pixels)")
        return width, height


def _read_config(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeDecodeError) as exc:
        raise FrameConfigError(f"{CONFIG_FILE} illisible ({exc})") from exc
    except json.JSONDecodeError as exc:
        raise FrameConfigError(f"{CONFIG_FILE} invalide (ligne {exc.lineno}) : {exc.msg}") from exc
    if not isinstance(data, dict):
        raise FrameConfigError(f"{CONFIG_FILE} doit contenir un objet JSON {{ … }}")
    return data


def _overlay_size(path: Path) -> tuple[int, int]:
    try:
        with Image.open(path) as image:
            if image.format != "PNG":
                raise FrameConfigError(f"{FRAME_FILE} doit être une image PNG")
            has_alpha = image.mode in {"RGBA", "LA", "PA"} or "transparency" in image.info
            size = image.size
    except (OSError, UnidentifiedImageError) as exc:
        raise FrameConfigError(f"{FRAME_FILE} illisible") from exc
    if not has_alpha:
        logger.warning("%s n'a pas de transparence : il masquera entièrement la photo", path)
    return size


def _parse_slots(raw: Any, width: int, height: int) -> tuple[Slot, ...]:
    if raw is None:
        return (Slot(0, 0, width, height),)
    if not isinstance(raw, list) or not raw:
        raise FrameConfigError("photo_slots doit être une liste d'emplacements")
    slots: list[Slot] = []
    for index, item in enumerate(raw):
        if not isinstance(item, dict):
            raise FrameConfigError(f"photo_slots[{index}] doit être un objet {{x, y, width, height}}")
        slot = Slot(
            x=_as_int(item.get("x", 0), "x"),
            y=_as_int(item.get("y", 0), "y"),
            width=_as_int(item.get("width"), "width"),
            height=_as_int(item.get("height"), "height"),
            shot=_as_int(item.get("shot", index + 1), "shot") - 1,
        )
        if slot.width <= 0 or slot.height <= 0 or slot.shot < 0:
            raise FrameConfigError(f"photo_slots[{index}] : dimensions et numéro de photo positifs attendus")
        if slot.x < 0 or slot.y < 0 or slot.x + slot.width > width or slot.y + slot.height > height:
            raise FrameConfigError(f"photo_slots[{index}] dépasse du cadre ({width}x{height})")
        slots.append(slot)
    shots = sorted({slot.shot for slot in slots})
    if shots != list(range(len(shots))):
        raise FrameConfigError("les numéros de photo (shot) doivent se suivre : 1, 2, 3…")
    if len(shots) > MAX_SHOTS:
        raise FrameConfigError(f"{MAX_SHOTS} photos maximum par cadre")
    return tuple(slots)


def _parse_qr(raw: Any, width: int, height: int) -> QrSpec | None:
    if raw is None:
        return None
    if not isinstance(raw, dict):
        raise FrameConfigError("qr doit être un objet {size, x, y} ou {size, position}")
    size = _as_int(raw.get("size", 240), "qr.size")
    if not 60 <= size <= min(width, height):
        raise FrameConfigError("qr.size hors limites")
    position = str(raw.get("position", "bottom-right"))
    if position not in QR_POSITIONS:
        raise FrameConfigError(f"qr.position doit valoir {', '.join(QR_POSITIONS)}")
    if ("x" in raw) != ("y" in raw):
        raise FrameConfigError("qr : x et y doivent être indiqués ensemble")
    if "x" in raw:
        x, y = _as_int(raw["x"], "qr.x"), _as_int(raw["y"], "qr.y")
        if x < 0 or y < 0 or x + size > width or y + size > height:
            raise FrameConfigError("qr dépasse du cadre")
        return QrSpec(size=size, x=x, y=y, position=position)
    return QrSpec(size=size, position=position)


def _as_int(value: Any, name: str) -> int:
    if isinstance(value, bool) or value is None:
        raise FrameConfigError(f"{name} doit être un nombre entier")
    try:
        number = int(value)
    except (TypeError, ValueError) as exc:
        raise FrameConfigError(f"{name} doit être un nombre entier") from exc
    if isinstance(value, float) and value != number:
        raise FrameConfigError(f"{name} doit être un nombre entier")
    return number


def _prettify(folder_name: str) -> str:
    """« cadre1 » devient « Cadre 1 », « soiree_gala » devient « Soiree gala »."""
    text = re.sub(r"[-_]+", " ", folder_name)
    text = re.sub(r"(?<=[A-Za-z])(?=\d)", " ", text).strip()
    return text[:1].upper() + text[1:]
