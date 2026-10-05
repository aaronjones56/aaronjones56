"""Envoi des photos vers le serveur web, après l'événement.

Seules les photos ``uploaded = 0`` sont envoyées. Une erreur sur une photo n'arrête
pas les autres : elle reste en attente et pourra être renvoyée plus tard. Le token
(UPLOAD_API_TOKEN) est transmis dans l'en-tête ``Authorization: Bearer``.
"""

from __future__ import annotations

import logging
import threading
from collections.abc import Callable
from dataclasses import asdict, dataclass, field
from typing import TYPE_CHECKING, Any
from urllib.parse import urlsplit, urlunsplit

import requests

from config import APP_VERSION
from services.errors import ConflictError, UploadError, ValidationError
from services.event_service import Event, EventService
from services.photo_repository import PhotoRecord, PhotoRepository
from services.storage import Storage
from services.utils import now_iso

if TYPE_CHECKING:
    from config import Config

logger = logging.getLogger(__name__)

MAX_CONSECUTIVE_NETWORK_ERRORS = 3
MAX_REPORTED_ERRORS = 50


class AuthenticationError(UploadError):
    """Le serveur refuse le token : inutile d'essayer les photos suivantes."""


class NetworkError(UploadError):
    """Connexion impossible ou coupée."""


@dataclass
class UploadProgress:
    running: bool = False
    total: int = 0
    done: int = 0
    succeeded: int = 0
    failed: int = 0
    current: str | None = None
    started_at: str | None = None
    finished_at: str | None = None
    message: str = ""
    errors: list[dict[str, str]] = field(default_factory=list)

    @property
    def percent(self) -> int:
        if not self.total:
            return 100 if self.finished_at else 0
        return round(self.done * 100 / self.total)

    def to_dict(self) -> dict[str, Any]:
        return {**asdict(self), "percent": self.percent}


ProgressCallback = Callable[[UploadProgress, PhotoRecord | None, str | None], None]


def health_url(upload_url: str) -> str:
    """https://site/api/upload devient https://site/api/health."""
    parts = urlsplit(upload_url)
    path = parts.path.rstrip("/")
    path = path[: -len("/upload")] + "/health" if path.endswith("/upload") else "/api/health"
    return urlunsplit((parts.scheme, parts.netloc, path, "", ""))


