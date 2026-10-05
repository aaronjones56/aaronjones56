"""Serveur web des photos du photobooth (à héberger sur Internet, indépendant de la borne).

Routes :
    POST /api/upload          réception des photos envoyées par la borne (token obligatoire)
    GET  /p/<code>            page de la photo, ou « pas encore disponible »
    GET  /media/<code>        image (affichage)
    GET  /download/<code>     image (téléchargement)
    GET  /g/<slug>/<secret>   galerie d'un événement (désactivée tant qu'aucun lien n'est créé)
    GET  /api/health          état du serveur (utilisé par la borne avant l'upload)

Commandes (cron, administration) :
    flask --app app cleanup               supprime les photos plus vieilles que PHOTO_RETENTION_DAYS
    flask --app app gallery-enable SLUG   crée le lien secret de la galerie d'un événement
    flask --app app gallery-disable SLUG  supprime ce lien
    flask --app app delete-photo CODE     supprime une photo à la demande (RGPD)
    flask --app app stats                 photos publiées par événement
    flask --app app generate-token        génère un token d'upload aléatoire

Aucune liste publique des photos n'existe : une photo n'est accessible qu'avec son code.
"""

from __future__ import annotations

import hmac
import io
import logging
import os
import re
import secrets
import sqlite3
import tempfile
import threading
import time
from collections import defaultdict, deque
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import click
from dotenv import load_dotenv
from flask import Flask, Response, abort, jsonify, redirect, render_template, request, send_file, url_for
from PIL import Image, ImageOps, UnidentifiedImageError
from werkzeug.exceptions import HTTPException
from werkzeug.middleware.proxy_fix import ProxyFix

BASE_DIR = Path(__file__).resolve().parent
CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
CODE_PATTERN = re.compile(rf"^[{CODE_ALPHABET}]{{12}}$")
SLUG_PATTERN = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,78}[a-z0-9])?$")
ALLOWED_EXTENSIONS = {".jpg", ".jpeg", ".png"}
FORMAT_EXTENSIONS = {"JPEG": ".jpg", "PNG": ".png"}
MIME_TYPES = {".jpg": "image/jpeg", ".png": "image/png"}
MAX_PIXELS = 60_000_000
THUMB_SIZE = (480, 720)
THUMBS_FOLDER = "_thumbs"
MIN_TOKEN_LENGTH = 16

CONTENT_SECURITY_POLICY = (
    "default-src 'none'; img-src 'self'; style-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
)

logger = logging.getLogger("photo_server")


# --- Configuration ----------------------------------------------------------------


def _env_int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, "").strip() or default)
    except ValueError:
        return default


def _env_path(name: str, default: str) -> Path:
    path = Path(os.environ.get(name, "").strip() or default).expanduser()
    return path if path.is_absolute() else (BASE_DIR / path).resolve()


@dataclass(frozen=True)
class ServerConfig:
    api_token: str
    upload_dir: Path
    database_path: Path
    max_upload_mb: int = 15
    retention_days: int = 30
    site_name: str = "Photobooth"
    public_base_url: str = ""
    contact_email: str = ""
    behind_proxy: bool = False
    lookup_limit: int = 30
    lookup_window: int = 600

    @classmethod
    def from_env(cls, env_file: Path | None = BASE_DIR / ".env") -> ServerConfig:
        if env_file is not None and env_file.is_file():
            try:
                load_dotenv(env_file, override=False, encoding="utf-8")
            except UnicodeDecodeError:
                load_dotenv(env_file, override=False, encoding="cp1252")
        return cls(
            api_token=os.environ.get("UPLOAD_API_TOKEN", "").strip(),
            upload_dir=_env_path("UPLOAD_DIR", "uploads"),
            database_path=_env_path("DATABASE_PATH", "data/photos.db"),
            max_upload_mb=_env_int("MAX_UPLOAD_MB", 15),
            retention_days=_env_int("PHOTO_RETENTION_DAYS", 30),
            site_name=os.environ.get("SITE_NAME", "Photobooth").strip() or "Photobooth",
            public_base_url=os.environ.get("PUBLIC_BASE_URL", "").strip().rstrip("/"),
            contact_email=os.environ.get("CONTACT_EMAIL", "").strip(),
            behind_proxy=os.environ.get("BEHIND_PROXY", "").strip().lower() in {"1", "true", "yes", "oui"},
            lookup_limit=_env_int("LOOKUP_LIMIT", 30),
            lookup_window=_env_int("LOOKUP_WINDOW_SECONDS", 600),
        )


