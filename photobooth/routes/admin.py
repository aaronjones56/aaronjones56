"""Routes de l'administration (/admin), protégées par le code PIN."""

from __future__ import annotations

import logging
import math
import re
import time
from datetime import datetime
from typing import Any

from flask import Blueprint, Response, abort, current_app, render_template, request, send_file, session

from config import APP_VERSION
from routes.helpers import (
    admin_required,
    check_pin,
    get_services,
    is_admin,
    json_ok,
    login_admin,
    read_json,
    require_photo_code,
    safe_check,
)
from services.container import Services
from services.errors import ValidationError
from services.logging_setup import LOG_FILE_NAME
from services.system_service import close_kiosk_browser, logs_zip, restart_process, schedule_exit

logger = logging.getLogger(__name__)
bp = Blueprint("admin", __name__)

_TEST_FILE = re.compile(r"^[A-Za-z0-9_.-]+\.jpg$")


@bp.get("/admin")
def admin_page() -> str:
    config = get_services().config
    return render_template(
        "admin.html",
        authenticated=is_admin(),
        title=config.kiosk_title,
        accent=config.accent_color,
        asset_version=current_app.config["ASSET_VERSION"],
    )


@bp.post("/admin/login")
def admin_login() -> Response:
    check_pin(read_json().get("pin"))
    login_admin()
    logger.info("Connexion à l'administration")
    return json_ok()


@bp.post("/admin/logout")
def admin_logout() -> Response:
    session.clear()
    return json_ok()


# --- Tableau de bord ----------------------------------------------------------------


def _printer_status(services: Services) -> dict[str, Any]:
    status = safe_check(services.printer.check)
    if not services.settings.runtime("print_enabled"):
        status["message"] = "Impression désactivée dans les réglages"
    return {**status, **services.printer.describe()}


@bp.get("/api/admin/stats")
@admin_required
def admin_stats() -> Response:
    services = get_services()
    event = services.events.active_event()
    devices = {
        "camera": {**safe_check(services.camera.check), **services.camera.describe()},
        "printer": _printer_status(services),
        "storage": safe_check(services.storage.check),
        "database": safe_check(services.db.check),
    }
    return json_ok(
        event=event.to_dict(),
        stats=services.events.stats(event),
        pending_total=services.repo.count_pending(),
        devices=devices,
        connectivity=services.connectivity.snapshot(),
        disk=services.storage.disk_usage().to_dict(),
        upload={
            "enabled": services.config.upload_enabled,
            "problem": services.uploader.configuration_problem(),
            "progress": services.uploader.progress(),
        },
        app={
            "version": APP_VERSION,
            "supervised": services.config.supervised,
            "uptime_seconds": int(time.time() - services.started_at),
        },
    )


# --- Événements ----------------------------------------------------------------------


@bp.get("/api/admin/events")
@admin_required
def admin_events() -> Response:
    services = get_services()
    active = services.events.active_event()
    events = [
        {**event.to_dict(), "active": event.id == active.id, "stats": services.events.stats(event)}
        for event in services.events.list_events()
    ]
    return json_ok(events=events, active_id=active.id)


@bp.post("/api/admin/events")
@admin_required
def admin_create_event() -> tuple[Response, int]:
    services = get_services()
    data = read_json()
    event = services.events.create(
        str(data.get("name") or ""), str(data.get("event_date") or "") or None, str(data.get("slug") or "") or None
    )
    if data.get("activate"):
        services.events.set_active(event.id)
    return json_ok(event=event.to_dict()), 201


@bp.post("/api/admin/events/<int:event_id>/activate")
@admin_required
def admin_activate_event(event_id: int) -> Response:
    return json_ok(event=get_services().events.set_active(event_id).to_dict())


# --- Photos --------------------------------------------------------------------------


