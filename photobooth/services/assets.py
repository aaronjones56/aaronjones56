"""Génération des images d'exemple : photo de test, cadres, vignettes et mire d'impression.

Utilisé par ``python manage.py generate-assets`` et automatiquement lorsque la
photo de test ou une vignette de cadre est absente.
"""

from __future__ import annotations

import json
import logging
import random
from datetime import datetime
from itertools import pairwise
from pathlib import Path
from typing import Any

from PIL import Image, ImageDraw, ImageFilter, ImageOps

from services import compositor
from services.fonts import draw_centered_text, draw_text, load_font, text_size
from services.frames import Frame, FrameLibrary
from services.utils import atomic_write_bytes

logger = logging.getLogger(__name__)

Color = tuple[int, int, int]
CANVAS = (1200, 1800)
PREVIEW_SIZE = (480, 720)


# --- Photo de test --------------------------------------------------------------


def _vertical_gradient(size: tuple[int, int], stops: list[tuple[float, Color]]) -> Image.Image:
    width, height = size
    column = Image.new("RGB", (1, height))
    for y in range(height):
        position = y / max(1, height - 1)
        for (start, color_a), (end, color_b) in pairwise(stops):
            if start <= position <= end:
                ratio = (position - start) / max(1e-6, end - start)
                column.putpixel(
                    (0, y), tuple(round(a + (b - a) * ratio) for a, b in zip(color_a, color_b, strict=True))
                )
                break
    return column.resize(size)


def _draw_guest(
    draw: ImageDraw.ImageDraw, center_x: float, ground_y: float, scale: float, palette: dict[str, Color]
) -> None:
    """Petit personnage stylisé (corps, tête, chapeau de fête) pour la photo de test."""
    body_w, body_h = 290 * scale, 330 * scale
    draw.rounded_rectangle(
        (center_x - body_w / 2, ground_y - body_h, center_x + body_w / 2, ground_y + 60 * scale),
        radius=int(120 * scale),
        fill=palette["shirt"],
    )
    radius = 112 * scale
    head_y = ground_y - body_h - radius + 34 * scale
    draw.ellipse((center_x - radius, head_y - radius, center_x + radius, head_y + radius), fill=palette["skin"])
    eye_dx, eye_y, eye_r = 38 * scale, head_y - 12 * scale, 12 * scale
    for side in (-1, 1):
        x = center_x + side * eye_dx
        draw.ellipse((x - eye_r, eye_y - eye_r, x + eye_r, eye_y + eye_r), fill=(45, 30, 45))
        cheek_x = center_x + side * 66 * scale
        draw.ellipse(
            (cheek_x - 18 * scale, head_y + 18 * scale, cheek_x + 18 * scale, head_y + 40 * scale),
            fill=palette["cheek"],
        )
    draw.arc(
        (center_x - 52 * scale, head_y - 14 * scale, center_x + 52 * scale, head_y + 58 * scale),
        start=25,
        end=155,
        fill=(70, 30, 45),
        width=max(2, int(9 * scale)),
    )
    hat_base = head_y - radius + 28 * scale
    hat_top = hat_base - 170 * scale
    draw.polygon(
        [(center_x, hat_top), (center_x - 72 * scale, hat_base), (center_x + 72 * scale, hat_base)], fill=palette["hat"]
    )
    for step in range(1, 4):
        y = hat_top + (hat_base - hat_top) * step / 4
        half = 72 * scale * step / 4
        draw.line((center_x - half, y, center_x + half, y), fill=(255, 255, 255), width=max(2, int(7 * scale)))
    pompom = 26 * scale
    draw.ellipse((center_x - pompom, hat_top - pompom, center_x + pompom, hat_top + pompom), fill=(255, 255, 255))


