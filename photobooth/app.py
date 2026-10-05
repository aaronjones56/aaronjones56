"""Photobooth : application Flask de la borne et serveur local.

Lancement :
    python app.py            serveur de production (waitress) sur http://127.0.0.1:5000
    python app.py --dev      serveur de développement Flask (messages d'erreur détaillés)
"""

from __future__ import annotations

import argparse
import hashlib
import logging
import secrets
import sys
import time
from dataclasses import replace
from datetime import timedelta
from pathlib import Path

from flask import Flask, Response, request
from werkzeug.exceptions import HTTPException

from config import APP_VERSION, Config, load_config
from routes import register_blueprints
from routes.helpers import json_error
from services.container import build_services
from services.errors import PhotoboothError
from services.logging_setup import setup_logging
from services.system_service import LoginThrottle

logger = logging.getLogger("photobooth")

CONTENT_SECURITY_POLICY = (
    "default-src 'self'; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'; "
    "script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
)
WRITE_METHODS = {"POST", "PUT", "PATCH", "DELETE"}


def create_app(config: Config | None = None) -> Flask:
    """Crée l'application et tous les services (caméra, imprimante, base…)."""
    config = config or load_config()
    app = Flask(
        __name__,
        static_folder=str(config.base_dir / "static"),
        template_folder=str(config.base_dir / "templates"),
    )
    app.config.update(
        SECRET_KEY=config.secret_key or _load_or_create_secret(config.data_dir),
        SESSION_COOKIE_NAME="photobooth_session",
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Strict",
        PERMANENT_SESSION_LIFETIME=timedelta(minutes=30),
        MAX_CONTENT_LENGTH=1024 * 1024,
        SEND_FILE_MAX_AGE_DEFAULT=timedelta(hours=1),
        ASSET_VERSION=_asset_version(config.base_dir / "static"),
    )
    app.json.ensure_ascii = False  # type: ignore[attr-defined]
    app.json.sort_keys = False  # type: ignore[attr-defined]

    for warning in config.warnings:
        logger.warning("Configuration : %s", warning)
    app.extensions["photobooth"] = build_services(config)
    app.extensions["login_throttle"] = LoginThrottle()
    register_blueprints(app)
    _register_hooks(app)
    _register_error_handlers(app)
    return app


def _load_or_create_secret(data_dir: Path) -> str:
    """Clé de session aléatoire, conservée dans data/.secret_key si FLASK_SECRET_KEY est vide."""
    path = data_dir / ".secret_key"
    try:
        secret = path.read_text(encoding="utf-8").strip()
    except OSError:
        secret = ""
    if len(secret) >= 32:
        return secret
    secret = secrets.token_hex(32)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(secret, encoding="utf-8")
    return secret


def _asset_version(static_dir: Path) -> str:
    """Empreinte des CSS/JS pour forcer le navigateur à recharger après une mise à jour."""
    digest = hashlib.sha1(APP_VERSION.encode())
    for path in sorted(static_dir.glob("*/*.*")):
        if path.suffix in {".css", ".js"}:
            digest.update(f"{path.name}:{path.stat().st_mtime_ns}".encode())
    return digest.hexdigest()[:10]


def _register_hooks(app: Flask) -> None:
    @app.before_request
    def require_json_body() -> Response | None:
        # Les requêtes de modification doivent être en JSON : un site tiers ne peut pas les forger.
        if request.method in WRITE_METHODS and not request.is_json:
            return json_error("Requête invalide : JSON attendu.", 415, "json_required")
        return None

    @app.after_request
    def security_headers(response: Response) -> Response:
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("X-Frame-Options", "DENY")
        response.headers.setdefault("Referrer-Policy", "no-referrer")
        if request.path.startswith("/api/"):
            response.headers["Cache-Control"] = "no-store"
        if response.mimetype == "text/html":
            response.headers.setdefault("Content-Security-Policy", CONTENT_SECURITY_POLICY)
            response.headers.setdefault("Cache-Control", "no-store")
        return response


def _register_error_handlers(app: Flask) -> None:
    @app.errorhandler(PhotoboothError)
    def handle_photobooth_error(error: PhotoboothError) -> Response:
        return json_error(error.message, error.status_code, error.error_code)

    @app.errorhandler(HTTPException)
    def handle_http_error(error: HTTPException) -> Response | HTTPException:
        if request.path.startswith("/api/"):
            return json_error(error.description or error.name, error.code or 500, "http_error")
        return error

    @app.errorhandler(Exception)
    def handle_unexpected_error(error: Exception) -> Response:
        logger.exception("Erreur inattendue sur %s %s", request.method, request.path)
        if request.path.startswith("/api/"):
            return json_error("Erreur interne : consultez les journaux.", 500, "internal_error")
        return Response(
            "<!doctype html><meta charset='utf-8'><title>Erreur</title>"
            "<p style='font-family:sans-serif'>Une erreur est survenue. <a href='/'>Retour</a></p>",
            status=500,
            mimetype="text/html",
        )


def _serve(app: Flask, host: str, port: int) -> None:
    """Serveur waitress (multi-thread, fiable sous Windows)."""
    from waitress import create_server

    for attempt in range(1, 11):
        try:
            server = create_server(app, host=host, port=port, threads=8, channel_timeout=120, ident="Photobooth")
            break
        except OSError as exc:
            if attempt == 10:
                raise
            logger.warning("Port %s indisponible (%s) : nouvel essai dans 1 seconde", port, exc)
            time.sleep(1)
    server.run()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Serveur local du photobooth.")
    parser.add_argument("--host", help="adresse d'écoute (défaut : HOST du .env, 127.0.0.1)")
    parser.add_argument("--port", type=int, help="port d'écoute (défaut : PORT du .env, 5000)")
    parser.add_argument("--dev", action="store_true", help="serveur de développement Flask")
    args = parser.parse_args(argv)

    config = load_config()
    if args.host or args.port:
        config = replace(config, host=args.host or config.host, port=args.port or config.port)
    setup_logging(config.log_dir, config.log_level)
    logger.info("=" * 60)
    logger.info(
        "Démarrage du photobooth %s (caméra : %s, imprimante : %s)",
        APP_VERSION,
        config.camera_mode,
        config.printer_mode,
    )
    try:
        app = create_app(config)
    except Exception:
        logger.exception("Impossible d'initialiser le photobooth")
        return 1

    services = app.extensions["photobooth"]
    url = f"http://{config.host}:{config.port}"
    logger.info("Photobooth prêt : %s (administration : %s/admin)", url, url)
    try:
        if args.dev:
            app.run(host=config.host, port=config.port, debug=True, use_reloader=False, threaded=True)
        else:
            _serve(app, config.host, config.port)
    except KeyboardInterrupt:
        logger.info("Arrêt demandé (Ctrl+C)")
    except OSError as exc:
        logger.error("Impossible d'écouter sur %s : %s", url, exc)
        return 1
    finally:
        services.close()
        logger.info("Photobooth arrêté")
    return 0


if __name__ == "__main__":
    sys.exit(main())
