"""Assemblage de tous les services à partir de la configuration."""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass, field

from config import Config
from services.camera import CameraProvider, create_camera
from services.database import Database
from services.event_service import EventService
from services.frames import FrameLibrary
from services.photo_repository import PhotoRepository
from services.photo_service import PhotoService
from services.printer import PrinterProvider, create_printer
from services.qr_service import QrService
from services.settings_service import SettingsService
from services.storage import Storage
from services.system_service import ConnectivityMonitor
from services.upload_service import UploadService

logger = logging.getLogger(__name__)


@dataclass
class Services:
    config: Config
    db: Database
    storage: Storage
    settings: SettingsService
    repo: PhotoRepository
    events: EventService
    frames: FrameLibrary
    camera: CameraProvider
    printer: PrinterProvider
    qr: QrService
    photos: PhotoService
    uploader: UploadService
    connectivity: ConnectivityMonitor
    started_at: float = field(default_factory=time.time)

    def close(self) -> None:
        """Libère le matériel ; appelé à l'arrêt de l'application."""
        try:
            self.camera.close()
        except Exception:  # noqa: BLE001
            logger.exception("Erreur pendant la fermeture de la caméra")


def build_services(config: Config) -> Services:
    storage = Storage(config.data_dir)
    storage.ensure()
    db = Database(config.database_path)
    db.initialize()
    settings = SettingsService(db, config)
    repo = PhotoRepository(db)
    events = EventService(db, storage, settings, repo, config)
    frames = FrameLibrary(config.frames_dir, config.output_size)
    found = frames.scan()
    logger.info("%d cadre(s) détecté(s) : %s", len(found), ", ".join(frame.id for frame in found))
    for error in frames.errors:
        logger.warning("Cadre invalide : %s", error)
    camera = create_camera(config)
    printer = create_printer(config, settings.printer_name)
    qr = QrService(config.public_photo_url)
    photos = PhotoService(
        config=config,
        repo=repo,
        events=events,
        frames=frames,
        storage=storage,
        camera=camera,
        printer=printer,
        qr=qr,
        settings=settings,
    )
    uploader = UploadService(config, repo, events, storage)
    connectivity = ConnectivityMonitor(config.upload_api_url if config.upload_enabled else "")
    event = events.active_event()
    logger.info("Événement actif : %s (%s)", event.name, event.folder)
    return Services(
        config=config,
        db=db,
        storage=storage,
        settings=settings,
        repo=repo,
        events=events,
        frames=frames,
        camera=camera,
        printer=printer,
        qr=qr,
        photos=photos,
        uploader=uploader,
        connectivity=connectivity,
    )
