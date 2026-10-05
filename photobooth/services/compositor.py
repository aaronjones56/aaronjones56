"""Montage des photos avec Pillow.

photo originale (recadrée au bon ratio, sans déformation) + frame.png = photo finale.
Le recadrage est centré (réglable avec CROP_FOCUS_X / CROP_FOCUS_Y) et l'aperçu de
la borne utilise exactement le même calcul : ce que l'on voit est ce que l'on obtient.
"""

from __future__ import annotations

import io
import logging
import math
from collections.abc import Sequence
from functools import lru_cache
from pathlib import Path

from PIL import Image, ImageDraw, ImageOps

from services.fonts import draw_text, load_font, text_size
from services.frames import Frame, QrSpec
from services.utils import atomic_write_bytes

logger = logging.getLogger(__name__)

RESAMPLE = Image.Resampling.LANCZOS
PRINT_DPI = 300
QR_MARGIN = 40
_EXIF_ORIENTATION = 0x0112
_ROTATED_ORIENTATIONS = {5, 6, 7, 8}

Centering = tuple[float, float]


def open_photo(path: Path, target_sizes: Sequence[tuple[int, int]] = ()) -> Image.Image:
    """Ouvre une photo en tenant compte de l'orientation EXIF et la convertit en RGB.

    ``target_sizes`` (tailles des emplacements à remplir) permet au décodeur JPEG de
    réduire l'image dès la lecture : beaucoup plus rapide avec un appareil reflex.
    """
    with Image.open(path) as image:
        if target_sizes and image.format == "JPEG":
            _apply_draft(image, target_sizes)
        oriented = ImageOps.exif_transpose(image)
        return oriented.convert("RGB")


def _apply_draft(image: Image.Image, target_sizes: Sequence[tuple[int, int]]) -> None:
    width, height = image.size
    if image.getexif().get(_EXIF_ORIENTATION, 1) in _ROTATED_ORIENTATIONS:
        width, height = height, width
    scale = max(_cover_scale((width, height), size) for size in target_sizes)
    if scale < 1:
        raw_width, raw_height = image.size
        image.draft("RGB", (math.ceil(raw_width * scale), math.ceil(raw_height * scale)))


def _cover_scale(source: tuple[int, int], target: tuple[int, int]) -> float:
    """Facteur d'échelle pour qu'un recadrage au ratio de ``target`` remplisse ``target``."""
    source_w, source_h = source
    target_w, target_h = target
    ratio = target_w / target_h
    crop_w = min(source_w, source_h * ratio)
    return target_w / crop_w


def fit_cover(image: Image.Image, size: tuple[int, int], centering: Centering = (0.5, 0.5)) -> Image.Image:
    """Recadre au ratio de ``size`` (rien n'est déformé) puis redimensionne."""
    return ImageOps.fit(image, size, method=RESAMPLE, centering=centering)


@lru_cache(maxsize=16)
def _cached_overlay(path: str, mtime_ns: int, size: tuple[int, int]) -> Image.Image:
    with Image.open(path) as source:
        overlay = source.convert("RGBA")
    if overlay.size != size:
        logger.warning("Le cadre %s mesure %sx%s au lieu de %sx%s : il est redimensionné", path, *overlay.size, *size)
        overlay = overlay.resize(size, RESAMPLE)
    return overlay


def load_overlay(path: Path, size: tuple[int, int]) -> Image.Image:
    """Charge frame.png (mis en cache tant que le fichier ne change pas)."""
    return _cached_overlay(str(path), path.stat().st_mtime_ns, size)


def compose(
    shots: Sequence[Path | Image.Image],
    frame: Frame,
    centering: Centering = (0.5, 0.5),
    background: tuple[int, int, int] = (255, 255, 255),
) -> Image.Image:
    """Place chaque photo dans ses emplacements puis superpose le PNG transparent."""
    if len(shots) < frame.shots:
        raise ValueError(f"{frame.shots} photo(s) attendue(s), {len(shots)} fournie(s)")
    canvas = Image.new("RGB", frame.size, background)
    opened: dict[int, Image.Image] = {}
    for slot in frame.slots:
        photo = opened.get(slot.shot)
        if photo is None:
            source = shots[slot.shot]
            if isinstance(source, Image.Image):
                photo = source.convert("RGB")
            else:
                sizes = [(item.width, item.height) for item in frame.slots if item.shot == slot.shot]
                photo = open_photo(source, sizes)
            opened[slot.shot] = photo
        canvas.paste(fit_cover(photo, (slot.width, slot.height), centering), (slot.x, slot.y))
    if frame.overlay_path is not None:
        overlay = load_overlay(frame.overlay_path, frame.size)
        canvas = Image.alpha_composite(canvas.convert("RGBA"), overlay).convert("RGB")
    return canvas


