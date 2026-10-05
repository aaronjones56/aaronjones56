"""Événements : création, événement actif et statistiques."""

from __future__ import annotations

import logging
import threading
from dataclasses import asdict, dataclass
from datetime import date
from typing import TYPE_CHECKING, Any

from services.database import Database
from services.errors import NotFoundError, ValidationError
from services.photo_repository import PhotoRepository
from services.settings_service import SettingsService
from services.storage import Storage
from services.utils import folder_size, human_size, is_valid_slug, now_iso, slugify

if TYPE_CHECKING:
    from config import Config

logger = logging.getLogger(__name__)

ACTIVE_EVENT_KEY = "active_event_id"


@dataclass(frozen=True)
class Event:
    id: int
    name: str
    slug: str
    event_date: str
    folder: str
    created_at: str

    @classmethod
    def from_row(cls, row: dict[str, Any]) -> Event:
        return cls(**row)

    @property
    def display_date(self) -> str:
        """Date au format français : 05/07/2027."""
        try:
            return date.fromisoformat(self.event_date).strftime("%d/%m/%Y")
        except ValueError:
            return self.event_date

    def to_dict(self) -> dict[str, Any]:
        return {**asdict(self), "display_date": self.display_date}


class EventService:
    """Gestion des événements et de l'événement actif (celui des nouvelles photos)."""

    def __init__(
        self, db: Database, storage: Storage, settings: SettingsService, repo: PhotoRepository, config: Config
    ) -> None:
        self.db = db
        self.storage = storage
        self.settings = settings
        self.repo = repo
        self.config = config
        self._lock = threading.Lock()

    def list_events(self) -> list[Event]:
        rows = self.db.fetch_all("SELECT * FROM events ORDER BY event_date DESC, id DESC")
        return [Event.from_row(row) for row in rows]

    def get(self, event_id: int) -> Event | None:
        row = self.db.fetch_one("SELECT * FROM events WHERE id = ?", (event_id,))
        return Event.from_row(row) if row else None

    def get_by_slug(self, slug: str) -> Event | None:
        row = self.db.fetch_one("SELECT * FROM events WHERE slug = ?", (slug,))
        return Event.from_row(row) if row else None

    def create(self, name: str, event_date: str | None = None, slug: str | None = None) -> Event:
        """Crée un événement et son dossier ``data/events/<date>-<slug>``."""
        name = (name or "").strip()
        if not name:
            raise ValidationError("Le nom de l'événement est obligatoire.")
        if len(name) > 120:
            raise ValidationError("Le nom de l'événement est trop long (120 caractères maximum).")
        event_date = (event_date or date.today().isoformat()).strip()
        try:
            date.fromisoformat(event_date)
        except ValueError as exc:
            raise ValidationError("Date invalide (format attendu : AAAA-MM-JJ).") from exc
        slug = slugify(slug or name)
        if not is_valid_slug(slug):
            raise ValidationError("Identifiant invalide : utilisez des lettres, des chiffres et des tirets.")
        if self.get_by_slug(slug) is not None:
            raise ValidationError(f"Un événement avec l'identifiant « {slug} » existe déjà.")

        folder = f"{event_date}-{slug}"
        result = self.db.execute(
            "INSERT INTO events (name, slug, event_date, folder, created_at) VALUES (?, ?, ?, ?, ?)",
            (name, slug, event_date, folder, now_iso()),
        )
        self.storage.event_folder(folder).ensure()
        logger.info("Événement créé : %s (%s, dossier %s)", name, slug, folder)
        event = self.get(int(result.lastrowid or 0))
        if event is None:
            raise NotFoundError("Événement introuvable après création.")
        return event

    def active_event(self) -> Event:
        """Événement actif ; au premier démarrage, il est créé à partir du fichier .env."""
        event_id = self.settings.get_int(ACTIVE_EVENT_KEY)
        event = self.get(event_id) if event_id else None
        return event if event is not None else self._bootstrap_default()

    def set_active(self, event_id: int) -> Event:
        event = self.get(event_id)
        if event is None:
            raise NotFoundError("Événement introuvable.")
        self.settings.set(ACTIVE_EVENT_KEY, str(event.id))
        self.storage.event_folder(event.folder).ensure()
        logger.info("Événement actif : %s (%s)", event.name, event.slug)
        return event

    def stats(self, event: Event) -> dict[str, Any]:
        stats: dict[str, Any] = dict(self.repo.stats_for_event(event.id))
        size = folder_size(self.storage.event_folder(event.folder).root)
        stats["disk_bytes"] = size
        stats["disk_human"] = human_size(size)
        return stats

    def _bootstrap_default(self) -> Event:
        with self._lock:
            event = self.get_by_slug(self.config.event_slug)
            if event is None:
                event = self.create(self.config.event_name, self.config.event_date, self.config.event_slug)
            self.settings.set(ACTIVE_EVENT_KEY, str(event.id))
            self.storage.event_folder(event.folder).ensure()
            return event
