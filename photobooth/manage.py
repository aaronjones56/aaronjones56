"""Commandes d'administration en ligne de commande.

python manage.py check                        état de la caméra, de l'imprimante, de la base…
python manage.py upload [--all]               envoie les photos en attente (événement actif ou tous)
python manage.py printers                     liste les imprimantes Windows
python manage.py events                       liste les événements
python manage.py create-event "Festi'Coat 2027" --date 2027-07-05 --activate
python manage.py activate-event festicoat-2027
python manage.py test-camera                  prend une photo de test
python manage.py test-print                   imprime une mire de test
python manage.py generate-assets [--force]    régénère la photo de test et les cadres d'exemple
"""

from __future__ import annotations

import argparse
import sys
from collections.abc import Callable

from config import load_config
from services.container import Services, build_services
from services.errors import PhotoboothError
from services.logging_setup import setup_logging
from services.photo_repository import PhotoRecord
from services.upload_service import UploadProgress


def cmd_check(services: Services, _args: argparse.Namespace) -> int:
    checks = {
        "Caméra": services.camera.check(),
        "Imprimante": services.printer.check(),
        "Base de données": services.db.check(),
        "Stockage": services.storage.check(),
    }
    for label, status in checks.items():
        state = {"ok": "OK", "warning": "ATTENTION", "error": "ERREUR"}[status.state]
        print(f"{label:<16} {state:<10} {status.message}")
    frames = services.frames.scan()
    print(f"{'Cadres':<16} {len(frames):<10} {', '.join(frame.id for frame in frames)}")
    for error in services.frames.errors:
        print(f"{'':<16} {'ERREUR':<10} {error}")
    event = services.events.active_event()
    print(f"{'Événement actif':<16} {event.name} ({event.slug}, {event.display_date})")
    return 0 if all(status.ok for status in checks.values()) else 1


def cmd_upload(services: Services, args: argparse.Namespace) -> int:
    problem = services.uploader.configuration_problem()
    if problem:
        print(f"ERREUR : {problem}")
        return 1
    event_id = None if args.all else services.events.active_event().id

    def report(progress: UploadProgress, record: PhotoRecord | None, error: str | None) -> None:
        code = record.code if record else "?"
        result = f"ERREUR : {error}" if error else "OK"
        print(f"[{progress.done}/{progress.total}] {code} {result}", flush=True)

    progress = services.uploader.upload_pending(event_id, on_progress=report)
    print(progress.message)
    return 0 if progress.failed == 0 else 1


def cmd_printers(services: Services, _args: argparse.Namespace) -> int:
    printers = services.printer.list_printers()
    if not printers:
        print("Aucune imprimante détectée.")
        return 1
    for info in printers:
        markers = []
        if info.is_default:
            markers.append("par défaut")
        if info.name == services.printer.printer_name:
            markers.append("sélectionnée")
        print(f"- {info.name}" + (f"  ({', '.join(markers)})" if markers else ""))
    return 0


def cmd_events(services: Services, _args: argparse.Namespace) -> int:
    active = services.events.active_event()
    for event in services.events.list_events():
        stats = services.events.stats(event)
        marker = "*" if event.id == active.id else " "
        print(
            f"{marker} {event.display_date}  {event.slug:<30} {event.name:<30} "
            f"{stats['photos']} photo(s), {stats['pending']} à envoyer, {stats['disk_human']}"
        )
    print("* = événement actif")
    return 0


def cmd_create_event(services: Services, args: argparse.Namespace) -> int:
    event = services.events.create(args.name, args.date, args.slug)
    print(f"Événement créé : {event.name} ({event.slug}) -> data/events/{event.folder}")
    if args.activate:
        services.events.set_active(event.id)
        print("Il est maintenant l'événement actif.")
    return 0


def cmd_activate_event(services: Services, args: argparse.Namespace) -> int:
    event = services.events.get_by_slug(args.slug)
    if event is None:
        print(f"ERREUR : aucun événement « {args.slug} ».")
        return 1
    services.events.set_active(event.id)
    print(f"Événement actif : {event.name}")
    return 0


def cmd_test_camera(services: Services, _args: argparse.Namespace) -> int:
    path = services.photos.test_camera()
    print(f"Photo de test enregistrée : {path}")
    return 0


def cmd_test_print(services: Services, _args: argparse.Namespace) -> int:
    path = services.photos.test_printer()
    print(f"Mire envoyée à l'imprimante : {path}")
    return 0


COMMANDS: dict[str, Callable[[Services, argparse.Namespace], int]] = {
    "check": cmd_check,
    "upload": cmd_upload,
    "printers": cmd_printers,
    "events": cmd_events,
    "create-event": cmd_create_event,
    "activate-event": cmd_activate_event,
    "test-camera": cmd_test_camera,
    "test-print": cmd_test_print,
}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Administration du photobooth en ligne de commande.")
    commands = parser.add_subparsers(dest="command", required=True, metavar="commande")
    commands.add_parser("check", help="vérifie la caméra, l'imprimante, la base et le stockage")
    upload = commands.add_parser("upload", help="envoie les photos en attente vers le serveur")
    upload.add_argument("--all", action="store_true", help="tous les événements (sinon l'événement actif)")
    commands.add_parser("printers", help="liste les imprimantes")
    commands.add_parser("events", help="liste les événements")
    create = commands.add_parser("create-event", help="crée un événement")
    create.add_argument("name", help='nom affiché, par exemple "Festi\'Coat 2027"')
    create.add_argument("--date", help="date AAAA-MM-JJ (défaut : aujourd'hui)")
    create.add_argument("--slug", help="identifiant (défaut : calculé depuis le nom)")
    create.add_argument("--activate", action="store_true", help="en faire l'événement actif")
    activate = commands.add_parser("activate-event", help="change l'événement actif")
    activate.add_argument("slug")
    commands.add_parser("test-camera", help="prend une photo de test")
    commands.add_parser("test-print", help="imprime une mire de test")
    assets = commands.add_parser("generate-assets", help="génère la photo de test et les cadres d'exemple")
    assets.add_argument("--force", action="store_true", help="remplace les fichiers existants")
    return parser


def main(argv: list[str] | None = None) -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(errors="replace")
    args = build_parser().parse_args(argv)
    config = load_config()
    setup_logging(config.log_dir, config.log_level)

    if args.command == "generate-assets":
        from services.assets import generate_all

        result = generate_all(config.frames_dir, config.test_photo, force=args.force)
        print(f"Photo de test : {'créée' if result['test_photo'] else 'déjà présente'} ({config.test_photo})")
        print(f"Cadres créés : {', '.join(result['frames']) or 'aucun (déjà présents, utilisez --force)'}")
        return 0

    services = build_services(config)
    try:
        return COMMANDS[args.command](services, args)
    except PhotoboothError as exc:
        print(f"ERREUR : {exc.message}")
        return 1
    finally:
        services.close()


if __name__ == "__main__":
    sys.exit(main())