# --- Outils -------------------------------------------------------------------------


def now_utc() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def normalize_code(raw: str | None) -> str | None:
    """« a7k4-q92x-b3lm » devient « A7K4Q92XB3LM » ; None si le code est invalide."""
    if not raw or len(raw) > 64:
        return None
    cleaned = re.sub(r"[\s\-_.]+", "", raw).upper()
    return cleaned if CODE_PATTERN.fullmatch(cleaned) else None


def format_code(code: str) -> str:
    return "-".join(code[index : index + 4] for index in range(0, len(code), 4))


def clean_text(value: str | None, limit: int) -> str:
    return re.sub(r"\s+", " ", value or "").strip()[:limit]


def parse_datetime(value: str | None) -> str | None:
    try:
        return datetime.fromisoformat((value or "").strip()).isoformat(timespec="seconds")
    except ValueError:
        return None


def parse_date(value: str | None) -> str | None:
    try:
        return date.fromisoformat((value or "").strip()).isoformat()
    except ValueError:
        return None


def safe_child(root: Path, name: str) -> Path:
    """Chemin ``root/name`` garanti à l'intérieur de ``root`` (aucun « ../ » possible)."""
    base = root.resolve()
    candidate = (base / name).resolve()
    if not candidate.is_relative_to(base) or candidate == base:
        raise ValueError("Chemin invalide.")
    return candidate


def write_atomic(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=".upload-", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp_name, 0o644)
        os.replace(tmp_name, path)
    except BaseException:
        Path(tmp_name).unlink(missing_ok=True)
        raise


def inspect_image(data: bytes) -> tuple[str, int, int]:
    """Vérifie que les octets sont une vraie image JPEG/PNG (le nom du fichier ne compte pas)."""
    try:
        with Image.open(io.BytesIO(data)) as image:
            image_format = image.format or ""
            width, height = image.size
            if image_format not in FORMAT_EXTENSIONS:
                raise ValueError("Seules les images JPEG et PNG sont acceptées.")
            if width * height > MAX_PIXELS:
                raise ValueError("Image trop grande.")
            image.verify()
    except (UnidentifiedImageError, OSError, SyntaxError, Image.DecompressionBombError) as exc:
        raise ValueError("Le fichier n'est pas une image JPEG ou PNG valide.") from exc
    return image_format, width, height


def make_thumbnail(data: bytes) -> bytes:
    with Image.open(io.BytesIO(data)) as image:
        if image.format == "JPEG":
            image.draft("RGB", THUMB_SIZE)
        thumb = ImageOps.exif_transpose(image).convert("RGB")
    thumb.thumbnail(THUMB_SIZE, Image.Resampling.LANCZOS)
    buffer = io.BytesIO()
    thumb.save(buffer, format="JPEG", quality=82, optimize=True)
    return buffer.getvalue()


# --- Base de données ------------------------------------------------------------------

SCHEMA = """
CREATE TABLE IF NOT EXISTS events (
    slug           TEXT PRIMARY KEY,
    name           TEXT NOT NULL,
    event_date     TEXT,
    gallery_token  TEXT,
    created_at     TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS photos (
    code         TEXT PRIMARY KEY,
    event_slug   TEXT NOT NULL REFERENCES events(slug),
    filename     TEXT NOT NULL,
    mime_type    TEXT NOT NULL,
    size         INTEGER NOT NULL,
    width        INTEGER,
    height       INTEGER,
    taken_at     TEXT,
    uploaded_at  TEXT NOT NULL,
    deleted_at   TEXT
);
CREATE INDEX IF NOT EXISTS idx_photos_event ON photos(event_slug, taken_at);
CREATE INDEX IF NOT EXISTS idx_photos_uploaded ON photos(uploaded_at);
"""


