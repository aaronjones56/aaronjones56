"""SQLite : création automatique, requêtes paramétrées, événements, réglages, persistance."""

import sqlite3

import pytest

from app import create_app
from services.errors import ValidationError
from tests.conftest import take_photo


def test_tables_are_created_automatically(services):
    rows = services.db.fetch_all("SELECT name FROM sqlite_master WHERE type = 'table'")
    assert {"events", "photos", "sessions", "settings"} <= {row["name"] for row in rows}


def test_photo_lifecycle(services):
    event = services.events.active_event()
    record = services.repo.insert(
        code="A7K4Q92XB3LM",
        event_id=event.id,
        frame_name="rouge",
        shot_count=1,
        original_path="o.jpg",
        final_path="f.jpg",
        qr_path="q.png",
    )
    assert record.printed is False and record.uploaded is False and record.print_count == 0

    printed = services.repo.mark_printed("A7K4Q92XB3LM", 2)
    assert printed.printed is True and printed.print_count == 2 and printed.printed_at

    assert [item.code for item in services.repo.pending_uploads(event.id)] == ["A7K4Q92XB3LM"]
    services.repo.mark_upload_failed("A7K4Q92XB3LM", "Erreur réseau")
    assert services.repo.get("A7K4Q92XB3LM").last_upload_error == "Erreur réseau"
    services.repo.mark_uploaded("A7K4Q92XB3LM")
    uploaded = services.repo.get("A7K4Q92XB3LM")
    assert uploaded.uploaded is True and uploaded.uploaded_at and uploaded.last_upload_error is None
    assert services.repo.pending_uploads() == []

    stats = services.repo.stats_for_event(event.id)
    assert stats["photos"] == 1 and stats["prints"] == 2 and stats["uploaded"] == 1 and stats["pending"] == 0


def test_codes_are_unique_in_database(services):
    event = services.events.active_event()
    values = dict(
        code="A7K4Q92XB3LM",
        event_id=event.id,
        frame_name="rouge",
        shot_count=1,
        original_path="o",
        final_path="f",
        qr_path="q",
    )
    services.repo.insert(**values)
    with pytest.raises(sqlite3.IntegrityError):
        services.repo.insert(**values)


def test_queries_are_parameterized(services):
    assert services.repo.get("x' OR '1'='1") is None
    assert services.events.get_by_slug("x' OR 1=1 --") is None


def test_events(services):
    default = services.events.active_event()
    assert default.slug == "evenement-test"
    assert default.folder == "2027-07-05-evenement-test"
    assert default.display_date == "05/07/2027"

    event = services.events.create("Festi'Coat 2027", "2027-07-05")
    assert event.slug == "festicoat-2027"
    assert (services.storage.events_dir / "2027-07-05-festicoat-2027" / "originals").is_dir()
    services.events.set_active(event.id)
    assert services.events.active_event().id == event.id

    with pytest.raises(ValidationError):
        services.events.create("Festi'Coat 2027", "2027-07-05")
    with pytest.raises(ValidationError):
        services.events.create("Mauvaise date", "05/07/2027")
    with pytest.raises(ValidationError):
        services.events.create("   ")


def test_runtime_settings(services):
    services.settings.update_runtime({"auto_print": True, "session_timeout": 90})
    assert services.settings.runtime("auto_print") is True
    assert services.settings.runtime("session_timeout") == 90
    with pytest.raises(ValidationError):
        services.settings.update_runtime({"session_timeout": 5})
    with pytest.raises(ValidationError):
        services.settings.update_runtime({"inconnu": 1})
    services.settings.reset_runtime()
    assert services.settings.runtime("session_timeout") == 45
    assert services.settings.runtime("auto_print") is False


def test_data_survives_restart(config):
    first = create_app(config)
    photo = take_photo(first.test_client())
    first.extensions["photobooth"].close()

    second = create_app(config)
    client = second.test_client()
    assert client.get(f"/api/photo/{photo['code']}").get_json()["photo"]["code"] == photo["code"]
    assert client.get(f"/photo/{photo['code']}").status_code == 200
    second.extensions["photobooth"].close()
