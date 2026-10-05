"""État des périphériques (caméra, imprimante, stockage) et vérification d'images."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

from PIL import Image, UnidentifiedImageError


@dataclass(frozen=True)
class DeviceStatus:
    """Résultat d'une vérification : utilisable ou non, avec un message lisible.

    ``warning`` signale un appareil utilisable mais à surveiller (disque presque plein…).
    """

    ok: bool
    message: str
    warning: bool = False

    @property
    def state(self) -> str:
        if not self.ok:
            return "error"
        return "warning" if self.warning else "ok"

    def to_dict(self) -> dict[str, Any]:
        return {"ok": self.ok, "message": self.message, "warning": self.warning, "state": self.state}


def is_readable_image(path: Path) -> bool:
    """Vrai si le fichier existe et contient une image JPEG ou PNG valide."""
    try:
        with Image.open(path) as image:
            image_format = image.format
            image.verify()
    except (OSError, UnidentifiedImageError, SyntaxError, ValueError):
        return False
    return image_format in {"JPEG", "PNG", "MPO"}
