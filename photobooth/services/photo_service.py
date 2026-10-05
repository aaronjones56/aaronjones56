"""Déroulement d'une session photo : capture, montage, QR code, impression.

Une session correspond à un passage devant la borne avec un cadre donné. Elle
compte autant de prises que d'emplacements dans le cadre (1 pour une photo simple,
3 pour une bande photomaton). Après la dernière prise, la photo finale, le QR code et
la vignette sont créés puis la photo est enregistrée en base.
"""

from __future__ import annotations

import errno
import logging
import threading
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import TYPE_CHECKING, Any

from PIL import Image

from services import compositor
from services.camera import CameraProvider
from services.codes import format_code, generate_code
from services.devices import is_readable_image
from services.errors import (
    CameraError,
    ConflictError,
    NotFoundError,
    PhotoboothError,
    PrinterError,
    StorageError,
    ValidationError,
)
from services.event_service import Event, EventService
from services.frames import Frame, FrameLibrary
from services.photo_repository import PhotoRecord, PhotoRepository
from services.printer import PrinterProvider
from services.qr_service import QrService
from services.settings_service import SettingsService
from services.storage import EventFolder, Storage
from services.utils import safe_unlink

if TYPE_CHECKING:
    from config import Config

logger = logging.getLogger(__name__)

SESSION_TTL_SECONDS = 30 * 60


@dataclass
class CaptureSession:
    id: str
    event: Event
    frame: Frame
    folder: EventFolder
    code: str
    shots: list[Path] = field(default_factory=list)
    started_at: float = field(default_factory=time.monotonic)
    finished: bool = False

    @property
    def shots_total(self) -> int:
        return self.frame.shots

    @property
    def complete(self) -> bool:
        return len(self.shots) >= self.shots_total

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "frame_id": self.frame.id,
            "shots_total": self.shots_total,
            "shots_taken": len(self.shots),
        }


