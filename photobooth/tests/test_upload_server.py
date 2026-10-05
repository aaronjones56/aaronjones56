"""Serveur web des photos : API d'upload sécurisée, pages publiques, galerie, rétention."""

import io
import os
import re
from datetime import datetime, timedelta, timezone

from PIL import Image

from tests.conftest import SERVER_TOKEN

CODE = "A7K4Q92XB3LM"


def image_bytes(image_format: str = "JPEG", size=(600, 900), color=(200, 40, 90)) -> bytes:
    buffer = io.BytesIO()
    Image.new("RGB", size, color).save(buffer, format=image_format)
    return buffer.getvalue()


def upload(client, code=CODE, token=SERVER_TOKEN, event="festicoat-2027", filename="photo.jpg", content=None):
    data = {
        "photo_code": code,
        "event": event,
        "event_name": "Festi'Coat 2027",
        "event_date": "2027-07-05",
        "date": "2027-07-05T21:30:12+02:00",
        "photo": (io.BytesIO(content if content is not None else image_bytes()), filename),
    }
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    return client.post("/api/upload", data=data, headers=headers, content_type="multipart/form-data")


def test_upload_then_view_and_download(upload_server):
    _module, app, config = upload_server
    client = app.test_client()

    response = upload(client)
    assert response.status_code == 201
    assert response.get_json()["url"] == f"https://photos.example.com/p/{CODE}"
    assert (config.upload_dir / "festicoat-2027" / f"{CODE}.jpg").is_file()

    page = client.get(f"/p/{CODE}")
    html = page.get_data(as_text=True)
    assert page.status_code == 200
    assert "Votre photo" in html and "TÉLÉCHARGER" in html and "A7K4-Q92X-B3LM" in html
    media = client.get(f"/media/{CODE}")
    assert media.status_code == 200 and media.mimetype == "image/jpeg"
    assert media.headers["X-Content-Type-Options"] == "nosniff"
    download = client.get(f"/download/{CODE}")
    assert download.headers["Content-Disposition"].startswith("attachment")


def test_photo_not_yet_available(upload_server):
    _module, app, _config = upload_server
    page = app.test_client().get("/p/AAAA-BBBB-CCCC", follow_redirects=True)
    html = page.get_data(as_text=True)
    assert page.status_code == 404
    assert "Votre photo n'est pas encore disponible." in html.replace("&#39;", "'")
    assert "Les photos seront publiées après l'événement." in html.replace("&#39;", "'")


def test_human_typed_code_redirects_to_canonical_url(upload_server):
    _module, app, _config = upload_server
    response = app.test_client().get("/p/a7k4-q92x-b3lm")
    assert response.status_code == 301 and response.headers["Location"].endswith(f"/p/{CODE}")


def test_bad_or_missing_token_is_refused(upload_server):
    _module, app, config = upload_server
    client = app.test_client()
    assert upload(client, token="mauvais-token-000000000").status_code == 401
    assert upload(client, token=None).status_code == 401
    assert not any(config.upload_dir.rglob("*.jpg"))


