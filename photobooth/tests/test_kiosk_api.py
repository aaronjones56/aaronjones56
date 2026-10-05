"""API de la borne et de l'administration (caméra simulée, imprimante simulée)."""

from pathlib import Path

from PIL import Image

from services.errors import CameraError, PrinterError
from tests.conftest import ADMIN_PIN, make_frame, take_photo


def test_kiosk_page_and_status(client):
    assert client.get("/").status_code == 200
    status = client.get("/api/status").get_json()
    assert status["ok"] is True
    assert {name: check["ok"] for name, check in status["checks"].items()} == {
        "camera": True,
        "printer": True,
        "database": True,
        "storage": True,
    }
    assert status["ui"]["session_timeout"] == 45
    assert status["event"]["slug"] == "evenement-test"


def test_frames_api_and_files(client):
    frames = client.get("/api/frames").get_json()["frames"]
    assert [frame["id"] for frame in frames] == ["rouge"]
    preview = client.get(frames[0]["preview_url"])  # vignette générée automatiquement
    assert preview.status_code == 200 and preview.mimetype == "image/jpeg"
    overlay = client.get(frames[0]["overlay_url"])
    assert overlay.status_code == 200 and overlay.mimetype == "image/png"
    assert client.get("/frames/inconnu/preview").status_code == 404


def test_camera_preview_returns_jpeg(client):
    response = client.get("/api/camera/preview")
    assert response.status_code == 200 and response.mimetype == "image/jpeg"


def test_complete_session_saves_everything(client, services):
    photo = take_photo(client)
    code = photo["code"]
    record = services.repo.get(code)
    files = services.photos.files_for(record)

    assert photo["display_code"].replace("-", "") == code
    assert photo["public_url"] == f"https://photos.example.com/p/{code}"
    assert record.event_id == services.events.active_event().id and record.frame_name == "rouge"
    assert record.printed is False and record.uploaded is False
    folder = services.storage.events_dir / "2027-07-05-evenement-test"
    assert files["original"] == (folder / "originals" / f"{code}.jpg").resolve()
    assert all(files[key].is_file() for key in ("original", "final", "qr", "thumb"))
    with Image.open(files["final"]) as final:
        assert final.size == (1200, 1800)

    assert client.get(f"/photo/{code}").mimetype == "image/jpeg"
    assert client.get(f"/photo/{code}/qr").mimetype == "image/png"
    assert client.get(f"/photo/{code}/thumb").status_code == 200


def test_photo_strip_session(client, services, config):
    slots = [{"x": 0, "y": index * 600, "width": 1200, "height": 600} for index in range(3)]
    make_frame(Path(config.frames_dir) / "bande", config={"name": "Bande", "photo_slots": slots})
    session = client.post("/api/session/start", json={"frame_id": "bande"}).get_json()["session"]
    assert session["shots_total"] == 3

    first = client.post("/api/capture", json={"session_id": session["id"]}).get_json()
    assert first["done"] is False and first["shot"] == 1
    assert client.get(first["shot_url"]).mimetype == "image/jpeg"
    client.post("/api/capture", json={"session_id": session["id"]})
    last = client.post("/api/capture", json={"session_id": session["id"]}).get_json()

    assert last["done"] is True and last["photo"]["shot_count"] == 3
    folder = services.storage.events_dir / "2027-07-05-evenement-test" / "originals"
    assert sorted(path.name for path in folder.iterdir()) == [f"{last['photo']['code']}-{n}.jpg" for n in (1, 2, 3)]
    again = client.post("/api/capture", json={"session_id": session["id"]})
    assert again.status_code == 404


def test_abandoned_session_removes_partial_shots(client, services, config):
    make_frame(
        Path(config.frames_dir) / "duo",
        config={
            "photo_slots": [
                {"x": 0, "y": 0, "width": 1200, "height": 900},
                {"x": 0, "y": 900, "width": 1200, "height": 900},
            ]
        },
    )
    session = client.post("/api/session/start", json={"frame_id": "duo"}).get_json()["session"]
    client.post("/api/capture", json={"session_id": session["id"]})
    originals = services.storage.events_dir / "2027-07-05-evenement-test" / "originals"
    assert len(list(originals.iterdir())) == 1
    assert client.post("/api/session/reset", json={"session_id": session["id"]}).get_json()["abandoned"] is True
    assert list(originals.iterdir()) == []


def test_print_with_simulated_printer(client, services):
    photo = take_photo(client)
    response = client.post(f"/api/print/{photo['code']}", json={"copies": 2})
    assert response.status_code == 200
    assert response.get_json()["photo"]["print_count"] == 2
    assert services.printer.jobs[-1][1] == 2
    assert services.repo.get(photo["code"]).printed is True


def test_print_limit_per_photo(client, services):
    services.settings.update_runtime({"print_limit_per_photo": 1})
    photo = take_photo(client)
    assert client.post(f"/api/print/{photo['code']}", json={"copies": 1}).status_code == 200
    refused = client.post(f"/api/print/{photo['code']}", json={"copies": 1})
    assert refused.status_code == 409
    assert "maximum" in refused.get_json()["error"]