def generate_test_photo(path: Path, size: tuple[int, int] = (1920, 1280)) -> Path:
    """Photo de test 3:2 (comme un reflex) : invités stylisés au centre, décor de soirée."""
    width, height = size
    image = _vertical_gradient(size, [(0.0, (38, 22, 86)), (0.55, (196, 64, 128)), (1.0, (255, 160, 102))])
    image = image.convert("RGBA")

    rng = random.Random(42)
    bokeh = Image.new("RGBA", size, (0, 0, 0, 0))
    bokeh_draw = ImageDraw.Draw(bokeh)
    lights = [(255, 214, 102), (255, 120, 170), (140, 200, 255), (255, 255, 255), (190, 140, 255)]
    for _ in range(70):
        radius = rng.randint(18, 85)
        x, y = rng.randint(0, width), rng.randint(0, int(height * 0.75))
        color = rng.choice(lights)
        bokeh_draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=(*color, rng.randint(50, 130)))
    image = Image.alpha_composite(image, bokeh.filter(ImageFilter.GaussianBlur(radius=10)))

    draw = ImageDraw.Draw(image)
    floor_top = int(height * 0.82)
    draw.ellipse((width * 0.2, floor_top - 40, width * 0.8, height + 160), fill=(40, 18, 60, 120))
    guests = [
        (
            width / 2 - 270,
            0.9,
            {"shirt": (255, 196, 0), "skin": (242, 196, 160), "cheek": (240, 150, 140), "hat": (0, 190, 200)},
        ),
        (
            width / 2 + 270,
            0.9,
            {"shirt": (0, 178, 140), "skin": (156, 104, 72), "cheek": (190, 110, 100), "hat": (255, 90, 120)},
        ),
        (
            width / 2,
            1.05,
            {"shirt": (255, 84, 112), "skin": (226, 172, 132), "cheek": (230, 130, 120), "hat": (255, 210, 60)},
        ),
    ]
    for center_x, scale, palette in guests:
        _draw_guest(draw, center_x, floor_top + 40, scale, palette)

    font = load_font(70, bold=True)
    label = "PHOTO TEST"
    label_w, label_h = text_size(font, label)
    label_x, label_y = (width - label_w) / 2, 64
    draw_text(draw, (label_x + 4, label_y + 4), label, font, (40, 10, 50, 160))
    draw_text(draw, (label_x, label_y), label, font, (255, 255, 255, 255))

    compositor.save_jpeg(image.convert("RGB"), path, quality=92, dpi=72)
    logger.info("Photo de test générée : %s", path)
    return path


# --- Cadres d'exemple ------------------------------------------------------------


def _transparent(size: tuple[int, int] = CANVAS) -> Image.Image:
    return Image.new("RGBA", size, (0, 0, 0, 0))


def _cut_windows(image: Image.Image, slots: list[dict[str, int]], radius: int) -> None:
    """Rend transparents les emplacements des photos (coins arrondis)."""
    mask = Image.new("L", image.size, 255)
    mask_draw = ImageDraw.Draw(mask)
    for slot in slots:
        box = (slot["x"], slot["y"], slot["x"] + slot["width"] - 1, slot["y"] + slot["height"] - 1)
        mask_draw.rounded_rectangle(box, radius=radius, fill=0)
    alpha = Image.composite(image.getchannel("A"), Image.new("L", image.size, 0), mask)
    image.putalpha(alpha)


def _shadowed_text(
    image: Image.Image, position: tuple[float, float], text: str, font: Any, color: tuple[int, ...]
) -> None:
    """Texte avec une ombre douce, lisible sur n'importe quelle photo."""
    shadow = _transparent(image.size)
    draw_text(ImageDraw.Draw(shadow), (position[0], position[1] + 5), text, font, (0, 0, 0, 150))
    image.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(6)))
    draw_text(ImageDraw.Draw(image), position, text, font, color)


def _diamond(draw: ImageDraw.ImageDraw, center: tuple[float, float], radius: float, fill: tuple[int, ...]) -> None:
    x, y = center
    draw.polygon([(x, y - radius), (x + radius, y), (x, y + radius), (x - radius, y)], fill=fill)