class UploadService:
    def __init__(
        self,
        config: Config,
        repo: PhotoRepository,
        events: EventService,
        storage: Storage,
        session_factory: Callable[[], requests.Session] = requests.Session,
    ) -> None:
        self.config = config
        self.repo = repo
        self.events = events
        self.storage = storage
        self.session_factory = session_factory
        self._progress = UploadProgress()
        self._lock = threading.Lock()

    def configuration_problem(self) -> str | None:
        """Explication lisible si l'upload ne peut pas fonctionner, sinon None."""
        if not self.config.upload_enabled:
            return "L'upload est désactivé (UPLOAD_ENABLED=false dans le fichier .env)."
        if not self.config.upload_api_url.startswith(("https://", "http://")):
            return "UPLOAD_API_URL n'est pas configurée (https://…/api/upload)."
        if not self.config.upload_api_token:
            return "UPLOAD_API_TOKEN n'est pas configuré."
        return None

    def progress(self) -> dict[str, Any]:
        with self._lock:
            return self._progress.to_dict()

    def start_background(self, event_id: int | None = None) -> dict[str, Any]:
        """Lance l'upload dans un thread ; la progression se lit avec ``progress()``."""
        problem = self.configuration_problem()
        if problem:
            raise ValidationError(problem)
        with self._lock:
            if self._progress.running:
                raise ConflictError("Un upload est déjà en cours.")
            self._progress = UploadProgress(running=True, started_at=now_iso(), message="Préparation…")
        threading.Thread(target=self._run_background, args=(event_id,), name="upload", daemon=True).start()
        return self.progress()

    def _run_background(self, event_id: int | None) -> None:
        try:
            self.upload_pending(event_id)
        except Exception:  # noqa: BLE001 - le thread ne doit jamais faire tomber l'application
            logger.exception("Erreur inattendue pendant l'upload")
            self._finish("Erreur inattendue : consultez les journaux.")

    def upload_pending(
        self, event_id: int | None = None, on_progress: ProgressCallback | None = None
    ) -> UploadProgress:
        """Envoie toutes les photos en attente (d'un événement ou de tous)."""
        problem = self.configuration_problem()
        if problem:
            raise ValidationError(problem)
        photos = self.repo.pending_uploads(event_id)
        with self._lock:
            self._progress = UploadProgress(
                running=True,
                total=len(photos),
                started_at=self._progress.started_at or now_iso(),
                message=f"{len(photos)} photo(s) à envoyer",
            )
        logger.info("Upload : %d photo(s) en attente", len(photos))
        if not photos:
            return self._finish("Aucune photo en attente.")
        if not self.server_reachable():
            logger.error("Upload impossible : serveur injoignable (%s)", self.config.upload_api_url)
            return self._finish("Serveur injoignable : vérifiez la connexion Internet.")

        events: dict[int, Event | None] = {}
        network_errors = 0
        with self.session_factory() as http:
            for record in photos:
                self._update(current=record.code)
                if record.event_id not in events:
                    events[record.event_id] = self.events.get(record.event_id)
                try:
                    self._send(http, record, events[record.event_id])
                except AuthenticationError as exc:
                    self._record_failure(record, exc.message, on_progress)
                    return self._finish(exc.message)
                except NetworkError as exc:
                    network_errors += 1
                    self._record_failure(record, exc.message, on_progress)
                    if network_errors >= MAX_CONSECUTIVE_NETWORK_ERRORS:
                        return self._finish("Connexion perdue : les photos restantes sont toujours en attente.")
                except UploadError as exc:
                    network_errors = 0
                    self._record_failure(record, exc.message, on_progress)
                else:
                    network_errors = 0
                    self.repo.mark_uploaded(record.code)
                    with self._lock:
                        self._progress.done += 1
                        self._progress.succeeded += 1
                    logger.info("Upload réussi : %s", record.code)
                    if on_progress:
                        on_progress(self._snapshot(), record, None)
        return self._finish()

    def server_reachable(self) -> bool:
        try:
            response = requests.get(health_url(self.config.upload_api_url), timeout=8)
        except requests.RequestException:
            return False
        return response.status_code < 500

    def _send(self, http: requests.Session, record: PhotoRecord, event: Event | None) -> None:
        path = self.storage.absolute(record.final_path)
        if not path.is_file():
            raise UploadError("Fichier de la photo finale introuvable sur le disque.")
        data = {
            "photo_code": record.code,
            "event": event.slug if event else "sans-evenement",
            "event_name": event.name if event else "Sans événement",
            "event_date": event.event_date if event else "",
            "date": record.created_at,
        }
        headers = {
            "Authorization": f"Bearer {self.config.upload_api_token}",
            "User-Agent": f"Photobooth/{APP_VERSION}",
        }
        try:
            with path.open("rb") as handle:
                response = http.post(
                    self.config.upload_api_url,
                    headers=headers,
                    data=data,
                    files={"photo": (f"{record.code}.jpg", handle, "image/jpeg")},
                    timeout=(10, self.config.upload_timeout),
                )
        except requests.RequestException as exc:
            raise NetworkError(f"Erreur réseau ({exc.__class__.__name__}).") from exc
        if response.status_code in (200, 201):
            return
        detail = _error_detail(response)
        if response.status_code in (401, 403):
            raise AuthenticationError("Token refusé par le serveur : vérifiez UPLOAD_API_TOKEN.")
        raise UploadError(f"Refusée par le serveur (HTTP {response.status_code}) : {detail}")

    def _record_failure(self, record: PhotoRecord, message: str, on_progress: ProgressCallback | None) -> None:
        self.repo.mark_upload_failed(record.code, message)
        logger.error("Erreur d'upload pour %s : %s", record.code, message)
        with self._lock:
            self._progress.done += 1
            self._progress.failed += 1
            if len(self._progress.errors) < MAX_REPORTED_ERRORS:
                self._progress.errors.append({"code": record.code, "error": message})
        if on_progress:
            on_progress(self._snapshot(), record, message)

    def _update(self, **changes: Any) -> None:
        with self._lock:
            for key, value in changes.items():
                setattr(self._progress, key, value)

    def _snapshot(self) -> UploadProgress:
        with self._lock:
            return UploadProgress(**{**asdict(self._progress), "errors": list(self._progress.errors)})

    def _finish(self, message: str | None = None) -> UploadProgress:
        with self._lock:
            progress = self._progress
            progress.running = False
            progress.current = None
            progress.finished_at = now_iso()
            if message is None:
                message = f"Terminé : {progress.succeeded} envoyée(s), {progress.failed} en échec."
            progress.message = message
        logger.info("Upload terminé : %s", message)
        return self._snapshot()


def _error_detail(response: requests.Response) -> str:
    try:
        payload = response.json()
    except ValueError:
        return response.text[:200] or response.reason
    if isinstance(payload, dict):
        return str(payload.get("error") or payload.get("message") or payload)[:200]
    return str(payload)[:200]
