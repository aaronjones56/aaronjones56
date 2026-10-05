"""Accès SQLite : création du schéma, connexions courtes et requêtes paramétrées."""

from __future__ import annotations

import sqlite3
from collections.abc import Iterator, Sequence
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from services.devices import DeviceStatus

SCHEMA_VERSION = 1

_SCHEMA = """
CREATE TABLE IF NOT EXISTS events (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT    NOT NULL,
    slug        TEXT    NOT NULL UNIQUE,
    event_date  TEXT    NOT NULL,
    folder      TEXT    NOT NULL UNIQUE,
    created_at  TEXT    NOT NULL
);

CREATE TABLE IF NOT EXISTS photos (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    code               TEXT    NOT NULL UNIQUE,
    event_id           INTEGER NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    frame_name         TEXT    NOT NULL,
    shot_count         INTEGER NOT NULL DEFAULT 1,
    original_path      TEXT    NOT NULL,
    final_path         TEXT    NOT NULL,
    qr_path            TEXT    NOT NULL,
    created_at         TEXT    NOT NULL,
    printed            INTEGER NOT NULL DEFAULT 0,
    printed_at         TEXT,
    print_count        INTEGER NOT NULL DEFAULT 0,
    uploaded           INTEGER NOT NULL DEFAULT 0,
    uploaded_at        TEXT,
    upload_attempts    INTEGER NOT NULL DEFAULT 0,
    last_upload_error  TEXT
);
CREATE INDEX IF NOT EXISTS idx_photos_event ON photos(event_id, created_at);
CREATE INDEX IF NOT EXISTS idx_photos_pending ON photos(uploaded, event_id);

CREATE TABLE IF NOT EXISTS sessions (
    id            TEXT    PRIMARY KEY,
    event_id      INTEGER NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    frame_name    TEXT    NOT NULL,
    started_at    TEXT    NOT NULL,
    completed_at  TEXT,
    photo_code    TEXT
);
CREATE INDEX IF NOT EXISTS idx_sessions_event ON sessions(event_id);

CREATE TABLE IF NOT EXISTS settings (
    key         TEXT PRIMARY KEY,
    value       TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);
"""


@dataclass(frozen=True)
class ExecResult:
    """Résultat d'une écriture : identifiant inséré et nombre de lignes touchées."""

    lastrowid: int | None
    rowcount: int


class Database:
    """Base SQLite du photobooth. Une connexion par opération : sûr avec plusieurs threads."""

    def __init__(self, path: Path) -> None:
        self.path = path

    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        """Connexion transactionnelle : validée si tout se passe bien, annulée sinon."""
        connection = sqlite3.connect(str(self.path), timeout=10)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA synchronous = FULL")
        try:
            with connection:
                yield connection
        finally:
            connection.close()

    def initialize(self) -> None:
        """Crée la base et les tables au premier démarrage, puis applique les migrations."""
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as connection:
            connection.execute("PRAGMA journal_mode = WAL")
            connection.executescript(_SCHEMA)
            version = connection.execute("PRAGMA user_version").fetchone()[0]
            if version < SCHEMA_VERSION:
                connection.execute(f"PRAGMA user_version = {SCHEMA_VERSION:d}")

    def execute(self, sql: str, params: Sequence[Any] = ()) -> ExecResult:
        with self.connect() as connection:
            cursor = connection.execute(sql, params)
            return ExecResult(cursor.lastrowid, cursor.rowcount)

    def fetch_one(self, sql: str, params: Sequence[Any] = ()) -> dict[str, Any] | None:
        with self.connect() as connection:
            row = connection.execute(sql, params).fetchone()
            return dict(row) if row is not None else None

    def fetch_all(self, sql: str, params: Sequence[Any] = ()) -> list[dict[str, Any]]:
        with self.connect() as connection:
            return [dict(row) for row in connection.execute(sql, params).fetchall()]

    def check(self) -> DeviceStatus:
        try:
            with self.connect() as connection:
                connection.execute("SELECT COUNT(*) FROM photos").fetchone()
        except sqlite3.Error as exc:
            return DeviceStatus(False, f"Base de données inaccessible : {exc}")
        return DeviceStatus(True, "Base de données opérationnelle")
