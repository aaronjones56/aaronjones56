"""Accès aux tables ``photos`` et ``sessions``."""

from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Any

from services.database import Database
from services.errors import NotFoundError
from services.utils import now_iso


@dataclass(frozen=True)
class PhotoRecord:
    """Une session photo terminée : fichiers, impression et état de l'upload."""

    id: int
    code: str
    event_id: int
    frame_name: str
    shot_count: int
    original_path: str
    final_path: str
    qr_path: str
    created_at: str
    printed: bool
    printed_at: str | None
    print_count: int
    uploaded: bool
    uploaded_at: str | None
    upload_attempts: int
    last_upload_error: str | None

    @classmethod
    def from_row(cls, row: dict[str, Any]) -> PhotoRecord:
        values = dict(row)
        values["printed"] = bool(values["printed"])
        values["uploaded"] = bool(values["uploaded"])
        return cls(**values)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


class PhotoRepository:
    """Requêtes SQL (toujours paramétrées) sur les photos et les sessions."""

    def __init__(self, db: Database) -> None:
        self.db = db

    # --- Photos -----------------------------------------------------------

    def code_exists(self, code: str) -> bool:
        return self.db.fetch_one("SELECT 1 FROM photos WHERE code = ?", (code,)) is not None

    def insert(
        self,
        *,
        code: str,
        event_id: int,
        frame_name: str,
        shot_count: int,
        original_path: str,
        final_path: str,
        qr_path: str,
    ) -> PhotoRecord:
        self.db.execute(
            "INSERT INTO photos (code, event_id, frame_name, shot_count, original_path, final_path, qr_path, "
            "created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (code, event_id, frame_name, shot_count, original_path, final_path, qr_path, now_iso()),
        )
        return self.require(code)

    def get(self, code: str) -> PhotoRecord | None:
        row = self.db.fetch_one("SELECT * FROM photos WHERE code = ?", (code,))
        return PhotoRecord.from_row(row) if row else None

    def require(self, code: str) -> PhotoRecord:
        record = self.get(code)
        if record is None:
            raise NotFoundError("Photo introuvable.")
        return record

    def list_for_event(self, event_id: int, limit: int = 48, offset: int = 0) -> list[PhotoRecord]:
        rows = self.db.fetch_all(
            "SELECT * FROM photos WHERE event_id = ? ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?",
            (event_id, limit, offset),
        )
        return [PhotoRecord.from_row(row) for row in rows]

    def count_for_event(self, event_id: int) -> int:
        row = self.db.fetch_one("SELECT COUNT(*) AS total FROM photos WHERE event_id = ?", (event_id,))
        return int(row["total"]) if row else 0

    def pending_uploads(self, event_id: int | None = None) -> list[PhotoRecord]:
        if event_id is None:
            rows = self.db.fetch_all("SELECT * FROM photos WHERE uploaded = 0 ORDER BY created_at, id")
        else:
            rows = self.db.fetch_all(
                "SELECT * FROM photos WHERE uploaded = 0 AND event_id = ? ORDER BY created_at, id", (event_id,)
            )
        return [PhotoRecord.from_row(row) for row in rows]

    def count_pending(self, event_id: int | None = None) -> int:
        if event_id is None:
            row = self.db.fetch_one("SELECT COUNT(*) AS total FROM photos WHERE uploaded = 0")
        else:
            row = self.db.fetch_one(
                "SELECT COUNT(*) AS total FROM photos WHERE uploaded = 0 AND event_id = ?", (event_id,)
            )
        return int(row["total"]) if row else 0

    def mark_printed(self, code: str, copies: int) -> PhotoRecord:
        self.db.execute(
            "UPDATE photos SET printed = 1, printed_at = ?, print_count = print_count + ? WHERE code = ?",
            (now_iso(), copies, code),
        )
        return self.require(code)

    def mark_uploaded(self, code: str) -> None:
        self.db.execute(
            "UPDATE photos SET uploaded = 1, uploaded_at = ?, upload_attempts = upload_attempts + 1, "
            "last_upload_error = NULL WHERE code = ?",
            (now_iso(), code),
        )

    def mark_upload_failed(self, code: str, error: str) -> None:
        self.db.execute(
            "UPDATE photos SET upload_attempts = upload_attempts + 1, last_upload_error = ? WHERE code = ?",
            (error[:500], code),
        )

    def delete(self, code: str) -> None:
        self.db.execute("DELETE FROM photos WHERE code = ?", (code,))

    # --- Sessions ---------------------------------------------------------

    def start_session(self, session_id: str, event_id: int, frame_name: str) -> None:
        self.db.execute(
            "INSERT INTO sessions (id, event_id, frame_name, started_at) VALUES (?, ?, ?, ?)",
            (session_id, event_id, frame_name, now_iso()),
        )

    def complete_session(self, session_id: str, code: str) -> None:
        self.db.execute(
            "UPDATE sessions SET completed_at = ?, photo_code = ? WHERE id = ?", (now_iso(), code, session_id)
        )

    # --- Statistiques -----------------------------------------------------

    def stats_for_event(self, event_id: int) -> dict[str, int]:
        photos = (
            self.db.fetch_one(
                "SELECT COUNT(*) AS photos, COALESCE(SUM(shot_count), 0) AS shots, "
                "COALESCE(SUM(printed), 0) AS printed, COALESCE(SUM(print_count), 0) AS prints, "
                "COALESCE(SUM(uploaded), 0) AS uploaded FROM photos WHERE event_id = ?",
                (event_id,),
            )
            or {}
        )
        sessions = (
            self.db.fetch_one(
                "SELECT COUNT(*) AS started, COALESCE(SUM(completed_at IS NOT NULL), 0) AS completed "
                "FROM sessions WHERE event_id = ?",
                (event_id,),
            )
            or {}
        )
        total = int(photos.get("photos", 0))
        uploaded = int(photos.get("uploaded", 0))
        return {
            "sessions": int(sessions.get("started", 0)),
            "sessions_completed": int(sessions.get("completed", 0)),
            "photos": total,
            "shots": int(photos.get("shots", 0)),
            "printed": int(photos.get("printed", 0)),
            "prints": int(photos.get("prints", 0)),
            "uploaded": uploaded,
            "pending": total - uploaded,
        }