@bp.get("/api/admin/photos")
@admin_required
def admin_photos() -> Response:
    services = get_services()
    event_id = request.args.get("event_id", type=int) or services.events.active_event().id
    per_page = min(96, max(6, request.args.get("per_page", 24, type=int)))
    total = services.repo.count_for_event(event_id)
    pages = max(1, math.ceil(total / per_page))
    page = min(pages, max(1, request.args.get("page", 1, type=int)))
    records = services.repo.list_for_event(event_id, per_page, (page - 1) * per_page)
    return json_ok(
        photos=[services.photos.payload(record) for record in records],
        total=total,
        page=page,
        pages=pages,
        event_id=event_id,
    )


@bp.get("/api/admin/photos/<code>")
@admin_required
def admin_photo(code: str) -> Response:
    services = get_services()
    return json_ok(photo=services.photos.payload(services.photos.get(require_photo_code(code))))


@bp.delete("/api/admin/photos/<code>")
@admin_required
def admin_delete_photo(code: str) -> Response:
    get_services().photos.delete(require_photo_code(code))
    return json_ok()


@bp.post("/api/admin/photos/<code>/print")
@admin_required
def admin_print_photo(code: str) -> Response:
    copies = read_json().get("copies", 1)
    return json_ok(photo=get_services().photos.print_photo(require_photo_code(code), copies))


@bp.get("/admin/photos/<code>/<kind>")
@admin_required
def admin_photo_file(code: str, kind: str) -> Response:
    """Téléchargement de la photo finale (download) ou de l'original (original)."""
    if kind not in {"download", "original"}:
        abort(404)
    services = get_services()
    record = services.photos.get(require_photo_code(code))
    files = services.photos.files_for(record)
    path = files["final"] if kind == "download" else files["original"]
    if not path.is_file():
        abort(404)
    suffix = "" if kind == "download" else "-original"
    return send_file(path, as_attachment=True, download_name=f"photo-{record.code}{suffix}.jpg")


# --- Matériel ------------------------------------------------------------------------


@bp.get("/api/admin/printers")
@admin_required
def admin_printers() -> Response:
    services = get_services()
    printer = services.printer
    return json_ok(
        mode=printer.mode,
        label=printer.label,
        selected=printer.printer_name,
        fit_mode=services.config.print_fit_mode,
        printers=[info.to_dict() for info in printer.list_printers()],
        status=_printer_status(services),
    )


@bp.post("/api/admin/printer")
@admin_required
def admin_set_printer() -> Response:
    services = get_services()
    name = str(read_json().get("name") or "").strip()
    if name and name not in {info.name for info in services.printer.list_printers()}:
        raise ValidationError("Imprimante inconnue : actualisez la liste.")
    services.printer.set_printer(name)
    if name:
        services.settings.set("printer_name", name)
    else:
        services.settings.delete("printer_name")
    logger.info("Imprimante sélectionnée : %s", name or "imprimante par défaut de Windows")
    return json_ok(selected=name, status=_printer_status(services))


@bp.post("/api/admin/test-camera")
@admin_required
def admin_test_camera() -> Response:
    path = get_services().photos.test_camera()
    return json_ok(url=f"/admin/tests/{path.name}", message="L'appareil photo fonctionne.")


@bp.post("/api/admin/test-printer")
@admin_required
def admin_test_printer() -> Response:
    get_services().photos.test_printer()
    return json_ok(message="Page de test envoyée à l'imprimante.")


@bp.get("/admin/tests/<name>")
@admin_required
def admin_test_file(name: str) -> Response:
    path = get_services().storage.tests_dir / name
    if not _TEST_FILE.fullmatch(name) or not path.is_file():
        abort(404)
    return send_file(path, mimetype="image/jpeg", max_age=0)


# --- Upload ----------------------------------------------------------------------------


@bp.get("/api/admin/upload/status")
@admin_required
def admin_upload_status() -> Response:
    services = get_services()
    config = services.config
    return json_ok(
        progress=services.uploader.progress(),
        problem=services.uploader.configuration_problem(),
        enabled=config.upload_enabled,
        url=config.upload_api_url,
        token_configured=bool(config.upload_api_token),
        pending_active=services.repo.count_pending(services.events.active_event().id),
        pending_all=services.repo.count_pending(),
        connectivity=services.connectivity.snapshot(),
    )