def test_qr_on_print_creates_print_version(client, services):
    services.settings.update_runtime({"qr_on_print": True})
    photo = take_photo(client)
    client.post(f"/api/print/{photo['code']}", json={"copies": 1})
    printed_file = services.printer.jobs[-1][0]
    assert printed_file.parent.name == "prints"
    final_file = services.photos.files_for(services.repo.get(photo["code"]))["final"]
    assert final_file.read_bytes() != printed_file.read_bytes()  # la photo en ligne reste sans QR code


def test_unknown_photo_returns_404(client):
    assert client.get("/photo/AAAABBBBCCCC").status_code == 404
    assert client.get("/photo/../../app.py").status_code == 404
    assert client.post("/api/print/AAAABBBBCCCC", json={}).status_code == 404


def test_writes_require_json(client):
    response = client.post("/api/session/start", data={"frame_id": "rouge"})
    assert response.status_code == 415


def test_camera_error_is_reported_without_crashing(client, services, monkeypatch):
    def broken_capture(_path):
        raise CameraError("L'appareil photo ne répond pas.")

    monkeypatch.setattr(services.camera, "capture", broken_capture)
    session = client.post("/api/session/start", json={"frame_id": "rouge"}).get_json()["session"]
    response = client.post("/api/capture", json={"session_id": session["id"]})
    assert response.status_code == 503
    assert response.get_json()["error"] == "L'appareil photo ne répond pas."
    assert client.get("/api/health").status_code == 200


def test_printer_error_is_reported_without_crashing(client, services, monkeypatch):
    def offline(*_args, **_kwargs):
        raise PrinterError("L'imprimante est hors ligne.")

    photo = take_photo(client)
    monkeypatch.setattr(services.printer, "print_image", offline)
    response = client.post(f"/api/print/{photo['code']}", json={"copies": 1})
    assert response.status_code == 503
    assert "hors ligne" in response.get_json()["error"]
    assert services.repo.get(photo["code"]).print_count == 0


def test_admin_requires_pin(client):
    assert client.get("/api/admin/stats").status_code == 401
    assert client.get("/admin").status_code == 200
    assert client.post("/admin/login", json={"pin": "0000"}).status_code == 400
    assert client.post("/admin/login", json={"pin": ADMIN_PIN}).status_code == 200
    assert client.get("/api/admin/stats").status_code == 200


def test_pin_is_locked_after_repeated_failures(client):
    for _ in range(5):
        client.post("/admin/login", json={"pin": "0000"})
    response = client.post("/admin/login", json={"pin": ADMIN_PIN})
    assert response.status_code == 429


def test_admin_dashboard_and_actions(admin_client):
    take_photo(admin_client)
    stats = admin_client.get("/api/admin/stats").get_json()
    assert stats["stats"]["photos"] == 1 and stats["stats"]["pending"] == 1
    assert stats["devices"]["camera"]["ok"] and stats["devices"]["printer"]["ok"]

    created = admin_client.post(
        "/api/admin/events", json={"name": "Mariage", "event_date": "2027-08-21", "activate": True}
    )
    assert created.status_code == 201
    assert admin_client.get("/api/admin/stats").get_json()["event"]["slug"] == "mariage"

    test_camera = admin_client.post("/api/admin/test-camera", json={}).get_json()
    assert admin_client.get(test_camera["url"]).mimetype == "image/jpeg"
    assert admin_client.post("/api/admin/test-printer", json={}).status_code == 200
    assert admin_client.get("/admin/logs/download").mimetype == "application/zip"
    upload = admin_client.post("/api/admin/upload", json={"scope": "all"})
    assert upload.status_code == 400  # UPLOAD_ENABLED=false
    assert len(admin_client.get("/api/admin/frames").get_json()["frames"]) == 1


def test_admin_photo_management(admin_client, services):
    photo = take_photo(admin_client)
    listing = admin_client.get("/api/admin/photos").get_json()
    assert listing["total"] == 1 and listing["photos"][0]["code"] == photo["code"]
    assert (
        admin_client.get(f"/admin/photos/{photo['code']}/download")
        .headers["Content-Disposition"]
        .startswith("attachment")
    )
    assert admin_client.get(f"/admin/photos/{photo['code']}/original").status_code == 200
    files = services.photos.files_for(services.repo.get(photo["code"]))
    assert admin_client.delete(f"/api/admin/photos/{photo['code']}", json={}).status_code == 200
    assert services.repo.get(photo["code"]) is None
    assert not files["final"].exists() and not files["original"].exists()


def test_admin_printer_and_settings(admin_client, services):
    printers = admin_client.get("/api/admin/printers").get_json()
    assert printers["mode"] == "null" and printers["printers"]
    assert admin_client.post("/api/admin/printer", json={"name": "Inconnue"}).status_code == 400
    saved = admin_client.post("/api/admin/settings", json={"values": {"session_timeout": 60, "auto_print": True}})
    assert saved.status_code == 200
    assert admin_client.get("/api/config").get_json()["ui"]["session_timeout"] == 60
    assert admin_client.post("/api/admin/settings", json={"values": {"countdown_seconds": 99}}).status_code == 400
