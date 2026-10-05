"""QR codes : lien public de la photo, générés sans Internet."""

from pathlib import Path

from PIL import Image

from services.qr_service import QrService
from tests.conftest import decode_qr


def test_photo_url_uses_public_address():
    service = QrService("https://photos.mondomaine.fr/")
    assert service.photo_url("A7K4Q92XB3LM") == "https://photos.mondomaine.fr/p/A7K4Q92XB3LM"


def test_qr_png_encodes_the_photo_url(tmp_path: Path):
    service = QrService("https://photos.mondomaine.fr")
    path = service.save("A7K4Q92XB3LM", tmp_path / "qr" / "A7K4Q92XB3LM.png")

    assert path.is_file()
    with Image.open(path) as image:
        assert image.format == "PNG"
        assert decode_qr(image) == "https://photos.mondomaine.fr/p/A7K4Q92XB3LM"


def test_qr_can_be_generated_at_exact_size():
    image = QrService("https://photos.mondomaine.fr").image_for("A7K4Q92XB3LM", size=240)
    assert image.size == (240, 240)
    assert decode_qr(image) == "https://photos.mondomaine.fr/p/A7K4Q92XB3LM"