def compose_to_file(
    shots: Sequence[Path | Image.Image],
    frame: Frame,
    output: Path,
    quality: int = 95,
    centering: Centering = (0.5, 0.5),
) -> Path:
    """Crée la photo finale (JPEG 300 dpi, sous-échantillonnage 4:4:4 pour une qualité maximale)."""
    return save_jpeg(compose(shots, frame, centering), output, quality)


def save_jpeg(image: Image.Image, path: Path, quality: int = 95, dpi: int = PRINT_DPI) -> Path:
    buffer = io.BytesIO()
    image.convert("RGB").save(buffer, format="JPEG", quality=quality, subsampling=0, optimize=True, dpi=(dpi, dpi))
    atomic_write_bytes(path, buffer.getvalue())
    return path


def thumbnail_bytes(source: Path, max_size: tuple[int, int] = (400, 600), quality: int = 80) -> bytes:
    """Vignette JPEG en mémoire (aperçu des photos d'une bande, galerie admin)."""
    with Image.open(source) as image:
        if image.format == "JPEG":
            image.draft("RGB", max_size)
        thumb = ImageOps.exif_transpose(image).convert("RGB")
    thumb.thumbnail(max_size, RESAMPLE)
    buffer = io.BytesIO()
    thumb.save(buffer, format="JPEG", quality=quality, optimize=True)
    return buffer.getvalue()


def make_thumbnail(source: Path, target: Path, max_size: tuple[int, int] = (400, 600)) -> Path:
    atomic_write_bytes(target, thumbnail_bytes(source, max_size, quality=82))
    return target


def qr_badge_box(
    image_size: tuple[int, int], size: int, label_height: int, spec: QrSpec | None, position: str
) -> tuple[int, int, int, int]:
    """Position (x, y, largeur, hauteur) du badge QR sur le tirage."""
    padding = max(8, size // 14)
    badge_w = size + 2 * padding
    badge_h = size + 2 * padding + (label_height + padding if label_height else 0)
    if spec is not None and spec.x is not None and spec.y is not None:
        return spec.x - padding, spec.y - padding, badge_w, badge_h
    width, height = image_size
    corner = spec.position if spec is not None else position
    x = QR_MARGIN if corner.endswith("left") else width - QR_MARGIN - badge_w
    y = QR_MARGIN if corner.startswith("top") else height - QR_MARGIN - badge_h
    return x, y, badge_w, badge_h


def add_qr_badge(
    image: Image.Image,
    qr_image: Image.Image,
    label: str,
    spec: QrSpec | None = None,
    size: int = 240,
    position: str = "bottom-right",
) -> Image.Image:
    """Ajoute un badge blanc arrondi contenant le QR code et le code de la photo."""
    size = spec.size if spec is not None else size
    padding = max(8, size // 14)
    font = load_font(max(14, size // 9), bold=True)
    label_w, label_h = text_size(font, label) if label else (0, 0)
    x, y, badge_w, badge_h = qr_badge_box(image.size, size, label_h, spec, position)

    badge = Image.new("RGBA", (badge_w, badge_h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(badge)
    draw.rounded_rectangle((0, 0, badge_w - 1, badge_h - 1), radius=max(10, padding), fill=(255, 255, 255, 245))
    badge.paste(qr_image.convert("RGB").resize((size, size), Image.Resampling.NEAREST), (padding, padding))
    if label:
        draw_text(draw, ((badge_w - label_w) // 2, padding + size + padding // 2), label, font, (34, 34, 40, 255))

    x = max(0, min(x, image.width - badge_w))
    y = max(0, min(y, image.height - badge_h))
    result = image.convert("RGBA")
    result.alpha_composite(badge, (x, y))
    return result.convert("RGB")