def _camera_icon(draw: ImageDraw.ImageDraw, left: float, top: float, size: int, color: tuple[int, ...]) -> None:
    """Pictogramme d'appareil photo (recouvert par le QR code quand QR_ON_PRINT est actif)."""
    line = max(3, size // 16)
    body_top = top + size * 0.18
    body_bottom = body_top + size * 0.68
    draw.rounded_rectangle(
        (left + size * 0.3, top, left + size * 0.62, body_top + line),
        radius=int(size * 0.06),
        outline=color,
        width=line,
    )
    draw.rounded_rectangle(
        (left, body_top, left + size, body_bottom), radius=int(size * 0.14), outline=color, width=line
    )
    center_x, center_y, radius = left + size / 2, (body_top + body_bottom) / 2, size * 0.2
    draw.ellipse(
        (center_x - radius, center_y - radius, center_x + radius, center_y + radius), outline=color, width=line
    )


def frame_classic() -> tuple[Image.Image, dict[str, Any]]:
    """Cadre 1 : bordure blanche et bandeau « Merci d'être venus ! » (QR code à droite du bandeau)."""
    width, height = CANVAS
    slot = {"x": 60, "y": 60, "width": 1080, "height": 1440}
    image = Image.new("RGBA", CANVAS, (255, 255, 255, 255))
    _cut_windows(image, [slot], radius=22)
    draw = ImageDraw.Draw(image)
    accent = (255, 61, 127, 255)
    draw.rounded_rectangle((66, 1570, 186, 1576), radius=3, fill=accent)
    draw_text(draw, (64, 1604), "Merci d'être venus !", load_font(66, bold=True), (32, 30, 44, 255))
    draw_text(draw, (68, 1712), "P H O T O B O O T H", load_font(28), (140, 136, 156, 255))
    _camera_icon(draw, 990, 1590, 120, (255, 61, 127, 110))
    config = {
        "name": "Classique",
        "enabled": True,
        "order": 10,
        "orientation": "portrait",
        "width": width,
        "height": height,
        "photo_slots": [slot],
        "qr": {"size": 190, "x": 937, "y": 1556},
    }
    return image, config


def frame_party() -> tuple[Image.Image, dict[str, Any]]:
    """Cadre 2 : confettis colorés et « C'est la fête ! » (photo plein cadre)."""
    width, height = CANVAS
    image = _transparent()
    rng = random.Random(2027)
    colors = [(255, 61, 127), (255, 196, 0), (0, 200, 220), (126, 87, 255), (46, 212, 122), (255, 120, 60)]
    band = 150
    for _ in range(420):
        side = rng.choice(("top", "bottom", "left", "right", "left", "right"))
        if side == "top":
            x, y = rng.uniform(0, width), rng.uniform(0, band)
        elif side == "bottom":
            x, y = rng.uniform(0, width), height - rng.uniform(0, band * 1.2)
        elif side == "left":
            x, y = rng.uniform(0, band) * rng.random(), rng.uniform(0, height)
        else:
            x, y = width - rng.uniform(0, band) * rng.random(), rng.uniform(0, height)
        color = (*rng.choice(colors), 255)
        piece = _transparent((60, 60))
        piece_draw = ImageDraw.Draw(piece)
        kind = rng.random()
        if kind < 0.45:
            piece_draw.rectangle((18, 24, 18 + rng.randint(14, 26), 24 + rng.randint(7, 11)), fill=color)
        elif kind < 0.8:
            radius = rng.randint(5, 10)
            piece_draw.ellipse((30 - radius, 30 - radius, 30 + radius, 30 + radius), fill=color)
        else:
            piece_draw.arc((10, 14, 50, 46), start=200, end=340, fill=color, width=6)
        piece = piece.rotate(rng.uniform(0, 360), resample=Image.Resampling.BICUBIC)
        image.alpha_composite(piece, (int(x) - 30, int(y) - 30))

    shade = _transparent()
    shade_draw = ImageDraw.Draw(shade)
    for offset in range(380):
        alpha = round(160 * (offset / 380) ** 1.6)
        shade_draw.line((0, height - 380 + offset, width, height - 380 + offset), fill=(20, 8, 40, alpha))
    image = Image.alpha_composite(shade, image)
    _shadowed_text(image, (66, 1598), "C'est la fête !", load_font(88, bold=True), (255, 255, 255, 255))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((24, 24, width - 25, height - 25), radius=28, outline=(255, 255, 255, 230), width=8)
    config = {
        "name": "Festif",
        "enabled": True,
        "order": 20,
        "orientation": "portrait",
        "width": width,
        "height": height,
        "qr": {"size": 200, "x": 946, "y": 1546},
    }
    return image, config


def frame_elegant() -> tuple[Image.Image, dict[str, Any]]:
    """Cadre 3 : noir et or, coins Art déco, « Une soirée inoubliable »."""
    width, height = CANVAS
    gold, gold_light = (212, 175, 55, 255), (240, 214, 140, 255)
    image = _transparent()
    shade_draw = ImageDraw.Draw(image)
    for offset in range(470):
        alpha = round(225 * (offset / 470) ** 1.4)
        shade_draw.line((0, height - 470 + offset, width, height - 470 + offset), fill=(8, 8, 12, alpha))
    draw = ImageDraw.Draw(image)
    draw.rectangle((0, 0, width - 1, height - 1), outline=(10, 10, 14, 255), width=40)
    draw.rectangle((52, 52, width - 53, height - 53), outline=gold, width=5)
    draw.rectangle((66, 66, width - 67, height - 67), outline=gold_light, width=2)
    corners = ((52, 52, 1, 1), (width - 53, 52, -1, 1), (52, height - 53, 1, -1), (width - 53, height - 53, -1, -1))
    for corner_x, corner_y, dx, dy in corners:
        for step in (40, 70, 100):
            draw.line((corner_x + dx * step, corner_y, corner_x + dx * step, corner_y + dy * 26), fill=gold, width=3)
            draw.line((corner_x, corner_y + dy * step, corner_x + dx * 26, corner_y + dy * step), fill=gold, width=3)
        _diamond(draw, (corner_x + dx * 22, corner_y + dy * 22), 13, gold_light)
    draw_text(draw, (112, 1566), "Une soirée", load_font(54, serif=True), gold_light)
    draw_text(draw, (104, 1630), "inoubliable", load_font(92, bold=True, serif=True), gold)
    for index in range(3):
        _diamond(draw, (124 + index * 40, 1752), 8, gold)
    config = {
        "name": "Élégant",
        "enabled": True,
        "order": 30,
        "orientation": "portrait",
        "width": width,
        "height": height,
        "qr": {"size": 180, "x": 920, "y": 1480},
    }
    return image, config


def frame_photo_strip() -> tuple[Image.Image, dict[str, Any]]:
    """Bande photomaton : 3 photos, imprimées en double (2 bandes à découper)."""
    width, height = CANVAS
    image = Image.new("RGBA", CANVAS, (250, 246, 238, 255))
    photo_w, photo_h, top, gap = 520, 484, 40, 24
    slots = [
        {"x": strip_x, "y": top + index * (photo_h + gap), "width": photo_w, "height": photo_h, "shot": index + 1}
        for strip_x in (40, 640)
        for index in range(3)
    ]
    _cut_windows(image, slots, radius=14)
    draw = ImageDraw.Draw(image)
    for y in range(0, height, 28):
        draw.line((width / 2, y, width / 2, y + 14), fill=(205, 198, 186, 255), width=2)
    accent = (255, 61, 127, 255)
    for strip_x in (40, 640):
        draw_text(draw, (strip_x + 6, 1592), "PHOTOMATON", load_font(36, bold=True), (36, 32, 46, 255))
        draw.rounded_rectangle((strip_x + 8, 1656, strip_x + 128, 1661), radius=3, fill=accent)
        draw_text(draw, (strip_x + 8, 1690), "souvenir de la soirée", load_font(24), (130, 124, 140, 255))
        _camera_icon(draw, strip_x + 394, 1598, 100, (255, 61, 127, 110))
    config = {
        "name": "Bande photomaton",
        "enabled": True,
        "order": 40,
        "orientation": "portrait",
        "width": width,
        "height": height,
        "photo_slots": slots,
        "qr": {"size": 170, "x": 976, "y": 1572},
    }
    return image, config


SAMPLE_FRAMES = {
    "cadre1": frame_classic,
    "cadre2": frame_party,
    "cadre3": frame_elegant,
    "photomaton": frame_photo_strip,
}


def _sample_shots(test_photo: Path, count: int) -> list[Image.Image]:
    """Variantes de la photo de test pour illustrer une bande de plusieurs photos."""
    if not test_photo.is_file():
        generate_test_photo(test_photo)
    base = compositor.open_photo(test_photo)
    variants = [base, ImageOps.mirror(base), ImageOps.grayscale(base).convert("RGB")]
    return [variants[index % len(variants)] for index in range(count)]


def render_frame_preview(frame: Frame, test_photo: Path, target: Path, size: tuple[int, int] = PREVIEW_SIZE) -> Path:
    """Vignette d'un cadre : la photo de test montée dans le cadre, réduite."""
    preview = compositor.compose(_sample_shots(test_photo, frame.shots), frame)
    preview.thumbnail(size, Image.Resampling.LANCZOS)
    return compositor.save_jpeg(preview, target, quality=86, dpi=72)


def generate_sample_frames(frames_dir: Path, test_photo: Path, force: bool = False) -> list[str]:
    """Crée les cadres d'exemple (frame.png, config.json, preview.jpg) ; renvoie leurs noms."""
    created: list[str] = []
    for folder_name, builder in SAMPLE_FRAMES.items():
        folder = frames_dir / folder_name
        if (folder / "frame.png").exists() and not force:
            continue
        folder.mkdir(parents=True, exist_ok=True)
        image, config = builder()
        image.save(folder / "frame.png", format="PNG", optimize=True)
        atomic_write_bytes(
            folder / "config.json", (json.dumps(config, indent=4, ensure_ascii=False) + "\n").encode("utf-8")
        )
        (folder / "preview.jpg").unlink(missing_ok=True)
        created.append(folder_name)
    library = FrameLibrary(frames_dir, CANVAS)
    for frame in library.scan():
        if frame.id in created and frame.folder is not None:
            render_frame_preview(frame, test_photo, frame.folder / "preview.jpg")
    return created


# --- Mire d'impression -----------------------------------------------------------


def generate_print_test_card(path: Path, printer_name: str, size: tuple[int, int] = CANVAS) -> Path:
    """Mire 10 x 15 : couleurs, dégradé, repères de bord pour vérifier le cadrage."""
    width, height = size
    image = Image.new("RGB", size, (255, 255, 255))
    draw = ImageDraw.Draw(image)
    unit = width / 1200
    draw.rectangle((0, 0, width - 1, height - 1), outline=(255, 61, 127), width=max(4, int(12 * unit)))
    margin = int(60 * unit)
    for x, y in (
        (margin, margin),
        (width - margin, margin),
        (margin, height - margin),
        (width - margin, height - margin),
    ):
        draw.line((x - 30 * unit, y, x + 30 * unit, y), fill=(0, 0, 0), width=3)
        draw.line((x, y - 30 * unit, x, y + 30 * unit), fill=(0, 0, 0), width=3)

    title_font, text_font = load_font(int(78 * unit), bold=True), load_font(int(36 * unit))
    draw_centered_text(draw, width / 2, 170 * unit, "TEST D'IMPRESSION", title_font, (30, 28, 40))
    draw_centered_text(draw, width / 2, 290 * unit, printer_name[:40], text_font, (90, 86, 100))
    draw_centered_text(draw, width / 2, 345 * unit, f"{datetime.now():%d/%m/%Y %H:%M}", text_font, (90, 86, 100))

    swatches: list[Color] = [
        (0, 255, 255),
        (255, 0, 255),
        (255, 255, 0),
        (0, 0, 0),
        (255, 0, 0),
        (0, 170, 0),
        (0, 80, 255),
        (128, 128, 128),
    ]
    swatch_w = (width - 2 * margin) / 4
    for index, color in enumerate(swatches):
        column, row = index % 4, index // 4
        left = margin + column * swatch_w
        top = 470 * unit + row * 230 * unit
        draw.rounded_rectangle(
            (left + 10, top, left + swatch_w - 10, top + 200 * unit), radius=int(18 * unit), fill=color
        )

    gradient_top, gradient_bottom = int(990 * unit), int(1130 * unit)
    for x in range(margin, width - margin):
        level = round(255 * (x - margin) / (width - 2 * margin))
        draw.line((x, gradient_top, x, gradient_bottom), fill=(level, level, level))

    center = (width / 2, 1420 * unit)
    for ring in range(6, 0, -1):
        radius = ring * 36 * unit
        fill = (255, 61, 127) if ring % 2 else (255, 255, 255)
        draw.ellipse((center[0] - radius, center[1] - radius, center[0] + radius, center[1] + radius), fill=fill)
    draw_centered_text(
        draw,
        width / 2,
        1690 * unit,
        "Le cadre rose doit être visible sur les 4 bords",
        load_font(int(30 * unit)),
        (120, 116, 130),
    )
    compositor.save_jpeg(image, path, quality=95)
    return path


def generate_all(frames_dir: Path, test_photo: Path, force: bool = False) -> dict[str, Any]:
    """Photo de test + cadres d'exemple (utilisé par manage.py generate-assets)."""
    photo_created = False
    if force or not test_photo.is_file():
        generate_test_photo(test_photo)
        photo_created = True
    frames = generate_sample_frames(frames_dir, test_photo, force=force)
    return {"test_photo": photo_created, "frames": frames}
