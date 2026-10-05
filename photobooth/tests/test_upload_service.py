"""Upload depuis la borne vers le serveur (le réseau est remplacé par le client de test Flask)."""

import io
from dataclasses import replace
from urllib.parse import urlsplit

import pytest
import requests

from app import create_app
from services.upload_service import UploadService, health_url
from tests.conftest import SERVER_TOKEN, take_photo


class FakeResponse:
    def __init__(self, response):
        self.status_code = response.status_code
        self._response = response
        self.text = response.get_data(as_text=True)
        self.reason = response.status

    def json(self):
        payload = self._response.get_json(silent=True)
        if payload is None:
            raise ValueError("pas de JSON")
        return payload


class FlaskSession:
    """Remplace requests.Session : les requêtes sont envoyées au serveur photos de test."""

    def __init__(self, client, fail: bool = False):
        self.client = client
        self.fail = fail
        self.calls = 0

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        return False

    def post(self, url, headers=None, data=None, files=None, timeout=None):
        self.calls += 1
        if self.fail:
            raise requests.ConnectionError("réseau indisponible")
        payload = dict(data or {})
        for name, (filename, handle, mimetype) in (files or {}).items():
            payload[name] = (io.BytesIO(handle.read()), filename, mimetype)
        response = self.client.post(
            urlsplit(url).path, data=payload, headers=headers or {}, content_type="multipart/form-data"
        )
        return FakeResponse(response)


@pytest.fixture
def kiosk(config):
    upload_config = replace(
        config,
        upload_enabled=True,
        upload_api_url="https://photos.example.com/api/upload",
        upload_api_token=SERVER_TOKEN,
    )
    application = create_app(upload_config)
    yield application
    application.extensions["photobooth"].close()


def make_uploader(kiosk, session, monkeypatch, reachable=True) -> UploadService:
    services = kiosk.extensions["photobooth"]
    uploader = services.uploader
    uploader.session_factory = lambda: session
    monkeypatch.setattr(uploader, "server_reachable", lambda: reachable)
    return uploader


def test_health_url():
    assert health_url("https://photos.example.com/api/upload") == "https://photos.example.com/api/health"
    assert health_url("https://photos.example.com/autre") == "https://photos.example.com/api/health"


def test_pending_photos_are_uploaded(kiosk, upload_server, monkeypatch):
    _module, server_app, _config = upload_server
    client = kiosk.test_client()
    codes = [take_photo(client)["code"] for _ in range(3)]
    uploader = make_uploader(kiosk, FlaskSession(server_app.test_client()), monkeypatch)

    progress = uploader.upload_pending()

    assert (progress.total, progress.succeeded, progress.failed, progress.percent) == (3, 3, 0, 100)
    services = kiosk.extensions["photobooth"]
    assert all(services.repo.get(code).uploaded for code in codes)
    assert services.repo.count_pending() == 0
    public = server_app.test_client()
    for code in codes:
        assert public.get(f"/p/{code}").status_code == 200


def test_wrong_token_stops_upload_and_keeps_photos(kiosk, upload_server, monkeypatch):
    _module, server_app, _config = upload_server
    client = kiosk.test_client()
    codes = [take_photo(client)["code"] for _ in range(2)]
    services = kiosk.extensions["photobooth"]
    services.uploader.config = replace(services.uploader.config, upload_api_token="mauvais-token-0000000000")
    session = FlaskSession(server_app.test_client())
    uploader = make_uploader(kiosk, session, monkeypatch)

    progress = uploader.upload_pending()

    assert session.calls == 1
    assert "Token refusé" in progress.message
    assert all(not services.repo.get(code).uploaded for code in codes)
    assert services.repo.get(codes[0]).last_upload_error


def test_network_errors_keep_photos_pending(kiosk, monkeypatch):
    client = kiosk.test_client()
    codes = [take_photo(client)["code"] for _ in range(4)]
    session = FlaskSession(None, fail=True)
    uploader = make_uploader(kiosk, session, monkeypatch)

    progress = uploader.upload_pending()

    services = kiosk.extensions["photobooth"]
    assert session.calls == 3  # abandon après 3 erreurs réseau consécutives
    assert progress.failed == 3 and "Connexion perdue" in progress.message
    assert services.repo.count_pending() == 4
    assert all(services.repo.get(code).upload_attempts <= 1 for code in codes)


def test_unreachable_server_changes_nothing(kiosk, monkeypatch):
    client = kiosk.test_client()
    take_photo(client)
    session = FlaskSession(None)
    uploader = make_uploader(kiosk, session, monkeypatch, reachable=False)

    progress = uploader.upload_pending()

    assert session.calls == 0
    assert "injoignable" in progress.message
    assert kiosk.extensions["photobooth"].repo.count_pending() == 1


def test_upload_disabled_by_default(services):
    assert "UPLOAD_ENABLED" in services.uploader.configuration_problem()