def test_only_jpeg_and_png_are_accepted(upload_server):
    _module, app, _config = upload_server
    client = app.test_client()
    assert upload(client, filename="photo.gif", content=image_bytes("GIF")).status_code == 415
    assert upload(client, filename="shell.php").status_code == 415
    assert upload(client, filename="photo.jpg", content=b"<?php system($_GET['c']); ?>").status_code == 415
    truncated = image_bytes(size=(1200, 1800))
    assert upload(client, filename="photo.jpg", content=truncated[: len(truncated) // 2]).status_code == 415
    assert upload(client, filename="photo.png", content=image_bytes("PNG")).status_code == 201


def test_stored_extension_comes_from_content_not_name(upload_server):
    _module, app, config = upload_server
    assert upload(app.test_client(), filename="photo.jpg", content=image_bytes("PNG")).status_code == 201
    assert (config.upload_dir / "festicoat-2027" / f"{CODE}.png").is_file()
    assert app.test_client().get(f"/media/{CODE}").mimetype == "image/png"


def test_upload_size_is_limited(upload_server):
    _module, app, _config = upload_server
    response = upload(app.test_client(), content=os.urandom(3 * 1024 * 1024))
    assert response.status_code == 413
    assert "trop volumineux" in response.get_json()["error"]


def test_path_traversal_is_impossible(upload_server):
    _module, app, config = upload_server
    client = app.test_client()
    assert upload(client, code="../../etc/passwd").status_code == 400
    assert upload(client, event="../secret").status_code == 400
    assert upload(client, filename="../../../evil.jpg").status_code == 201
    stored = sorted(
        path.relative_to(config.upload_dir).as_posix() for path in config.upload_dir.rglob("*") if path.is_file()
    )
    assert stored == [f"_thumbs/{CODE}.jpg", f"festicoat-2027/{CODE}.jpg"]
    assert client.get("/media/..%2F..%2Fphotos.db").status_code == 404


def test_reupload_replaces_the_photo(upload_server):
    _module, app, config = upload_server
    client = app.test_client()
    assert upload(client, content=image_bytes(color=(255, 0, 0))).status_code == 201
    assert upload(client, content=image_bytes(color=(0, 0, 255))).status_code == 201
    assert len(list((config.upload_dir / "festicoat-2027").iterdir())) == 1


def test_no_public_listing_of_photos(upload_server):
    _module, app, _config = upload_server
    client = app.test_client()
    upload(client)
    home = client.get("/").get_data(as_text=True)
    assert CODE not in home
    assert client.get("/uploads/festicoat-2027/").status_code == 404
    assert client.get("/g/festicoat-2027/devine").status_code == 404
    assert client.get("/robots.txt").get_data(as_text=True).endswith("Disallow: /\n")
    assert "noindex" in client.get(f"/p/{CODE}").headers["X-Robots-Tag"]


def test_optional_event_gallery(upload_server):
    _module, app, _config = upload_server
    client = app.test_client()
    upload(client)
    runner = app.test_cli_runner()

    enabled = runner.invoke(args=["gallery-enable", "festicoat-2027"])
    url = re.search(r"https://photos\.example\.com(/g/\S+)", enabled.output).group(1)
    page = client.get(url)
    assert page.status_code == 200 and f"/p/{CODE}" in page.get_data(as_text=True)
    assert client.get(f"{url}/thumb/{CODE}").mimetype == "image/jpeg"

    runner.invoke(args=["gallery-disable", "festicoat-2027"])
    assert client.get(url).status_code == 404


def test_retention_deletes_old_photos(upload_server):
    module, app, config = upload_server
    client = app.test_client()
    upload(client)
    store = app.extensions["photo_store"]

    assert module.cleanup_expired(store, config, 30) == []
    later = datetime.now(timezone.utc) + timedelta(days=31)
    assert module.cleanup_expired(store, config, 30, now=later) == [CODE]
    assert not (config.upload_dir / "festicoat-2027" / f"{CODE}.jpg").exists()
    page = client.get(f"/p/{CODE}")
    assert page.status_code == 410 and "plus disponible" in page.get_data(as_text=True)


def test_cleanup_and_delete_commands(upload_server):
    _module, app, config = upload_server
    upload(app.test_client())
    runner = app.test_cli_runner()
    assert "0 photo(s)" in runner.invoke(args=["cleanup", "--dry-run"]).output
    assert "supprimée" in runner.invoke(args=["delete-photo", "a7k4-q92x-b3lm"]).output
    assert not (config.upload_dir / "festicoat-2027" / f"{CODE}.jpg").exists()


def test_guessing_codes_is_rate_limited(upload_server):
    _module, app, _config = upload_server
    client = app.test_client()
    upload(client)
    for index in range(5):
        client.get(f"/p/AAAABBBBCC{'23456'[index]}{'2'}")
    assert client.get(f"/p/{CODE}").status_code == 429


def test_security_headers(upload_server):
    _module, app, _config = upload_server
    response = app.test_client().get("/")
    assert "default-src 'none'" in response.headers["Content-Security-Policy"]
    assert response.headers["X-Frame-Options"] == "DENY"
    assert response.headers["Referrer-Policy"] == "no-referrer"