@bp.post("/api/admin/upload")
@admin_required
def admin_upload() -> Response:
    services = get_services()
    scope = read_json().get("scope", "active")
    event_id = None if scope == "all" else services.events.active_event().id
    logger.info(
        "Upload lancé depuis l'administration (%s)", "tous les événements" if event_id is None else "événement actif"
    )
    return json_ok(progress=services.uploader.start_background(event_id))


# --- Cadres et réglages ------------------------------------------------------------------


@bp.get("/api/admin/frames")
@admin_required
def admin_frames() -> Response:
    services = get_services()
    frames = services.frames.scan()
    return json_ok(
        frames=[
            {
                **frame.to_public_dict(),
                "folder": frame.folder.name if frame.folder else None,
                "has_overlay": frame.overlay_path is not None,
                "has_preview": frame.preview_path is not None,
            }
            for frame in frames
        ],
        errors=services.frames.errors,
        frames_dir=str(services.config.frames_dir),
    )


def _config_summary(services: Services) -> dict[str, Any]:
    config = services.config
    return {
        "Version": APP_VERSION,
        "Appareil photo": f"{services.camera.label} (CAMERA_MODE={services.camera.mode})",
        "Imprimante": f"{services.printer.label} (PRINTER_MODE={services.printer.mode})",
        "Format de sortie": f"{config.output_width} x {config.output_height} px",
        "Adresse publique des photos": config.public_photo_url,
        "Upload": "activé" if config.upload_enabled else "désactivé",
        "Serveur d'upload": config.upload_api_url or "non configuré",
        "Token d'upload": "configuré" if config.upload_api_token else "absent",
        "Conservation en ligne": f"{config.photo_retention_days} jours",
        "Dossier des données": str(config.data_dir),
        "Dossier des cadres": str(config.frames_dir),
        "Base de données": str(config.database_path),
        "Journaux": str(config.log_dir / LOG_FILE_NAME),
        "Lancement supervisé": "oui (redémarrage automatique)" if config.supervised else "non",
    }


@bp.get("/api/admin/settings")
@admin_required
def admin_settings() -> Response:
    services = get_services()
    return json_ok(settings=services.settings.describe(), config=_config_summary(services))


@bp.post("/api/admin/settings")
@admin_required
def admin_update_settings() -> Response:
    services = get_services()
    data = read_json()
    if data.get("reset"):
        services.settings.reset_runtime()
        logger.info("Réglages réinitialisés (valeurs du fichier .env)")
    else:
        values = data.get("values")
        if not isinstance(values, dict):
            raise ValidationError("Aucun réglage reçu.")
        services.settings.update_runtime(values)
        logger.info("Réglages modifiés : %s", ", ".join(f"{key}={value}" for key, value in values.items()))
    return json_ok(settings=services.settings.describe())


# --- Système ---------------------------------------------------------------------------


@bp.get("/admin/logs/download")
@admin_required
def admin_download_logs() -> Response:
    archive = logs_zip(get_services().config.log_dir)
    return send_file(
        archive,
        mimetype="application/zip",
        as_attachment=True,
        download_name=f"photobooth-logs-{datetime.now():%Y%m%d-%H%M}.zip",
    )


@bp.post("/api/admin/restart")
@admin_required
def admin_restart() -> Response:
    services = get_services()
    logger.info("Redémarrage demandé depuis l'administration")
    restart_process(services.config.supervised, services.close)
    return json_ok(message="Redémarrage en cours…")


@bp.post("/api/admin/quit")
@admin_required
def admin_quit() -> Response:
    services = get_services()
    logger.info("Fermeture du kiosk demandée depuis l'administration")

    def shutdown() -> None:
        close_kiosk_browser()
        services.close()

    schedule_exit(0, shutdown)
    return json_ok(message="Fermeture du photobooth…")
