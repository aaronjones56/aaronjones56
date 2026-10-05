"""Routes de la borne : page plein écran et API utilisée par static/js/kiosk.js."""

from __future__ import annotations

import logging
from typing import Any

from flask import Blueprint, Response, abort, current_app, render_template, send_file

from routes.helpers import check_pin, get_services, is_admin, json_ok, read_json, require_photo_code, safe_check
from services.container import Services
from services.system_service import close_kiosk_browser, schedule_exit

logger = logging.getLogger(__name__)
bp = Blueprint("kiosk", __name__)


def ui_config(services: Services) -> dict[str, Any]:
    """Réglages utiles à l'interface (relus à chaque retour à l'accueil)."""
    settings = services.settings.runtime_values()
    config = services.config
    return {
        "title": config.kiosk_title,
        "session_timeout": settings["session_timeout"],
        "countdown_seconds": settings["countdown_seconds"],
        "print_enabled": settings["print_enabled"],
        "auto_print": settings["auto_print"],
        "print_max_copies": settings["print_max_copies"],
        "preview_mirror": settings["preview_mirror"],
        "sound_enabled": settings["sound_enabled"],
        "camera_preview": services.camera.supports_preview,
        "camera_mode": services.camera.mode,
        "crop_centering": list(config.crop_centering),
        "retention_days": config.photo_retention_days,
        "notice": "Les photos seront disponibles après l'événement.",
    }


def _printer_check(services: Services) -> dict[str, Any]:
    if not services.settings.runtime("print_enabled"):
        return {"ok": True, "message": "Impression désactivée", "warning": False, "state": "disabled"}
    return safe_check(services.printer.check)


@bp.get("/")
def kiosk_page() -> str:
    config = get_services().config
    return render_template(
        "kiosk.html",
        title=config.kiosk_title,
        accent=config.accent_color,
        asset_version=current_app.config["ASSET_VERSION"],
    )


@bp.get("/api/health")
def health() -> Response:
    return json_ok(status="up")


@bp.get("/api/config")
def api_config() -> Response:
    services = get_services()
    return json_ok(ui=ui_config(services), event=services.events.active_event().to_dict())


@bp.get("/api/status")
def api_status() -> Response:
    """Vérifications de l'écran de démarrage : caméra, imprimante, base, stockage."""
    services = get_services()
    checks = {
        "camera": safe_check(services.camera.check),
        "printer": _printer_check(services),
        "database": safe_check(services.db.check),
        "storage": safe_check(services.storage.check),
    }
    for name, result in checks.items():
        if not result["ok"]:
            logger.warning("Vérification au démarrage : %s en erreur (%s)", name, result["message"])
    return json_ok(checks=checks, ui=ui_config(services), event=services.events.active_event().to_dict())


@bp.get("/api/frames")
def api_frames() -> Response:
    frames = get_services().frames.scan()
    return json_ok(frames=[frame.to_public_dict() for frame in frames])


@bp.get("/frames/<frame_id>/preview")
def frame_preview(frame_id: str) -> Response:
    services = get_services()
    frame = services.frames.get(frame_id)
    if frame is None:
        abort(404)
    return send_file(services.photos.frame_preview_path(frame), max_age=3600)


@bp.get("/frames/<frame_id>/overlay")
def frame_overlay(frame_id: str) -> Response:
    frame = get_services().frames.get(frame_id)
    if frame is None or frame.overlay_path is None:
        abort(404)
    return send_file(frame.overlay_path, mimetype="image/png", max_age=3600)


@bp.get("/api/camera/preview")
def camera_preview() -> Response:
    """Image d'aperçu en direct (JPEG) ; 204 si l'appareil n'en fournit pas."""
    camera = get_services().camera
    if not camera.supports_preview:
        return Response(status=204)
    data = camera.preview_jpeg()
    if not data:
        return Response(status=204)
    return Response(data, mimetype="image/jpeg", headers={"Cache-Control": "no-store"})


@bp.post("/api/session/start")
def session_start() -> Response:
    frame_id = str(read_json().get("frame_id") or "")
    session = get_services().photos.start_session(frame_id)
    return json_ok(session=session.to_dict())


@bp.post("/api/capture")
def capture() -> Response:
    session_id = str(read_json().get("session_id") or "")
    return json_ok(**get_services().photos.capture(session_id))


@bp.post("/api/session/reset")
def session_reset() -> Response:
    session_id = str(read_json().get("session_id") or "")
    return json_ok(abandoned=get_services().photos.abandon(session_id))


@bp.get("/api/session/<session_id>/shot/<int:number>")
def session_shot(session_id: str, number: int) -> Response:
    data = get_services().photos.shot_preview(session_id, number)
    return Response(data, mimetype="image/jpeg", headers={"Cache-Control": "no-store"})


@bp.post("/api/print/<code>")
def print_photo(code: str) -> Response:
    copies = read_json().get("copies", 1)
    photo = get_services().photos.print_photo(require_photo_code(code), copies)
    return json_ok(photo=photo)


@bp.get("/api/photo/<code>")
def photo_info(code: str) -> Response:
    services = get_services()
    return json_ok(photo=services.photos.payload(services.photos.get(require_photo_code(code))))


def _photo_file(code: str, kind: str) -> Response:
    services = get_services()
    record = services.photos.get(require_photo_code(code))
    if kind == "thumb":
        path = services.photos.thumbnail_path(record)
    else:
        path = services.photos.files_for(record)[kind]
    if not path.is_file():
        abort(404)
    return send_file(path, max_age=86400)


@bp.get("/photo/<code>")
def photo_final(code: str) -> Response:
    return _photo_file(code, "final")


@bp.get("/photo/<code>/qr")
def photo_qr(code: str) -> Response:
    return _photo_file(code, "qr")


@bp.get("/photo/<code>/thumb")
def photo_thumb(code: str) -> Response:
    return _photo_file(code, "thumb")


@bp.post("/api/kiosk/quit")
def kiosk_quit() -> Response:
    """Ferme le navigateur kiosk et arrête le serveur (Ctrl+Alt+Q ou menu caché, PIN requis)."""
    if not is_admin():
        check_pin(read_json().get("pin"))
    services = get_services()
    logger.info("Fermeture du kiosk demandée")

    def shutdown() -> None:
        close_kiosk_browser()
        services.close()

    schedule_exit(0, shutdown)
    return json_ok(message="Fermeture du photobooth…")