class PhotoStore:
    """Index SQLite des photos publiées ; le code photo sert d'identifiant."""

    def __init__(self, path: Path) -> None:
        self.path = path

    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        connection = sqlite3.connect(str(self.path), timeout=10)
        connection.row_factory = sqlite3.Row
        try:
            with connection:
                yield connection
        finally:
            connection.close()

    def initialize(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as connection:
            connection.execute("PRAGMA journal_mode = WAL")
            connection.executescript(SCHEMA)

    def _one(self, sql: str, params: tuple[Any, ...]) -> dict[str, Any] | None:
        with self.connect() as connection:
            row = connection.execute(sql, params).fetchone()
            return dict(row) if row else None

    def _all(self, sql: str, params: tuple[Any, ...] = ()) -> list[dict[str, Any]]:
        with self.connect() as connection:
            return [dict(row) for row in connection.execute(sql, params).fetchall()]

    def upsert_event(self, slug: str, name: str, event_date: str | None) -> None:
        with self.connect() as connection:
            connection.execute(
                "INSERT INTO events (slug, name, event_date, created_at) VALUES (?, ?, ?, ?) "
                "ON CONFLICT(slug) DO UPDATE SET name = excluded.name, "
                "event_date = COALESCE(excluded.event_date, events.event_date)",
                (slug, name, event_date, now_utc()),
            )

    def get_event(self, slug: str) -> dict[str, Any] | None:
        return self._one("SELECT * FROM events WHERE slug = ?", (slug,))

    def set_gallery_token(self, slug: str, token: str | None) -> bool:
        with self.connect() as connection:
            cursor = connection.execute("UPDATE events SET gallery_token = ? WHERE slug = ?", (token, slug))
            return cursor.rowcount > 0

    def upsert_photo(self, values: dict[str, Any]) -> None:
        with self.connect() as connection:
            connection.execute(
                "INSERT INTO photos (code, event_slug, filename, mime_type, size, width, height, taken_at, "
                "uploaded_at) VALUES (:code, :event_slug, :filename, :mime_type, :size, :width, :height, :taken_at, "
                ":uploaded_at) "
                "ON CONFLICT(code) DO UPDATE SET event_slug = excluded.event_slug, filename = excluded.filename, "
                "mime_type = excluded.mime_type, size = excluded.size, width = excluded.width, "
                "height = excluded.height, taken_at = excluded.taken_at, uploaded_at = excluded.uploaded_at, "
                "deleted_at = NULL",
                values,
            )

    def get_photo(self, code: str) -> dict[str, Any] | None:
        return self._one("SELECT * FROM photos WHERE code = ?", (code,))

    def event_photos(self, slug: str) -> list[dict[str, Any]]:
        return self._all(
            "SELECT * FROM photos WHERE event_slug = ? AND deleted_at IS NULL ORDER BY taken_at, code", (slug,)
        )

    def expired_photos(self, cutoff: str) -> list[dict[str, Any]]:
        return self._all("SELECT * FROM photos WHERE deleted_at IS NULL AND uploaded_at < ?", (cutoff,))

    def mark_deleted(self, code: str) -> None:
        with self.connect() as connection:
            connection.execute("UPDATE photos SET deleted_at = ? WHERE code = ?", (now_utc(), code))

    def stats(self) -> list[dict[str, Any]]:
        return self._all(
            "SELECT e.slug, e.name, e.event_date, e.gallery_token IS NOT NULL AS gallery, "
            "SUM(p.deleted_at IS NULL) AS online, COUNT(p.code) AS total, "
            "COALESCE(SUM(CASE WHEN p.deleted_at IS NULL THEN p.size ELSE 0 END), 0) AS bytes "
            "FROM events e LEFT JOIN photos p ON p.event_slug = e.slug GROUP BY e.slug ORDER BY e.event_date DESC"
        )


class LookupLimiter:
    """Limite les recherches de codes inexistants par adresse IP : impossible de deviner les codes."""

    def __init__(self, limit: int, window_seconds: int) -> None:
        self.limit = limit
        self.window = window_seconds
        self._misses: dict[str, deque[float]] = defaultdict(deque)
        self._lock = threading.Lock()

    def _purge(self, key: str, now: float) -> deque[float]:
        misses = self._misses[key]
        while misses and now - misses[0] > self.window:
            misses.popleft()
        return misses

    def blocked(self, key: str) -> bool:
        with self._lock:
            return len(self._purge(key, time.monotonic())) >= self.limit

    def miss(self, key: str) -> None:
        with self._lock:
            now = time.monotonic()
            self._purge(key, now).append(now)
            if len(self._misses) > 10_000:
                for stale in [k for k, v in self._misses.items() if not v]:
                    del self._misses[stale]


# --- Fichiers -------------------------------------------------------------------------


def photo_file(config: ServerConfig, photo: dict[str, Any]) -> Path:
    return safe_child(config.upload_dir, photo["filename"])


def thumb_file(config: ServerConfig, code: str) -> Path:
    return safe_child(config.upload_dir, f"{THUMBS_FOLDER}/{code}.jpg")


def delete_photo_files(config: ServerConfig, photo: dict[str, Any]) -> None:
    for path in (photo_file(config, photo), thumb_file(config, photo["code"])):
        path.unlink(missing_ok=True)


def cleanup_expired(
    store: PhotoStore, config: ServerConfig, days: int, now: datetime | None = None, dry_run: bool = False
) -> list[str]:
    """Supprime les photos mises en ligne il y a plus de ``days`` jours ; renvoie leurs codes."""
    if days <= 0:
        return []
    cutoff = ((now or datetime.now(timezone.utc)) - timedelta(days=days)).isoformat(timespec="seconds")
    expired = store.expired_photos(cutoff)
    if not dry_run:
        for photo in expired:
            delete_photo_files(config, photo)
            store.mark_deleted(photo["code"])
            logger.info("Photo expirée supprimée : %s", photo["code"])
    return [photo["code"] for photo in expired]


# --- Application ----------------------------------------------------------------------


def create_app(config: ServerConfig | None = None) -> Flask:
    """Fabrique de l'application (utilisée par « flask --app app », gunicorn et les tests)."""
    if not logging.getLogger().handlers:
        logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s : %(message)s")
    config = config or ServerConfig.from_env()
    app = Flask(__name__, root_path=str(BASE_DIR), template_folder="templates", static_folder="static")
    app.config["MAX_CONTENT_LENGTH"] = config.max_upload_mb * 1024 * 1024 + 256 * 1024
    app.json.ensure_ascii = False  # type: ignore[attr-defined]
    if config.behind_proxy:
        app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1)  # type: ignore[method-assign]

    store = PhotoStore(config.database_path)
    store.initialize()
    config.upload_dir.mkdir(parents=True, exist_ok=True)
    limiter = LookupLimiter(config.lookup_limit, config.lookup_window)
    app.extensions["photo_config"] = config
    app.extensions["photo_store"] = store
    if len(config.api_token) < MIN_TOKEN_LENGTH:
        logger.warning(
            "UPLOAD_API_TOKEN absent ou trop court (%d caractères minimum) : upload désactivé", MIN_TOKEN_LENGTH
        )

    def external_url(endpoint: str, **values: Any) -> str:
        if config.public_base_url:
            return config.public_base_url + url_for(endpoint, **values)
        return url_for(endpoint, _external=True, **values)

    def client_ip() -> str:
        return request.remote_addr or "?"

    def json_error(message: str, status: int) -> tuple[Response, int]:
        return jsonify({"ok": False, "error": message}), status

    def token_is_valid() -> bool:
        header = request.headers.get("Authorization", "")
        token = header[7:].strip() if header.lower().startswith("bearer ") else ""
        token = token or request.headers.get("X-API-Token", "").strip() or request.form.get("api_token", "").strip()
        return bool(token) and hmac.compare_digest(token.encode("utf-8"), config.api_token.encode("utf-8"))

    def find_photo(raw_code: str) -> tuple[str | None, dict[str, Any] | None, Response | None]:
        """Recherche limitée en débit ; renvoie (code, photo, réponse d'erreur éventuelle)."""
        ip = client_ip()
        if limiter.blocked(ip):
            return None, None, Response(render_template("error.html", status=429), status=429)
        code = normalize_code(raw_code)
        photo = store.get_photo(code) if code else None
        if photo is None or (not photo["deleted_at"] and not photo_file(config, photo).is_file()):
            limiter.miss(ip)
            return code, None, None
        return code, photo, None

    @app.context_processor
    def inject_globals() -> dict[str, Any]:
        return {
            "site_name": config.site_name,
            "retention_days": config.retention_days,
            "contact_email": config.contact_email,
        }

    @app.after_request
    def security_headers(response: Response) -> Response:
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("X-Frame-Options", "DENY")
        response.headers.setdefault("Referrer-Policy", "no-referrer")
        response.headers.setdefault("X-Robots-Tag", "noindex, nofollow, noarchive")
        response.headers.setdefault("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
        response.headers.setdefault("Content-Security-Policy", CONTENT_SECURITY_POLICY)
        response.headers.setdefault("Cache-Control", "no-store")
        return response

    @app.errorhandler(HTTPException)
    def http_error(error: HTTPException) -> Any:
        status = error.code or 500
        if request.path.startswith("/api/"):
            messages = {413: f"Fichier trop volumineux ({config.max_upload_mb} Mo maximum)."}
            return json_error(messages.get(status, error.description or error.name), status)
        return render_template("error.html", status=status), status

    @app.get("/")
    def index() -> str:
        return render_template("index.html")

    @app.get("/find")
    def find() -> Any:
        code = normalize_code(request.args.get("code"))
        if code is None:
            return render_template("index.html", error="Code invalide : il contient 12 lettres et chiffres."), 400
        return redirect(url_for("photo_page", raw_code=code))

    @app.get("/p/<raw_code>")
    def photo_page(raw_code: str) -> Any:
        canonical = normalize_code(raw_code)
        if canonical and canonical != raw_code:
            return redirect(url_for("photo_page", raw_code=canonical), 301)
        code, photo, error = find_photo(raw_code)
        if error is not None:
            return error
        if code is None:
            return render_template("pending.html", code=None, invalid=True), 404
        if photo is None:
            return render_template("pending.html", code=format_code(code), invalid=False), 404
        if photo["deleted_at"]:
            return render_template("expired.html", code=format_code(code)), 410
        event = store.get_event(photo["event_slug"]) or {}
        expires_on = None
        if config.retention_days > 0:
            uploaded = datetime.fromisoformat(photo["uploaded_at"])
            expires_on = (uploaded + timedelta(days=config.retention_days)).strftime("%d/%m/%Y")
        return render_template(
            "photo.html",
            photo=photo,
            event=event,
            display_code=format_code(code),
            image_url=url_for("media", raw_code=code),
            download_url=url_for("download", raw_code=code),
            og_image=external_url("media", raw_code=code),
            page_url=external_url("photo_page", raw_code=code),
            expires_on=expires_on,
        )

    def serve_photo(raw_code: str, as_attachment: bool) -> Any:
        code, photo, error = find_photo(raw_code)
        if error is not None:
            return error
        if code is None or photo is None or photo["deleted_at"]:
            abort(404)
        path = photo_file(config, photo)
        response = send_file(
            path,
            mimetype=photo["mime_type"],
            as_attachment=as_attachment,
            download_name=f"photo-{photo['event_slug']}-{code}{path.suffix}",
            max_age=3600,
        )
        response.headers["Cache-Control"] = "private, max-age=3600"
        return response

    @app.get("/media/<raw_code>")
    def media(raw_code: str) -> Any:
        return serve_photo(raw_code, as_attachment=False)

    @app.get("/download/<raw_code>")
    def download(raw_code: str) -> Any:
        return serve_photo(raw_code, as_attachment=True)

    @app.get("/g/<slug>/<secret>")
    def gallery(slug: str, secret: str) -> Any:
        event = store.get_event(slug) if SLUG_PATTERN.fullmatch(slug) else None
        token = (event or {}).get("gallery_token") or ""
        if not token or not hmac.compare_digest(secret.encode("utf-8"), token.encode("utf-8")):
            limiter.miss(client_ip())
            abort(404)
        photos = [{**photo, "display_code": format_code(photo["code"])} for photo in store.event_photos(slug)]
        return render_template("gallery.html", event=event, photos=photos, secret=secret)

    @app.get("/g/<slug>/<secret>/thumb/<raw_code>")
    def gallery_thumb(slug: str, secret: str, raw_code: str) -> Any:
        event = store.get_event(slug) if SLUG_PATTERN.fullmatch(slug) else None
        token = (event or {}).get("gallery_token") or ""
        code = normalize_code(raw_code)
        if not token or not code or not hmac.compare_digest(secret.encode("utf-8"), token.encode("utf-8")):
            abort(404)
        photo = store.get_photo(code)
        path = thumb_file(config, code)
        if photo is None or photo["event_slug"] != slug or photo["deleted_at"] or not path.is_file():
            abort(404)
        response = send_file(path, mimetype="image/jpeg", max_age=3600)
        response.headers["Cache-Control"] = "private, max-age=3600"
        return response

    @app.get("/api/health")
    def health() -> Response:
        return jsonify({"ok": True, "upload": len(config.api_token) >= MIN_TOKEN_LENGTH})

    @app.get("/robots.txt")
    def robots() -> Response:
        return Response("User-agent: *\nDisallow: /\n", mimetype="text/plain")

    @app.get("/favicon.ico")
    def favicon() -> Response:
        return Response(status=204)

    @app.post("/api/upload")
    def api_upload() -> Any:
        if len(config.api_token) < MIN_TOKEN_LENGTH:
            return json_error("Upload non configuré sur le serveur (UPLOAD_API_TOKEN).", 503)
        if not token_is_valid():
            logger.warning("Upload refusé : token invalide (%s)", client_ip())
            return json_error("Token invalide.", 401)
        code = normalize_code(request.form.get("photo_code"))
        if code is None:
            return json_error("photo_code invalide.", 400)
        slug = (request.form.get("event") or "").strip().lower()
        if not SLUG_PATTERN.fullmatch(slug):
            return json_error("Identifiant d'événement invalide.", 400)
        upload = request.files.get("photo")
        if upload is None or not upload.filename:
            return json_error("Fichier « photo » manquant.", 400)
        if Path(upload.filename).suffix.lower() not in ALLOWED_EXTENSIONS:
            return json_error("Extension non autorisée : JPEG ou PNG uniquement.", 415)
        data = upload.read()
        if not data:
            return json_error("Fichier vide.", 400)
        try:
            image_format, width, height = inspect_image(data)
            thumbnail = make_thumbnail(data)  # décodage complet : refuse aussi les images tronquées
        except ValueError as exc:
            return json_error(str(exc), 415)
        except (OSError, SyntaxError):
            return json_error("Le fichier n'est pas une image JPEG ou PNG valide.", 415)

        extension = FORMAT_EXTENSIONS[image_format]
        target = safe_child(config.upload_dir, f"{slug}/{code}{extension}")
        previous = store.get_photo(code)
        write_atomic(target, data)
        write_atomic(thumb_file(config, code), thumbnail)
        relative = target.relative_to(config.upload_dir.resolve()).as_posix()
        if previous and previous["filename"] != relative:
            photo_file(config, previous).unlink(missing_ok=True)

        store.upsert_event(
            slug, clean_text(request.form.get("event_name"), 120) or slug, parse_date(request.form.get("event_date"))
        )
        store.upsert_photo(
            {
                "code": code,
                "event_slug": slug,
                "filename": relative,
                "mime_type": MIME_TYPES[extension],
                "size": len(data),
                "width": width,
                "height": height,
                "taken_at": parse_datetime(request.form.get("date")),
                "uploaded_at": now_utc(),
            }
        )
        logger.info("Photo reçue : %s (%s, %d octets)", code, slug, len(data))
        return jsonify({"ok": True, "code": code, "url": external_url("photo_page", raw_code=code)}), 201

    register_commands(app, config, store, external_url)
    return app


# --- Commandes ----------------------------------------------------------------------------


def register_commands(app: Flask, config: ServerConfig, store: PhotoStore, external_url: Any) -> None:
    @app.cli.command("cleanup")
    @click.option("--days", type=int, default=None, help="Durée de conservation (défaut : PHOTO_RETENTION_DAYS).")
    @click.option("--dry-run", is_flag=True, help="Affiche les photos concernées sans les supprimer.")
    def cleanup_command(days: int | None, dry_run: bool) -> None:
        """Supprime les photos trop anciennes (à lancer chaque nuit avec cron)."""
        retention = config.retention_days if days is None else days
        codes = cleanup_expired(store, config, retention, dry_run=dry_run)
        verb = "seraient supprimées" if dry_run else "supprimées"
        click.echo(f"{len(codes)} photo(s) de plus de {retention} jour(s) {verb}.")

    @app.cli.command("gallery-enable")
    @click.argument("slug")
    def gallery_enable(slug: str) -> None:
        """Crée (ou renouvelle) le lien secret de la galerie d'un événement."""
        token = secrets.token_urlsafe(18)
        if not store.set_gallery_token(slug, token):
            raise click.ClickException(f"Événement inconnu : {slug}")
        with app.test_request_context():
            click.echo(f"Galerie activée : {external_url('gallery', slug=slug, secret=token)}")

    @app.cli.command("gallery-disable")
    @click.argument("slug")
    def gallery_disable(slug: str) -> None:
        """Désactive la galerie d'un événement (le lien ne fonctionne plus)."""
        if not store.set_gallery_token(slug, None):
            raise click.ClickException(f"Événement inconnu : {slug}")
        click.echo("Galerie désactivée.")

    @app.cli.command("delete-photo")
    @click.argument("code")
    def delete_photo(code: str) -> None:
        """Supprime une photo à la demande (droit à l'effacement)."""
        normalized = normalize_code(code)
        photo = store.get_photo(normalized) if normalized else None
        if photo is None:
            raise click.ClickException("Photo introuvable.")
        delete_photo_files(config, photo)
        store.mark_deleted(photo["code"])
        click.echo(f"Photo {format_code(photo['code'])} supprimée.")

    @app.cli.command("stats")
    def stats() -> None:
        """Photos en ligne par événement."""
        for row in store.stats():
            gallery = "galerie active" if row["gallery"] else "sans galerie"
            size_mb = (row["bytes"] or 0) / 1024 / 1024
            click.echo(
                f"{row['event_date'] or '????-??-??'}  {row['slug']:<30} {row['online'] or 0} en ligne / "
                f"{row['total']} reçue(s), {size_mb:.1f} Mo, {gallery}"
            )

    @app.cli.command("generate-token")
    def generate_token() -> None:
        """Génère un token aléatoire à copier dans UPLOAD_API_TOKEN (serveur et borne)."""
        click.echo(secrets.token_urlsafe(32))


if __name__ == "__main__":
    create_app().run(host="127.0.0.1", port=int(os.environ.get("PORT", "8000")), debug=False)
