# 📸 Photobooth : borne photo professionnelle faite maison

Logiciel complet pour une borne photo : un mini-PC Windows, un écran tactile, un appareil photo (webcam ou
reflex Canon/Nikon), une imprimante photo (Canon SELPHY CP1500) et un site web où chaque invité retrouve sa photo
grâce à un QR code.

**Tout fonctionne hors ligne pendant l'événement.** Les photos sont envoyées sur votre site après coup, en un clic.

| Borne (écran tactile) | Administration (`/admin`) | Site des invités (mobile) |
|---|---|---|
| Accueil, choix du cadre, aperçu en direct, compte à rebours 3-2-1, flash, photo finale avec code et QR code, impression | Tableau de bord, événements, photos, upload, imprimante, cadres, réglages | « Votre photo 📸 », bouton TÉLÉCHARGER, page « pas encore disponible », galerie privée facultative |

---

## Sommaire

1. [Fonctionnalités](#fonctionnalités)
2. [Architecture du projet](#architecture-du-projet)
3. [Installation sous Windows](#installation-sous-windows)
4. [Premier test sans matériel](#premier-test-sans-matériel)
5. [Utilisation](#utilisation)
6. [Configuration (.env)](#configuration-env)
7. [Appareil photo : webcam ou reflex](#appareil-photo--webcam-ou-reflex)
8. [Imprimante (Canon SELPHY CP1500)](#imprimante-canon-selphy-cp1500)
9. [Cadres personnalisés](#cadres-personnalisés)
10. [Mode photomaton (bande de 3 photos)](#mode-photomaton-bande-de-3-photos)
11. [Mode kiosk et lancement au démarrage](#mode-kiosk-et-lancement-au-démarrage)
12. [Upload des photos après l'événement](#upload-des-photos-après-lévénement)
13. [Serveur web des photos](#serveur-web-des-photos)
14. [Sécurité et confidentialité](#sécurité-et-confidentialité)
15. [Tests automatiques](#tests-automatiques)
16. [Commandes utiles](#commandes-utiles)
17. [Dépannage](#dépannage)
18. [Aller plus loin](#aller-plus-loin)

---

## Fonctionnalités

**Borne**
- Interface plein écran tactile (machine à états : démarrage, accueil, cadre, aperçu, compte à rebours, résultat),
  grandes zones tactiles, animations légères, adaptée aux écrans de 10 à 15 pouces en paysage comme en portrait.
- Écran de démarrage qui vérifie la caméra, l'imprimante, la base de données et le stockage.
- Cadres détectés automatiquement dans `static/frames/` : ajoutez un dossier, c'est tout.
- Aperçu caméra en direct avec le cadre par-dessus, recadré **exactement** comme la photo finale.
- Compte à rebours 3, 2, 1, « SOURIEZ ! », flash blanc et sons (générés, aucun fichier audio).
- Mode **photomaton** : plusieurs photos à la suite dans un même cadre (bande de 3 photos fournie).
- Photo finale 1200 x 1800 px (10 x 15 cm à 300 dpi), recadrage 2:3 centré sans déformation, orientation EXIF
  respectée, JPEG qualité 95 ; l'original est toujours conservé.
- Code unique non prévisible (12 caractères, 2^60 possibilités) et QR code généré hors ligne.
- Impression (validation par l'invité, ou automatique), copies, limite par photo, QR code sur le tirage en option.
- Retour automatique à l'accueil après inactivité ; reconnexion automatique si le serveur redémarre.
- Accès administrateur caché (5 touches dans le coin) et raccourcis clavier ; un gros bouton USB peut déclencher la photo.

**Administration** (protégée par code PIN) : état du matériel et d'Internet, statistiques, création et choix de
l'événement, galerie des photos (impression, téléchargement, suppression), upload avec barre de progression, choix
de l'imprimante Windows, test caméra et imprimante, réglages modifiables à chaud, téléchargement des journaux,
redémarrage et fermeture du kiosk.

**Fiabilité** : aucune erreur matérielle ne ferme l'application, journaux avec rotation, écritures de fichiers
atomiques, base SQLite en mode WAL, redémarrage automatique du serveur en cas de plantage.

**Serveur web** (`upload_server/`) : API d'upload protégée par token, page mobile par photo, téléchargement, aucune
galerie publique, galerie privée par événement en option, suppression automatique après 30 jours, protection contre
la recherche de codes au hasard.

---

## Architecture du projet

```
photobooth/
├── app.py                     Application Flask et serveur local (waitress)
├── config.py                  Lecture et validation du fichier .env
├── manage.py                  Commandes en ligne (upload, check, imprimantes, événements…)
├── requirements.txt
├── .env.example               Modèle de configuration (à copier en .env)
├── pytest.ini
│
├── services/                  Logique métier, indépendante de Flask
│   ├── camera.py              CameraProvider + MockCamera, WebcamCamera, ExternalCommandCamera
│   ├── printer.py             PrinterProvider + NullPrinter, WindowsPrinter (pywin32)
│   ├── compositor.py          Recadrage 2:3, cadre PNG, badge QR code, vignettes
│   ├── qr_service.py          QR codes (lien PUBLIC_PHOTO_URL/p/CODE)
│   ├── frames.py              Détection des cadres et lecture de config.json
│   ├── photo_service.py       Session photo : capture, montage, enregistrement, impression
│   ├── photo_repository.py    Requêtes SQL sur les photos et les sessions
│   ├── event_service.py       Événements et statistiques
│   ├── settings_service.py    Réglages modifiables depuis l'administration
│   ├── storage.py             Dossiers data/events/<date>-<slug>/…
│   ├── upload_service.py      Envoi des photos vers le serveur web
│   ├── system_service.py      Internet, redémarrage, fermeture du kiosk, journaux
│   ├── assets.py              Génération de la photo de test, des cadres d'exemple et de la mire
│   ├── database.py            Schéma SQLite et connexions
│   ├── codes.py               Codes photo
│   ├── container.py           Assemblage des services
│   └── …                      errors.py, devices.py, fonts.py, logging_setup.py, utils.py
│
├── routes/
│   ├── kiosk.py               Page de la borne et API /api/…
│   ├── admin.py               Administration /admin et API /api/admin/…
│   └── helpers.py
│
├── templates/                 kiosk.html, admin.html
├── static/
│   ├── css/                   kiosk.css, admin.css
│   ├── js/                    kiosk.js (machine à états), admin.js
│   ├── frames/                cadre1, cadre2, cadre3, photomaton (frame.png, preview.jpg, config.json)
│   └── assets/test_photo.jpg  Photo utilisée par la caméra simulée
│
├── database/photobooth.db     Créée au premier démarrage
├── data/                      Photos (créé automatiquement)
│   ├── events/2027-07-05-festicoat-2027/
│   │   ├── originals/  A7K4Q92XB3LM.jpg      photo d'origine (CODE-1.jpg, CODE-2.jpg… pour une bande)
│   │   ├── finals/     A7K4Q92XB3LM.jpg      photo finale 1200 x 1800 avec le cadre
│   │   ├── qr/         A7K4Q92XB3LM.png      QR code
│   │   ├── thumbs/     A7K4Q92XB3LM.jpg      vignette (administration)
│   │   └── prints/     A7K4Q92XB3LM.jpg      version imprimée avec QR code (si QR_ON_PRINT)
│   ├── cache/  tests/
├── logs/photobooth.log        Journaux (rotation : 10 fichiers de 2 Mo)
│
├── scripts/
│   ├── install.bat            Installation complète
│   ├── start_kiosk.bat        Serveur + navigateur plein écran
│   ├── run_server.bat         Serveur avec redémarrage automatique
│   ├── stop_kiosk.bat         Arrêt du navigateur et du serveur
│   ├── upload_pending.bat     Upload des photos en attente
│   ├── install_autostart.bat  Lancement automatique à l'ouverture de session
│   └── remove_autostart.bat
│
├── tests/                     Tests pytest (codes, montage, QR, SQLite, cadres, API, upload, serveur)
│
└── upload_server/             Site web des photos (à héberger sur Internet)
    ├── app.py                 API d'upload, pages /p/<code>, galerie privée, commandes de maintenance
    ├── wsgi.py                Point d'entrée gunicorn
    ├── requirements.txt
    ├── .env.example
    ├── templates/             base, index, photo, pending, expired, gallery, error
    ├── static/css/site.css
    ├── data/photos.db         Index des photos (créé automatiquement)
    └── uploads/               Photos reçues (jamais servies directement)
```

---

## Installation sous Windows

### Prérequis

1. **Python 3.12 ou plus récent** : <https://www.python.org/downloads/>. Pendant l'installation, cochez
   **« Add python.exe to PATH »**.
2. Le dossier `photobooth` sur le PC, par exemple dans `C:\photobooth` (téléchargement ZIP ou `git clone`).
3. Chrome ou Edge (Edge est déjà installé sur Windows 10/11).

### Installation automatique

Double-cliquez sur `scripts\install.bat`. Le script crée l'environnement Python, installe les dépendances,
copie `.env.example` en `.env` et vérifie le matériel.

### Installation manuelle (commandes exactes)

Dans une invite de commandes (`cmd`) :

```bat
cd C:\photobooth
python -m venv venv
venv\Scripts\activate
pip install -r requirements.txt
copy .env.example .env
python app.py
```

Ouvrez ensuite :

- la borne : <http://127.0.0.1:5000>
- l'administration : <http://127.0.0.1:5000/admin> (code PIN par défaut : `1234`, à changer dans `.env`)

Arrêt du serveur : `Ctrl + C` dans la fenêtre de commandes.

> Sous Linux ou macOS (développement) : `python3 -m venv venv`, `source venv/bin/activate`, puis les mêmes commandes
> (`cp .env.example .env`). L'impression Windows n'y est pas disponible, la simulation fonctionne.

---

## Premier test sans matériel

La configuration par défaut permet de tout tester **sans appareil photo, sans imprimante et sans site Internet** :

```ini
CAMERA_MODE=mock
PRINTER_MODE=null
UPLOAD_ENABLED=false
```

- La caméra simulée utilise `static/assets/test_photo.jpg` (fournie). Pour tester avec une vraie photo, remplacez ce
  fichier par n'importe quel JPEG (idéalement en 3:2, comme un reflex). S'il est supprimé, une photo de test est
  régénérée automatiquement.
- L'imprimante simulée attend 1,5 seconde puis écrit l'impression dans les journaux.
- Toutes les photos sont enregistrées dans `data/events/<date>-<événement>/` et la base `database/photobooth.db`.

---

## Utilisation

### Parcours d'un invité

1. **Accueil** : « PHOTOBOOTH, Toucher pour commencer », bouton COMMENCER (tout l'écran est tactile).
2. **Choix du cadre** : tous les cadres de `static/frames/` ; le cadre touché est mis en avant, puis CONTINUER.
   (S'il n'y a qu'un seul cadre, cette étape est sautée.)
3. **Aperçu** : la caméra en direct avec le cadre par-dessus ; RETOUR ou PRENDRE LA PHOTO.
4. **Compte à rebours** : 3, 2, 1, SOURIEZ !, flash blanc.
5. **Résultat** : « Votre photo est prête ! », la photo, le code (`A7K4-Q92X-B3LM`), le QR code, le message
   « Les photos seront disponibles après l'événement. » et les boutons RECOMMENCER, IMPRIMER, TERMINER.
6. Sans interaction pendant `SESSION_TIMEOUT` secondes (45 par défaut), la borne revient à l'accueil
   (un compte à rebours s'affiche dans les 10 dernières secondes).

### Administration

Accessible sur <http://127.0.0.1:5000/admin> avec le code PIN (5 erreurs = blocage d'une minute) :

| Onglet | Contenu |
|---|---|
| Tableau de bord | Caméra, imprimante, stockage, Internet ; sessions, photos, imprimées, uploadées, à uploader, espace disque ; boutons Tester caméra, Tester imprimante, Changer d'imprimante, Changer d'événement, Uploader maintenant, Voir les photos, Télécharger les journaux, Redémarrer, Quitter le kiosk |
| Événements | Créer un événement (nom, date, identifiant), choisir l'événement actif, statistiques par événement |
| Photos | Toutes les photos d'un événement ; détail avec QR code, impression, téléchargement de la photo et de l'original, suppression |
| Upload | Configuration, photos en attente, bouton UPLOAD TOUTES LES PHOTOS EN ATTENTE, barre de progression, erreurs |
| Imprimante | Imprimantes Windows détectées, choix, page de test |
| Cadres | Cadres détectés, erreurs de configuration, rechargement |
| Réglages | Impression automatique, QR code sur le tirage, copies, délai de retour à l'accueil, compte à rebours, miroir, sons |

### Raccourcis sur la borne

| Action | Comment |
|---|---|
| Menu administrateur (PIN) | 5 touches rapides dans le coin en haut à gauche de l'écran |
| Administration | `Ctrl` + `Alt` + `A` |
| Quitter le kiosk (PIN) | `Ctrl` + `Alt` + `Q` : ferme le navigateur et arrête le serveur |
| Déclencher la photo | `Entrée` ou `Espace` (compatible avec un gros bouton USB qui simule une touche) |
| Dernier recours | `Alt` + `F4` ferme le navigateur ; `scripts\stop_kiosk.bat` arrête tout |

---

## Configuration (.env)

Copiez `.env.example` en `.env`. Chaque valeur invalide est remplacée par sa valeur par défaut et signalée dans
les journaux : l'application démarre toujours. Les principales variables :

| Variable | Défaut | Rôle |
|---|---|---|
| `ADMIN_PIN` | `1234` | Code de l'administration (4 à 12 chiffres) |
| `FLASK_SECRET_KEY` | vide | Vide = clé aléatoire conservée dans `data/.secret_key` |
| `CAMERA_MODE` | `mock` | `mock`, `webcam` ou `external` |
| `CAMERA_DEVICE` | `0` | Numéro de la webcam |
| `CAMERA_CAPTURE_COMMAND` | vide | Commande du mode `external` (`{output}` = fichier à créer) |
| `CAMERA_WATCH_DIR` | vide | Dossier où l'appareil dépose ses photos (mode `external`) |
| `CAMERA_PREVIEW_URL` | vide | Image d'aperçu en direct d'un reflex (mode `external`) |
| `PREVIEW_MIRROR` | `true` | Aperçu en miroir (la photo finale n'est jamais inversée) |
| `PRINTER_MODE` | `null` | `null` (simulation) ou `windows` |
| `PRINTER_NAME` | vide | Imprimante Windows (vide = imprimante par défaut ; modifiable dans l'admin) |
| `AUTO_PRINT` | `false` | Impression automatique sans validation de l'invité |
| `PRINT_MAX_COPIES` | `2` | Copies maximum par impression (1 = pas de choix) |
| `PRINT_LIMIT_PER_PHOTO` | `0` | Impressions maximum par photo (0 = illimité) |
| `PRINT_FIT_MODE` | `fill` | `fill` bord à bord, `fit` image entière |
| `EVENT_NAME`, `EVENT_SLUG`, `EVENT_DATE` | `Photobooth Test` | Premier événement, créé au premier démarrage |
| `PUBLIC_PHOTO_URL` | `https://photos.example.com` | Adresse de votre site : les QR codes pointent vers `…/p/CODE` |
| `UPLOAD_ENABLED` | `false` | Active l'upload |
| `UPLOAD_API_URL` | `https://photos.example.com/api/upload` | API du serveur web |
| `UPLOAD_API_TOKEN` | vide | Token partagé avec le serveur |
| `PHOTO_RETENTION_DAYS` | `30` | Durée de conservation en ligne |
| `SESSION_TIMEOUT` | `45` | Retour automatique à l'accueil (secondes) |
| `COUNTDOWN_SECONDS` | `3` | Durée du compte à rebours |
| `OUTPUT_WIDTH`, `OUTPUT_HEIGHT` | `1200`, `1800` | Taille de la photo finale |
| `QR_ON_PRINT` | `false` | QR code et code imprimés sur le tirage |
| `KIOSK_TITLE`, `ACCENT_COLOR` | `PHOTOBOOTH`, `#ff3d7f` | Titre et couleur de l'interface |
| `PORT` | `5000` | Port du serveur local |

`.env.example` documente toutes les variables (backend webcam, cadrage, qualité JPEG, dossiers, journaux…).
Les réglages de l'onglet **Réglages** de l'administration remplacent ceux du `.env` sans redémarrage.

> ⚠️ **Réglez `PUBLIC_PHOTO_URL` avant l'événement** : l'adresse est inscrite dans chaque QR code imprimé ou affiché.

---

## Appareil photo : webcam ou reflex

L'appareil photo est une abstraction (`CameraProvider` dans `services/camera.py`) : la borne ne sait pas quel
matériel elle utilise. Trois modes sont fournis.

### Webcam

```ini
CAMERA_MODE=webcam
CAMERA_DEVICE=0
CAMERA_WIDTH=1920
CAMERA_HEIGHT=1080
```

Redémarrez l'application, puis **Administration › Tester la caméra**. `CAMERA_DEVICE=1` ou `2` si le PC a plusieurs
caméras. La webcam est libérée automatiquement après 2 minutes sans utilisation.

### Reflex Canon / Nikon / Sony (mode `external`)

La borne lance une commande Windows qui déclenche l'appareil et enregistre la photo dans le fichier `{output}`.
N'importe quel logiciel en ligne de commande convient : **aucune modification du programme n'est nécessaire**.

Variables remplacées dans la commande : `{output}` (chemin complet du JPEG attendu), `{output_dir}`, `{filename}`,
`{stem}`.

**Exemple avec digiCamControl** (gratuit, Windows, compatible avec de nombreux boîtiers Canon, Nikon et Sony) :

1. Installez digiCamControl, branchez l'appareil en USB (mode manuel, mise en veille désactivée) et vérifiez
   qu'il déclenche depuis digiCamControl.
2. Dans `.env` (notez les apostrophes autour de toute la valeur, car elle commence par un chemin entre guillemets) :

   ```ini
   CAMERA_MODE=external
   CAMERA_CAPTURE_COMMAND='"C:\Program Files (x86)\digiCamControl\CameraControlCmd.exe" /filename "{output}" /capture'
   CAMERA_CAPTURE_TIMEOUT=30
   ```

3. Redémarrez puis **Tester la caméra**. Vérifiez la syntaxe exacte dans la documentation de votre version de
   digiCamControl si besoin.

**Aperçu en direct d'un reflex** : si votre logiciel publie une image d'aperçu sur une adresse HTTP (par exemple le
serveur web de digiCamControl, réglages *Webserver*, avec l'aperçu en direct démarré), indiquez-la :

```ini
CAMERA_PREVIEW_URL=http://127.0.0.1:5513/liveview.jpg
```

Sans aperçu, la borne affiche « Regardez l'appareil photo » avec le cadre.

**Logiciel qui ne sait pas choisir le nom du fichier** (dossier de sortie fixe, appareil Wi-Fi/FTP, EOS Utility…) :
indiquez le dossier surveillé, la photo la plus récente y sera récupérée après la commande.

```ini
CAMERA_WATCH_DIR=C:\Users\Photobooth\Pictures\digiCamControl\Session1
```

**Linux (gPhoto2)** :

```ini
CAMERA_CAPTURE_COMMAND=gphoto2 --capture-image-and-download --filename "{output}" --force-overwrite
```

Conseils : montez l'appareil **à la verticale** pour utiliser tout le capteur en portrait 2:3 ; utilisez un
adaptateur secteur (batterie factice) et désactivez la mise en veille de l'appareil.

### Cadrage

La photo est recadrée au ratio du cadre (2:3 par défaut) puis redimensionnée, **jamais déformée**. Le cadrage est
centré ; `CROP_FOCUS_Y=0.4` garde un peu plus le haut de l'image. L'aperçu utilise exactement le même calcul.

---

## Imprimante (Canon SELPHY CP1500)

L'impression passe par une abstraction `PrinterProvider` (`services/printer.py`) : `NullPrinter` (simulation) et
`WindowsPrinter` (pywin32, n'importe quelle imprimante installée sous Windows).

1. Installez le pilote Canon de la SELPHY CP1500 et branchez-la (USB recommandé pour la fiabilité, ou Wi-Fi).
   Faites une impression de test depuis Windows.
2. Dans **Paramètres › Bluetooth et appareils › Imprimantes › SELPHY CP1500 › Préférences d'impression** :
   papier **Carte postale (100 x 148 mm)**, orientation **Portrait**, **sans bordure**.
3. Dans `.env` : `PRINTER_MODE=windows`, puis redémarrez l'application.
4. **Administration › Imprimante** : choisissez la SELPHY, **Utiliser cette imprimante**, puis
   **Imprimer une page de test** (une mire avec un cadre rose qui doit être visible sur les quatre bords).

| Réglage | Effet |
|---|---|
| `PRINT_FIT_MODE=fill` | Bord à bord : l'image couvre toute la feuille (léger rognage possible : gardez une marge de 40 px dans vos cadres) |
| `PRINT_FIT_MODE=fit` | Image entière, marges blanches possibles |
| `AUTO_PRINT=true` | Impression automatique de chaque photo (sinon jamais sans le bouton IMPRIMER) |
| `PRINT_MAX_COPIES=2` | L'invité choisit 1 ou 2 tirages |
| `PRINT_LIMIT_PER_PHOTO=2` | Au plus 2 tirages par photo (0 = illimité) |
| `QR_ON_PRINT=true` | QR code et code ajoutés sur le tirage (la photo en ligne reste sans QR code) |

Les erreurs (imprimante absente, hors ligne, plus de papier, plus d'encre, en pause…) sont détectées avant
l'impression et affichées proprement à l'invité ; la borne continue de fonctionner.

---

## Cadres personnalisés

Chaque sous-dossier de `static/frames/` est un cadre, **détecté automatiquement** (au démarrage et à chaque
nouveau client) : créez un dossier, aucune ligne de code à modifier. 3, 5, 10 cadres ou plus : l'écran de choix
défile automatiquement.

```
static/frames/festicoat/
├── frame.png      calque PNG transparent, 1200 x 1800 px (obligatoire sauf cadre « sans calque »)
├── preview.jpg    vignette affichée sur la borne (facultatif : générée automatiquement sinon)
└── config.json    réglages (facultatif)
```

**Créer `frame.png`** (Canva, Photoshop, GIMP, Affinity…) : document de **1200 x 1800 pixels**, décor et textes sur
les bords, zone de la photo **transparente** (gomme ou masque), export **PNG avec transparence**. Évitez de placer
du texte à moins de 40 px des bords (rognage possible à l'impression bord à bord).

**`config.json`** (toutes les clés sont facultatives) :

```json
{
    "name": "Festi'Coat",
    "enabled": true,
    "order": 10,
    "orientation": "portrait",
    "width": 1200,
    "height": 1800,
    "photo_slots": [{"x": 60, "y": 60, "width": 1080, "height": 1440}],
    "qr": {"size": 200, "x": 940, "y": 1560}
}
```

| Clé | Rôle |
|---|---|
| `name` | Nom affiché (sinon le nom du dossier : `cadre1` devient « Cadre 1 ») |
| `enabled` | `false` pour masquer le cadre sans le supprimer |
| `order` | Ordre d'affichage (plus petit = en premier) |
| `width`, `height` | Taille du montage (sinon taille de `frame.png`, sinon `OUTPUT_WIDTH` x `OUTPUT_HEIGHT`) ; `1800 x 1200` pour un cadre paysage |
| `photo_slots` | Emplacements des photos en pixels. Absent : la photo occupe toute l'image, sous le PNG |
| `qr` | Position du QR code sur le tirage : `{"size", "x", "y"}` ou `{"size", "position": "bottom-left"}` |

Le nom du dossier ne doit contenir que des lettres, chiffres, `-` et `_`. Une erreur dans `config.json` n'empêche
pas la borne de fonctionner : le cadre est ignoré et l'erreur est affichée dans **Administration › Cadres**.

Quatre cadres d'exemple sont fournis (`cadre1` classique, `cadre2` festif, `cadre3` élégant, `photomaton`).
Pour les régénérer : `python manage.py generate-assets --force`.

---

## Mode photomaton (bande de 3 photos)

Le mode photomaton est intégré : un cadre avec plusieurs emplacements déclenche plusieurs photos à la suite, avec
un compte à rebours avant chacune (« Photo 1 / 3 », « Changez de pose ! »), puis assemble la bande.

`shot` indique quelle photo va dans quel emplacement : le cadre `photomaton` fourni imprime **deux bandes
identiques** côte à côte (à découper) avec 6 emplacements pour 3 photos :

```json
"photo_slots": [
    {"x": 40,  "y": 40,   "width": 520, "height": 484, "shot": 1},
    {"x": 40,  "y": 548,  "width": 520, "height": 484, "shot": 2},
    {"x": 40,  "y": 1056, "width": 520, "height": 484, "shot": 3},
    {"x": 640, "y": 40,   "width": 520, "height": 484, "shot": 1},
    {"x": 640, "y": 548,  "width": 520, "height": 484, "shot": 2},
    {"x": 640, "y": 1056, "width": 520, "height": 484, "shot": 3}
]
```

Sans `shot`, les emplacements sont numérotés dans l'ordre (1, 2, 3…). Jusqu'à 6 photos par cadre. Les originaux
sont conservés (`originals/CODE-1.jpg`, `CODE-2.jpg`, `CODE-3.jpg`).

---

## Mode kiosk et lancement au démarrage

### Lancer la borne

Double-cliquez sur **`scripts\start_kiosk.bat`** :

1. le serveur démarre dans une fenêtre réduite (`run_server.bat`), avec **redémarrage automatique** s'il s'arrête
   (et lors du bouton « Redémarrer » de l'administration) ;
2. le script attend que le serveur réponde ;
3. Chrome (ou Edge s'il n'est pas installé) s'ouvre **en plein écran kiosk**, avec un profil dédié, sans barre
   d'adresse, sans zoom ni geste de retour.

Pour forcer un navigateur, modifiez `set "KIOSK_BROWSER=auto"` en `chrome` ou `edge` dans le script.

**Quitter** : `Ctrl` + `Alt` + `Q` puis le code PIN (ou menu caché › QUITTER LE KIOSK) ferme le navigateur et
arrête le serveur. En secours : `Alt` + `F4` ou `scripts\stop_kiosk.bat`.

### Lancement automatique au démarrage de Windows

Double-cliquez sur **`scripts\install_autostart.bat`** (raccourci dans le dossier Démarrage de la session).
Pour annuler : `scripts\remove_autostart.bat`.

Réglages Windows conseillés pour une borne :

- **Ouverture de session automatique** : `netplwiz` (compte local dédié au photobooth).
- **Jamais de mise en veille** :
  ```bat
  powercfg /change standby-timeout-ac 0
  powercfg /change monitor-timeout-ac 0
  ```
- **Windows Update** : définissez les heures d'activité pour éviter un redémarrage pendant un événement.
- **Notifications** : activez « Ne pas déranger ».
- **Gestes de bord d'écran tactile** (qui ouvrent les menus Windows) : désactivez-les avec la stratégie de groupe
  *Composants Windows › Interface utilisateur de bord › Autoriser le balayage de bord* (*Allow edge swipe*) = Désactivé.

---

## Upload des photos après l'événement

Pendant l'événement, Internet n'est **jamais** nécessaire. Ensuite :

1. Connectez la borne à Internet.
2. Dans `.env` (une seule fois), puis redémarrez :
   ```ini
   UPLOAD_ENABLED=true
   UPLOAD_API_URL=https://photos.mondomaine.fr/api/upload
   UPLOAD_API_TOKEN=le-meme-token-que-sur-le-serveur
   ```
3. **Administration › Upload › UPLOAD TOUTES LES PHOTOS EN ATTENTE** (événement actif ou tous les événements),
   avec barre de progression. Autres possibilités : `scripts\upload_pending.bat` ou `python manage.py upload --all`.

Seules les photos `uploaded = false` sont envoyées (photo finale, code, événement, date ; le token est transmis dans
l'en-tête `Authorization: Bearer`). En cas d'erreur réseau, la photo reste en attente et l'envoi continue avec les
suivantes ; après 3 erreurs réseau consécutives l'envoi s'arrête proprement. Relancez plus tard : rien n'est perdu
ni envoyé deux fois. Les originaux restent uniquement sur la borne.

---

## Serveur web des photos

`upload_server/` est un petit site Flask indépendant, à héberger sur Internet (VPS, serveur dédié…).

| Route | Rôle |
|---|---|
| `POST /api/upload` | Réception d'une photo (`photo`, `photo_code`, `event`, `event_name`, `event_date`, `date` + token) |
| `GET /p/<code>` | « Votre photo 📸 » + TÉLÉCHARGER, ou « Votre photo n'est pas encore disponible. Les photos seront publiées après l'événement. » |
| `GET /media/<code>`, `GET /download/<code>` | Image (affichage, téléchargement) |
| `GET /` | Saisie d'un code à la main |
| `GET /g/<événement>/<secret>` | Galerie privée d'un événement (désactivée par défaut) |
| `GET /api/health` | État du serveur (utilisé par la borne) |

### Test en local

```bat
cd upload_server
python -m venv venv
venv\Scripts\activate
pip install -r requirements.txt
copy .env.example .env
flask --app app generate-token
```

Copiez le token affiché dans `UPLOAD_API_TOKEN` (fichier `upload_server\.env` **et** `.env` de la borne), puis :

```bat
flask --app app run --port 8000
```

Côté borne : `UPLOAD_API_URL=http://127.0.0.1:8000/api/upload` et `PUBLIC_PHOTO_URL=http://127.0.0.1:8000`.

### Mise en ligne sur un serveur Linux (Debian / Ubuntu)

```bash
sudo mkdir -p /srv/photobooth-server && sudo chown $USER /srv/photobooth-server
# copiez le contenu du dossier upload_server dans /srv/photobooth-server
cd /srv/photobooth-server
python3 -m venv venv
venv/bin/pip install -r requirements.txt
cp .env.example .env            # UPLOAD_API_TOKEN, PUBLIC_BASE_URL, BEHIND_PROXY=true, CONTACT_EMAIL
sudo chown -R www-data:www-data /srv/photobooth-server
```

Service systemd `/etc/systemd/system/photobooth-server.service` :

```ini
[Unit]
Description=Serveur des photos du photobooth
After=network.target

[Service]
User=www-data
WorkingDirectory=/srv/photobooth-server
ExecStart=/srv/photobooth-server/venv/bin/gunicorn -w 2 -b 127.0.0.1:8000 wsgi:app
Restart=always

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now photobooth-server
```

Nginx (`/etc/nginx/sites-available/photos`) puis HTTPS avec `sudo certbot --nginx -d photos.mondomaine.fr` :

```nginx
server {
    server_name photos.mondomaine.fr;
    client_max_body_size 20M;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Ne servez **jamais** le dossier `uploads/` directement par nginx : les photos passent par l'application, qui
vérifie chaque code.

### Maintenance

| Commande (dans le dossier du serveur, venv activé) | Rôle |
|---|---|
| `flask --app app cleanup` | Supprime les photos de plus de `PHOTO_RETENTION_DAYS` jours (`--dry-run` pour simuler) |
| `flask --app app gallery-enable festicoat-2027` | Crée la galerie privée de l'événement et affiche son lien secret |
| `flask --app app gallery-disable festicoat-2027` | Désactive la galerie |
| `flask --app app delete-photo A7K4Q92XB3LM` | Supprime une photo à la demande |
| `flask --app app stats` | Photos en ligne par événement |
| `flask --app app generate-token` | Génère un token d'upload |

Suppression automatique chaque nuit (`crontab -e` de l'utilisateur `www-data`) :

```cron
15 3 * * * cd /srv/photobooth-server && venv/bin/flask --app app cleanup >> /srv/photobooth-server/cleanup.log 2>&1
```

---

## Sécurité et confidentialité

**Codes** : 12 caractères tirés par un générateur cryptographique (`secrets`), alphabet de 32 caractères sans 0/O
ni 1/I, soit 2^60 combinaisons ; jamais de compteur. Le serveur limite les recherches de codes inexistants par
adresse IP (30 par 10 minutes par défaut) : deviner un code est impossible en pratique.

**API d'upload** : token obligatoire (comparaison à temps constant), refus de tout token absent ou faux, extensions
limitées à `.jpg`, `.jpeg`, `.png`, **contenu vérifié avec Pillow** (le nom du fichier ne compte pas), taille
limitée (`MAX_UPLOAD_MB`), nom de fichier ignoré et remplacé par le code, chemins vérifiés (aucun `../` possible),
fichiers servis avec le bon type et `X-Content-Type-Options: nosniff`, jamais exécutés.

**Pages** : aucune liste publique, `noindex` et `robots.txt` (pas d'indexation), en-têtes de sécurité (CSP, anti
iframe, `Referrer-Policy: no-referrer`).

**Borne** : serveur accessible uniquement depuis le PC (`127.0.0.1`), administration protégée par PIN avec blocage
après 5 erreurs, cookies `HttpOnly` et `SameSite=Strict`, toutes les modifications en JSON (protection CSRF),
requêtes SQL paramétrées.

**RGPD** : prévenez les invités (affichette près de la borne : « Vos photos seront en ligne pendant 30 jours,
accessibles uniquement avec votre code »), indiquez `CONTACT_EMAIL` pour les demandes de suppression et réglez
`PHOTO_RETENTION_DAYS`. Les photos de la borne restent sur le PC : protégez-le (mot de passe Windows, chiffrement
BitLocker si possible) et supprimez les anciens événements quand ils ne sont plus utiles.

---

## Tests automatiques

```bat
venv\Scripts\activate
python -m pytest
```

Les tests (une dizaine de secondes, sans matériel ni réseau) vérifient notamment : génération et
normalisation des codes, montage (taille, cadre, recadrage centré sans déformation, EXIF, bande photomaton), QR
codes (décodés avec OpenCV), SQLite (création, cycle de vie d'une photo, injections, persistance après
redémarrage), détection des cadres et erreurs de configuration, API de la borne et de l'administration (session
complète, impression, limites, erreurs caméra et imprimante), caméra par commande externe, upload (succès, mauvais
token, coupure réseau) et serveur web (upload, extensions, contenu, taille, path traversal, page inexistante, page
existante, galerie, rétention, limitation des essais).

---

## Commandes utiles

| Commande | Rôle |
|---|---|
| `python app.py` | Lance le serveur (http://127.0.0.1:5000) |
| `python app.py --dev` | Serveur de développement Flask (erreurs détaillées) |
| `python manage.py check` | Vérifie caméra, imprimante, base, stockage et cadres |
| `python manage.py printers` | Liste les imprimantes Windows |
| `python manage.py test-camera` | Prend une photo de test (`data/tests/`) |
| `python manage.py test-print` | Imprime la mire de test |
| `python manage.py events` | Liste les événements et leurs statistiques |
| `python manage.py create-event "Festi'Coat 2027" --date 2027-07-05 --activate` | Crée et active un événement |
| `python manage.py activate-event festicoat-2027` | Change l'événement actif |
| `python manage.py upload --all` | Envoie toutes les photos en attente |
| `python manage.py generate-assets --force` | Régénère la photo de test et les cadres d'exemple |

---

## Dépannage

| Problème | Solution |
|---|---|
| Caméra « ERREUR » au démarrage | Webcam : fermez Teams/Zoom/Caméra Windows, essayez `CAMERA_DEVICE=1` ou `CAMERA_BACKEND=msmf`. Reflex : testez la commande seule dans `cmd` |
| « La commande de capture a échoué » | Lisez `logs/photobooth.log` (la sortie de la commande y est copiée) ; vérifiez les guillemets et les apostrophes de `CAMERA_CAPTURE_COMMAND` |
| Imprimante « hors ligne » | Vérifiez le câble ou le Wi-Fi, décochez « Utiliser l'imprimante hors connexion » dans Windows, videz la file d'attente |
| Bords coupés à l'impression | Gardez une marge dans le cadre, ou `PRINT_FIT_MODE=fit` ; vérifiez le réglage sans bordure du pilote |
| « pywin32 n'est pas installé » | `venv\Scripts\pip install pywin32` |
| Le navigateur ne s'ouvre pas en plein écran | Utilisez `scripts\start_kiosk.bat` (profil dédié) ; forcez `KIOSK_BROWSER=edge` ou `chrome` dans le script |
| Port 5000 déjà utilisé | `PORT=5050` dans `.env` (pris en compte par `start_kiosk.bat`) |
| Upload « Token refusé » | Le même `UPLOAD_API_TOKEN` doit être dans les deux fichiers `.env` |
| Upload « Serveur injoignable » | Vérifiez Internet et `UPLOAD_API_URL` ; ouvrez `https://votre-site/api/health` dans un navigateur |
| Le QR code mène au mauvais site | `PUBLIC_PHOTO_URL` est inscrit dans les QR codes : réglez-le avant l'événement et conservez ce domaine |
| Où sont les journaux ? | `logs/photobooth.log`, ou **Administration › Télécharger les journaux** |

---

## Aller plus loin

**Ajouter un modèle d'appareil photo** sans toucher au reste du programme : une classe avec `capture()` et
`check()`, enregistrée sous un nouveau nom. Exemple complet avec gPhoto2 (Linux, macOS) :

```python
# services/gphoto_camera.py
import subprocess
from pathlib import Path

from services.camera import CameraProvider, register_camera
from services.devices import DeviceStatus
from services.errors import CameraError


class GPhotoCamera(CameraProvider):
    mode = "gphoto"
    label = "Reflex (gPhoto2)"

    def capture(self, output_path: Path) -> Path:
        command = ["gphoto2", "--capture-image-and-download", "--filename", str(output_path), "--force-overwrite"]
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise CameraError("Le reflex ne répond pas.") from exc
        if result.returncode != 0 or not output_path.is_file():
            raise CameraError("Le reflex n'a pas pu prendre la photo.")
        return output_path

    def check(self) -> DeviceStatus:
        try:
            result = subprocess.run(["gphoto2", "--auto-detect"], capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            return DeviceStatus(False, "gPhoto2 n'est pas installé")
        detected = result.returncode == 0 and len(result.stdout.strip().splitlines()) > 2
        return DeviceStatus(detected, "Reflex détecté" if detected else "Aucun reflex détecté")


register_camera("gphoto", lambda config: GPhotoCamera())
```

Ajoutez `import services.gphoto_camera  # noqa: F401` en haut de `services/container.py`, puis `CAMERA_MODE=gphoto`.
Une classe `CanonCamera`, `NikonCamera` ou `SonyCamera` basée sur le SDK du constructeur suit exactement le même
modèle. Le principe vaut aussi pour les imprimantes (`register_printer` dans `services/printer.py`).

**Personnaliser l'apparence** : `KIOSK_TITLE`, `ACCENT_COLOR`, et les feuilles de style `static/css/kiosk.css`
(borne) et `upload_server/static/css/site.css` (site des invités).
