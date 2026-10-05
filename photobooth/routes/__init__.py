"""Routes HTTP : interface de la borne (kiosk) et administration."""

from __future__ import annotations

from flask import Flask


def register_blueprints(app: Flask) -> None:
    from routes.admin import bp as admin_bp
    from routes.kiosk import bp as kiosk_bp

    app.register_blueprint(kiosk_bp)
    app.register_blueprint(admin_bp)
