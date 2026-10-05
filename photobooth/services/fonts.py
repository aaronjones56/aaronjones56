"""Choix d'une police TrueType disponible sur la machine (Windows, Linux, macOS)."""

from __future__ import annotations

from functools import lru_cache
from typing import Any

from PIL import ImageDraw, ImageFont

FontType = ImageFont.FreeTypeFont | ImageFont.ImageFont

_CANDIDATES: dict[tuple[bool, bool], tuple[str, ...]] = {
    (False, False): ("segoeui.ttf", "arial.ttf", "DejaVuSans.ttf", "LiberationSans-Regular.ttf", "Helvetica.ttc"),
    (True, False): ("segoeuib.ttf", "arialbd.ttf", "DejaVuSans-Bold.ttf", "LiberationSans-Bold.ttf", "Helvetica.ttc"),
    (False, True): ("georgia.ttf", "times.ttf", "DejaVuSerif.ttf", "LiberationSerif-Regular.ttf", "Times.ttc"),
    (True, True): ("georgiab.ttf", "timesbd.ttf", "DejaVuSerif-Bold.ttf", "LiberationSerif-Bold.ttf", "Times.ttc"),
}


@lru_cache(maxsize=64)
def load_font(size: int, bold: bool = False, serif: bool = False) -> FontType:
    """Renvoie la première police trouvée ; à défaut, la police intégrée à Pillow."""
    for name in _CANDIDATES[(bold, serif)]:
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    try:
        return ImageFont.load_default(size=size)
    except TypeError:  # Pillow < 10.1 : police intégrée sans taille
        return ImageFont.load_default()


def text_size(font: FontType, text: str) -> tuple[int, int]:
    """Largeur et hauteur du texte rendu avec ``font``."""
    left, top, right, bottom = font.getbbox(text)
    return int(right - left), int(bottom - top)


def draw_text(draw: ImageDraw.ImageDraw, position: tuple[float, float], text: str, font: FontType, fill: Any) -> None:
    """Dessine le texte pour que sa zone visible commence exactement à ``position``."""
    left, top, _right, _bottom = font.getbbox(text)
    draw.text((position[0] - left, position[1] - top), text, font=font, fill=fill)


def draw_centered_text(
    draw: ImageDraw.ImageDraw, center_x: float, top: float, text: str, font: FontType, fill: Any
) -> int:
    """Dessine le texte centré horizontalement ; renvoie sa hauteur."""
    width, height = text_size(font, text)
    draw_text(draw, (center_x - width / 2, top), text, font, fill)
    return height
