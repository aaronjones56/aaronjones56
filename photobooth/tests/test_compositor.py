"""Montage : format 2:3, recadrage centré sans déformation, cadre PNG, QR code d'impression."""

from pathlib import Path

from PIL import Image, ImageDraw

from services import compositor
from services.frames import Frame, FrameLibrary, Slot
from services.printer import compute_print_box
from services.qr_service import QrService
from tests.conftest import decode_qr, make_frame, make_photo

PLAIN = Frame(id="plain", name="Sans cadre", width=1200, height=1800, slots=(Slot(0, 0, 1200, 1800),))


def test_final_photo_is_1200x1800_jpeg_with_frame(tmp_path: Path):
    photo = make_photo(tmp_path / "photo.jpg", size=(1920, 1080))
    make_frame(tmp_path / "frames" / "test")
    frame = FrameLibrary(tmp_path / "frames", (1200, 1800)).scan()[0]

    output = compositor.compose_to_file([photo], frame, tmp_path / "final.jpg", quality=95)

    with Image.open(output) as image:
        assert image.format == "JPEG"
        assert image.size == (1200, 1800)
        assert tuple(round(value) for value in image.info["dpi"]) == (300, 300)
        red, green, blue = image.getpixel((10, 10))  # bordure rouge du cadre
        assert red > 200 and green < 60 and blue < 60
        red, green, blue = image.getpixel((600, 900))  # centre : carré jaune de la photo
        assert red > 200 and green > 180 and blue < 90


def test_crop_is_centered_and_never_distorted(tmp_path: Path):
    source = Image.new("RGB", (3000, 1000), (255, 0, 0))
    draw = ImageDraw.Draw(source)
    draw.rectangle((1000, 0, 1999, 999), fill=(0, 200, 0))
    draw.rectangle((2000, 0, 2999, 999), fill=(0, 0, 255))
    draw.rectangle((1400, 400, 1599, 599), fill=(0, 0, 0))  # carré noir de 200 px au centre
    path = tmp_path / "bands.jpg"
    source.save(path, quality=95)

    result = compositor.compose([path], PLAIN)

    for x in (15, 600, 1185):  # le recadrage 2:3 ne garde que la bande centrale (verte)
        red, green, blue = result.getpixel((x, 100))
        assert green > 150 and red < 80 and blue < 80
    mask = result.convert("L").point(lambda value: 255 if value < 40 else 0)
    left, top, right, bottom = mask.getbbox()
    assert abs((right - left) - (bottom - top)) <= 4  # le carré reste un carré
    assert abs((right - left) - 360) <= 6  # 200 px x (1800 / 1000)


def test_exif_orientation_is_applied(tmp_path: Path):
    image = Image.new("RGB", (1800, 1200), (0, 0, 255))
    exif = image.getexif()
    exif[0x0112] = 6  # appareil tenu verticalement
    path = tmp_path / "rotated.jpg"
    image.save(path, exif=exif.tobytes())

    assert compositor.open_photo(path).size == (1200, 1800)


def test_large_reflex_photo_is_processed(tmp_path: Path):
    photo = make_photo(tmp_path / "reflex.jpg", size=(6000, 4000))
    result = compositor.compose([photo], PLAIN)
    assert result.size == (1200, 1800)


def test_photo_strip_places_each_shot_in_its_slots(tmp_path: Path):
    slots = (
        Slot(0, 0, 600, 600, shot=0),
        Slot(600, 0, 600, 600, shot=1),
        Slot(0, 600, 600, 600, shot=0),
    )
    frame = Frame(id="strip", name="Bande", width=1200, height=1200, slots=slots)
    first = make_photo(tmp_path / "1.jpg", color=(255, 0, 0))
    second = make_photo(tmp_path / "2.jpg", color=(0, 0, 255))

    result = compositor.compose([first, second], frame)

    assert frame.shots == 2
    assert result.getpixel((20, 20))[0] > 200  # photo 1 (rouge)
    assert result.getpixel((620, 20))[2] > 200  # photo 2 (bleue)
    assert result.getpixel((20, 620))[0] > 200  # photo 1 répétée


def test_qr_badge_is_readable_on_print():
    base = Image.new("RGB", (1200, 1800), (40, 40, 40))
    qr_image = QrService("https://photos.example.com").image_for("A7K4Q92XB3LM", size=240)

    printed = compositor.add_qr_badge(base, qr_image, "A7K4-Q92X-B3LM", size=240, position="bottom-right")

    assert printed.size == (1200, 1800)
    assert printed.getpixel((5, 5)) == (40, 40, 40)
    assert decode_qr(printed.crop((800, 1350, 1200, 1800))) == "https://photos.example.com/p/A7K4Q92XB3LM"


def test_print_box_fill_and_fit():
    page, printable, offset = (1181, 1748), (1181, 1748), (0, 0)
    left, top, right, bottom = compute_print_box((1200, 1800), page, printable, offset, "fill")
    assert left <= 0 and top <= 0 and right >= page[0] and bottom >= page[1]
    left, top, right, bottom = compute_print_box((1200, 1800), page, printable, offset, "fit")
    assert left >= 0 and top >= 0 and right <= printable[0] and bottom <= printable[1]
    assert abs((right - left) / (bottom - top) - 2 / 3) < 0.01