class PhotoService:
    """Orchestration de la prise de vue ; aucune erreur matérielle n'arrête l'application."""

    def __init__(
        self,
        *,
        config: Config,
        repo: PhotoRepository,
        events: EventService,
        frames: FrameLibrary,
        storage: Storage,
        camera: CameraProvider,
        printer: PrinterProvider,
        qr: QrService,
        settings: SettingsService,
    ) -> None:
        self.config = config
        self.repo = repo
        self.events = events
        self.frames = frames
        self.storage = storage
        self.camera = camera
        self.printer = printer
        self.qr = qr
        self.settings = settings
        self._sessions: dict[str, CaptureSession] = {}
        self._sessions_lock = threading.Lock()
        self._capture_lock = threading.Lock()
        self._print_lock = threading.Lock()

    # --- Sessions -----------------------------------------------------------

    def start_session(self, frame_id: str) -> CaptureSession:
        frame = self.frames.get(frame_id)
        if frame is None:
            raise NotFoundError("Ce cadre n'est plus disponible.")
        event = self.events.active_event()
        folder = self.storage.event_folder(event.folder).ensure()
        session = CaptureSession(id=uuid.uuid4().hex, event=event, frame=frame, folder=folder, code=self._new_code())
        with self._sessions_lock:
            self._purge_expired()
            self._sessions[session.id] = session
        self.repo.start_session(session.id, event.id, frame.id)
        logger.info(
            "Session %s démarrée : cadre « %s » (%s), %d photo(s), événement %s",
            session.id[:8],
            frame.name,
            frame.id,
            frame.shots,
            event.slug,
        )
        return session

    def capture(self, session_id: str) -> dict[str, Any]:
        """Prend la photo suivante de la session ; après la dernière, crée la photo finale."""
        session = self._get_session(session_id)
        if session.finished or session.complete:
            raise ConflictError("Cette session est déjà terminée.")
        if not self._capture_lock.acquire(blocking=False):
            raise ConflictError("Une photo est déjà en cours.")
        try:
            index = len(session.shots)
            target = session.folder.original_path(session.code, index, session.shots_total)
            self._capture_to(target)
            session.shots.append(target)
            logger.info("Photo %d/%d capturée (code %s)", index + 1, session.shots_total, session.code)
            response: dict[str, Any] = {"shot": index + 1, "shots_total": session.shots_total, "done": False}
            if not session.complete:
                response["shot_url"] = f"/api/session/{session.id}/shot/{index + 1}"
                return response
            try:
                record = self._finalize(session)
            except PhotoboothError:
                # Les originaux restent sur le disque pour pouvoir être récupérés.
                with self._sessions_lock:
                    self._sessions.pop(session.id, None)
                raise
            response.update(done=True, photo=self.payload(record))
            return response
        finally:
            self._capture_lock.release()

    def abandon(self, session_id: str) -> bool:
        """Annule une session inachevée et supprime ses prises intermédiaires."""
        with self._sessions_lock:
            session = self._sessions.pop(session_id, None)
        if session is None or session.finished:
            return False
        for shot in session.shots:
            safe_unlink(shot)
        logger.info("Session %s abandonnée (%d prise(s) supprimée(s))", session.id[:8], len(session.shots))
        return True

    def shot_preview(self, session_id: str, shot_number: int) -> bytes:
        """Vignette d'une prise intermédiaire (bande photomaton en cours)."""
        session = self._get_session(session_id)
        if not 1 <= shot_number <= len(session.shots):
            raise NotFoundError("Prise introuvable.")
        return compositor.thumbnail_bytes(session.shots[shot_number - 1], (480, 480))

    def _capture_to(self, target: Path) -> None:
        try:
            self.camera.capture(target)
        except CameraError as exc:
            logger.error("Erreur caméra : %s", exc.message)
            raise
        except OSError as exc:
            logger.exception("Erreur d'écriture pendant la capture")
            raise StorageError(_storage_message(exc)) from exc
        except Exception as exc:  # noqa: BLE001 - un pilote défaillant ne doit pas arrêter la borne
            logger.exception("Erreur caméra inattendue")
            raise CameraError("L'appareil photo n'a pas pu prendre la photo.") from exc
        if not is_readable_image(target):
            safe_unlink(target)
            logger.error("Fichier reçu de la caméra illisible : %s", target)
            raise CameraError("La photo reçue de l'appareil est illisible.")

    def _finalize(self, session: CaptureSession) -> PhotoRecord:
        folder, code = session.folder, session.code
        final_path = folder.final_path(code)
        qr_path = folder.qr_path(code)
        try:
            compositor.compose_to_file(
                session.shots, session.frame, final_path, self.config.jpeg_quality, self.config.crop_centering
            )
            self.qr.save(code, qr_path)
            compositor.make_thumbnail(final_path, folder.thumb_path(code))
        except OSError as exc:
            logger.exception("Impossible de créer la photo finale %s", code)
            raise StorageError(_storage_message(exc)) from exc
        except Exception as exc:  # noqa: BLE001
            logger.exception("Erreur pendant le montage de la photo %s", code)
            raise PhotoboothError("Le montage de la photo a échoué.") from exc

        record = self.repo.insert(
            code=code,
            event_id=session.event.id,
            frame_name=session.frame.id,
            shot_count=len(session.shots),
            original_path=self.storage.relative(session.shots[0]),
            final_path=self.storage.relative(final_path),
            qr_path=self.storage.relative(qr_path),
        )
        self.repo.complete_session(session.id, code)
        session.finished = True
        with self._sessions_lock:
            self._sessions.pop(session.id, None)
        logger.info(
            "Photo prise : code %s, cadre %s, événement %s, %d prise(s)",
            code,
            session.frame.id,
            session.event.slug,
            len(session.shots),
        )
        return record

    def _get_session(self, session_id: str) -> CaptureSession:
        with self._sessions_lock:
            session = self._sessions.get(session_id or "")
        if session is None:
            raise NotFoundError("Session expirée : recommencez depuis l'accueil.")
        return session

    def _purge_expired(self) -> None:
        now = time.monotonic()
        for session_id, session in list(self._sessions.items()):
            if now - session.started_at > SESSION_TTL_SECONDS:
                del self._sessions[session_id]
                for shot in session.shots:
                    safe_unlink(shot)

    def _new_code(self) -> str:
        for _ in range(20):
            code = generate_code()
            if not self.repo.code_exists(code):
                return code
        raise PhotoboothError("Impossible de générer un code photo unique.")

    # --- Photos -------------------------------------------------------------

    def get(self, code: str) -> PhotoRecord:
        return self.repo.require(code)

    def files_for(self, record: PhotoRecord) -> dict[str, Path]:
        """Chemins absolus des fichiers d'une photo."""
        folder = self._folder_for(record)
        return {
            "original": self.storage.absolute(record.original_path),
            "final": self.storage.absolute(record.final_path),
            "qr": self.storage.absolute(record.qr_path),
            "thumb": folder.thumb_path(record.code),
            "print": folder.print_path(record.code),
        }

    def thumbnail_path(self, record: PhotoRecord) -> Path:
        files = self.files_for(record)
        if not files["thumb"].is_file() and files["final"].is_file():
            compositor.make_thumbnail(files["final"], files["thumb"])
        return files["thumb"]

    def payload(self, record: PhotoRecord) -> dict[str, Any]:
        """Données d'une photo pour l'interface (borne et administration)."""
        limit = int(self.settings.runtime("print_limit_per_photo"))
        remaining = None if limit == 0 else max(0, limit - record.print_count)
        frame = self.frames.get(record.frame_name, rescan=False)
        return {
            "code": record.code,
            "display_code": format_code(record.code),
            "public_url": self.qr.photo_url(record.code),
            "final_url": f"/photo/{record.code}",
            "qr_url": f"/photo/{record.code}/qr",
            "thumb_url": f"/photo/{record.code}/thumb",
            "frame_id": record.frame_name,
            "frame_name": frame.name if frame else record.frame_name,
            "shot_count": record.shot_count,
            "created_at": record.created_at,
            "printed": record.printed,
            "print_count": record.print_count,
            "prints_remaining": remaining,
            "uploaded": record.uploaded,
            "uploaded_at": record.uploaded_at,
            "upload_attempts": record.upload_attempts,
            "last_upload_error": record.last_upload_error,
        }

    def delete(self, code: str) -> None:
        record = self.repo.require(code)
        folder = self._folder_for(record)
        files = self.files_for(record)
        for path in folder.original_paths(record.code, record.shot_count):
            safe_unlink(path)
        for key in ("original", "final", "qr", "thumb", "print"):
            safe_unlink(files[key])
        self.repo.delete(code)
        logger.info("Photo %s supprimée par l'administrateur", code)

    def _folder_for(self, record: PhotoRecord) -> EventFolder:
        event = self.events.get(record.event_id)
        if event is not None:
            return self.storage.event_folder(event.folder)
        return EventFolder(self.storage.absolute(record.final_path).parent.parent)

    # --- Impression ---------------------------------------------------------

    def print_photo(self, code: str, copies: int = 1) -> dict[str, Any]:
        """Imprime la photo ; en cas d'échec, l'erreur est renvoyée sans rien casser."""
        if not self.settings.runtime("print_enabled"):
            raise ConflictError("L'impression est désactivée.")
        record = self.repo.require(code)
        try:
            copies = int(copies)
        except (TypeError, ValueError) as exc:
            raise ValidationError("Nombre de copies invalide.") from exc
        copies = max(1, min(copies, int(self.settings.runtime("print_max_copies"))))
        limit = int(self.settings.runtime("print_limit_per_photo"))
        if limit and record.print_count + copies > limit:
            remaining = max(0, limit - record.print_count)
            if remaining == 0:
                raise ConflictError("Nombre maximum d'impressions atteint pour cette photo.")
            raise ConflictError(f"Il ne reste que {remaining} impression(s) possible(s) pour cette photo.")

        path = self.print_file(record)
        with self._print_lock:
            self._send_to_printer(path, copies, f"Photobooth {code}")
        record = self.repo.mark_printed(code, copies)
        logger.info("Impression : photo %s, %d copie(s), imprimante « %s »", code, copies, self.printer.printer_name)
        return self.payload(record)

    def print_file(self, record: PhotoRecord) -> Path:
        """Fichier à imprimer : la photo finale, avec le QR code si QR_ON_PRINT est actif."""
        files = self.files_for(record)
        if not files["final"].is_file():
            raise NotFoundError("Le fichier de la photo est introuvable.")
        if not self.settings.runtime("qr_on_print"):
            return files["final"]
        frame = self.frames.get(record.frame_name, rescan=False)
        spec = frame.qr if frame is not None else None
        size = spec.size if spec is not None else self.config.qr_print_size
        with Image.open(files["final"]) as source:
            image = source.convert("RGB")
        badge_image = compositor.add_qr_badge(
            image,
            self.qr.image_for(record.code, size=size),
            format_code(record.code),
            spec=spec,
            size=size,
            position=self.config.qr_print_position,
        )
        return compositor.save_jpeg(badge_image, files["print"], self.config.jpeg_quality)

    def _send_to_printer(self, path: Path, copies: int, job_name: str) -> None:
        try:
            self.printer.print_image(path, copies=copies, job_name=job_name)
        except PrinterError as exc:
            logger.error("Erreur imprimante : %s", exc.message)
            raise
        except Exception as exc:  # noqa: BLE001
            logger.exception("Erreur imprimante inattendue")
            raise PrinterError("L'impression a échoué.") from exc

    # --- Tests matériels (administration) -------------------------------------

    def test_camera(self) -> Path:
        """Prend une photo de test dans data/tests/ (sans l'enregistrer comme photo)."""
        self.storage.ensure()
        target = self.storage.tests_dir / f"camera-test-{datetime.now():%Y%m%d-%H%M%S}.jpg"
        if not self._capture_lock.acquire(timeout=10):
            raise ConflictError("Une photo est déjà en cours.")
        try:
            self._capture_to(target)
        finally:
            self._capture_lock.release()
        logger.info("Test caméra réussi : %s", target.name)
        return target

    def test_printer(self) -> Path:
        """Imprime une mire de test 10 x 15 cm."""
        from services.assets import generate_print_test_card

        self.storage.ensure()
        target = self.storage.tests_dir / "print-test.jpg"
        generate_print_test_card(target, self.printer.printer_name or "Imprimante par défaut", self.config.output_size)
        with self._print_lock:
            self._send_to_printer(target, 1, "Photobooth - test")
        logger.info("Test imprimante envoyé à « %s »", self.printer.printer_name)
        return target

    def frame_preview_path(self, frame: Frame) -> Path:
        """preview.jpg du cadre, ou vignette générée automatiquement (mise en cache)."""
        if frame.preview_path is not None:
            return frame.preview_path
        from services.assets import render_frame_preview

        target = self.storage.cache_dir / "previews" / f"{frame.id}-{frame.version}.jpg"
        if not target.is_file():
            render_frame_preview(frame, self.config.test_photo, target)
        return target


def _storage_message(error: OSError) -> str:
    if error.errno == errno.ENOSPC:
        return "Disque plein : impossible d'enregistrer la photo."
    return "Impossible d'enregistrer la photo sur le disque."
