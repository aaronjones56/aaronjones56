"""QR codes des photos, générés hors ligne.

Le QR code contient simplement ``PUBLIC_PHOTO_URL/p/CODE`` : il est valable dès la
prise de vue, même si la photo ne sera mise en ligne qu'après l'événement.
"""

from __future__ import annotations

import io
from pathlib import Path

import qrcode
from qrcode.constants import ERROR_CORRECT_M
from PIL import Image

from services.utils import atomic_write_bytes

QR_BORDER = 4  # zone blanche standard (4 modules) : lecture fiable par tous les téléphones


class QrService:
    def __init__(self, public_url: str) -> None:
        self.public_url = public_url.rstrip("/")

    def photo_url(self, code: str) -> str:
        """Lien public de la photo, par exemple https://photos.mondomaine.fr/p/A7K4Q92XB3LM."""
        return f"{self.public_url}/p/{code}"

    @staticmethod
    def make_image(data: str, size: int | None = None, box_size: int = 10) -> Image.Image:
        """Image RGB du QR code ; ``size`` force une taille exacte en pixels."""
        qr = qrcode.QRCode(error_correction=ERROR_CORRECT_M, box_size=box_size, border=QR_BORDER)
        qr.add_data(data)
        qr.make(fit=True)
        if size is not None:
            modules = qr.modules_count + 2 * QR_BORDER
            qr.box_size = max(2, round(size / modules))
        image = qr.make_image(fill_color="black", back_color="white").get_image().convert("RGB")
        if size is not None and image.size != (size, size):
            image = image.resize((size, size), Image.Resampling.NEAREST)
        return image

    def image_for(self, code: str, size: int | None = None) -> Image.Image:
        return self.make_image(self.photo_url(code), size=size)

    def save(self, code: str, path: Path) -> Path:
        """Enregistre qr.png (environ 370 pixels, idéal pour l'écran)."""
        buffer = io.BytesIO()
        self.image_for(code).save(buffer, format="PNG", optimize=True)
        atomic_write_bytes(path, buffer.getvalue())
        return path
