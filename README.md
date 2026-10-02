# 🛡️ Rempart — anti-cheat FiveM serveur-autoritaire

> **Le serveur est la seule source de vérité.** Le client signale ; le serveur recoupe, prouve et décide.

Rempart est un anti-cheat complet pour serveurs FiveM avec OneSync. Il a été conçu à partir de la documentation officielle Cfx.re, du **code source de FXServer**, de l'étude des anti-cheats open source et de celle des **cheats réellement vendus** (redENGINE, Eulen, menus Lua…) : chaque fonction de cheat étudiée a sa contre-mesure ([voir le tableau](#cheats-étudiés-et-contre-mesures)). Il ne compte ni sur le secret ni sur l'obfuscation. Sa force vient de contrôles que le tricheur **ne peut pas désactiver**, parce qu'ils ne tournent pas sur sa machine.

| | |
|---|---|
| 🧠 **Serveur-autoritaire** | **58 détections exécutées sur le serveur**, à partir des données de synchronisation OneSync et des événements de jeu que FXServer route (et qui peuvent être **annulés avant d'atteindre les autres joueurs**). |
| 🧱 **Pare-feu d'événements** | Un *shield* **bloquant** à inclure dans vos ressources (débit, arguments malformés, ACE, distance, `serverOnly`, quarantaine). S'y ajoute un **capteur global** qui voit tous les événements réseau grâce à l'abonnement joker `*`. |
| 🔐 **Client signé** | Un canal HMAC-SHA256 avec clé de session, anti-rejeu et heartbeat à défi. Un client anti-cheat arrêté, bloqué, falsifié ou filtré (*event blocker*) est démasqué. |
| 🧾 **Attestation des événements** | Le shield compte les `TriggerServerEvent` de vos ressources, le client anti-cheat les atteste, le capteur compte ce que le serveur reçoit : un trigger lancé **hors de vos ressources** (exécuteur en « ressource isolée », trigger finder) est démasqué. |
| 🎯 **Pas de ban sur un faux positif isolé** | Score de risque qui décroît avec le temps, déclarations d'intention des scripts légitimes, apprentissage automatique, preuves de comportement, mode audit. |
| 🔨 **Bans difficiles à contourner** | Tous les identifiants + tokens matériels + **marqueur client** (résiste aux spoofers HWID), extension automatique en cas de contournement. Stockage KVP ou MySQL (bans partagés entre plusieurs serveurs). |
| 🩺 **Sécurité du serveur** | Audit des convars de sécurité Cfx.re et scanner de backdoors (Cipher Panel & co.) au démarrage. |

Aucune dépendance obligatoire (screenshot-basic et oxmysql sont facultatifs). Lua 5.4. Vérifié par **85 scénarios automatisés** sur un simulateur FXServer inclus, et par `luacheck` (0 avertissement).

---

## Sommaire

1. [Principe](#principe)
2. [Cheats étudiés et contre-mesures](#cheats-étudiés-et-contre-mesures)
3. [Fonctionnalités](#fonctionnalités)
4. [Installation](#installation)
5. [Le shield : protéger vos ressources](#le-shield--protéger-vos-ressources)
6. [Configuration](#configuration)
7. [Commandes d'administration](#commandes-dadministration)
8. [API pour vos scripts](#api-pour-vos-scripts)
9. [Catalogue des détections](#catalogue-des-détections)
10. [Journaux](#journaux)
11. [Tests](#tests)
12. [Limites](#limites)
13. [Recherche et références](#recherche-et-références)

---

## Principe

Les menus de triche (exécuteurs Lua, injecteurs, menus externes) contrôlent toute la machine du joueur. Tout ce qui s'y exécute peut être lu, désactivé ou falsifié. Un anti-cheat qui repose sur le client finit donc toujours par être contourné. Rempart inverse la logique :

1. **Le serveur observe ce que le jeu du tricheur est obligé de lui envoyer** : positions, état du joueur, armes, entités créées, explosions, dégâts, événements. FXServer route ces actions, et Rempart peut les **annuler** (`CancelEvent`) avant qu'elles n'atteignent les autres joueurs.
2. **Le client n'est qu'un capteur.** Il ne décide jamais d'une sanction. Ses messages sont signés, et il ne peut signaler que des détections de la catégorie « client » (un tricheur ne peut que s'auto-dénoncer).
3. **Les preuves s'accumulent.** Chaque détection heuristique ajoute des points à un score qui décroît dans le temps. Seules les preuves non ambiguës bannissent immédiatement : piège déclenché, ressource injectée, réponse cryptographique falsifiée, arme donnée à un autre joueur…

```
 Client (tricheur ou non)                        Serveur FXServer
 ────────────────────────                        ──────────────────────────────────────────────
 synchro OneSync ────────────────────────────▶  état joueur / positions / véhicules ──┐
 événements de jeu (explosion, dégâts…) ─────▶  routage FXServer ─▶ annulé si interdit ┤
 TriggerServerEvent ──┬──────────────────────▶  rempart_sensor (joker *) : observe, compte
                      └──────────────────────▶  shield (vos ressources) : bloque ─────┤
 shield client : compte ses TriggerServerEvent ┐                                      │
 client Rempart ─── HMAC-SHA256 + heartbeat ───┴▶ canal signé + attestations ─────────┤
                                                                                      ▼
                         Detect ─▶ immunités ─▶ score (décroissance) ─▶ logs / Discord
                                ─▶ quarantaine ─▶ capture d'écran ─▶ kick / ban (ids + HWID)
```

---

## Cheats étudiés et contre-mesures

Les fonctions ci-dessous sont celles que les vendeurs de cheats mettent en avant (pages produit de redENGINE, Eulen, Macho, menus Lua publics) et celles que les anti-cheats open source ont documentées. Pour chacune, ce que fait Rempart :

| Fonction de cheat | Comment Rempart la contre |
|---|---|
| **Exécuteur Lua en « ressource isolée »** (redENGINE : « runs inside an isolated FiveM resource ») | **Attestation** : ses `TriggerServerEvent` ne passent par aucun shield, ils arrivent au serveur sans attestation (`event_unattested`). Ses entités portent un script inconnu du serveur (`entity_unknown_script`) ; sa ressource fantôme est inconnue du serveur (`resource_injected`). |
| **Exécution dans une ressource légitime choisie** | Le shield de chaque ressource protégée inspecte son environnement Lua (variables globales de menus) ; toutes les détections comportementales serveur restent actives. |
| **Trigger finder, event logger, « money triggers »** | Attestation, pièges (dont pièges « forts » et motif `DFWM` de certains menus), pare-feu du shield (débit, distance, ACE, `serverOnly`). |
| **Event blocker** (filtre les messages de l'anti-cheat) | Chaque attestation signée porte le nombre de messages envoyés : des **détections manquantes** trahissent le filtre (`client_blocked`) ; des attestations absentes alors que le heartbeat passe aussi. |
| **Resource stopper / resource blocker** | Arrêt local reconfirmé par le serveur ; témoins (shields des autres ressources) ; heartbeat signé ; module anti-cheat absent **90 s après** que les autres scripts du joueur ont commencé à envoyer des événements (`client_missing`). |
| **Contournement des captures d'écran** (« SHBypass », overlay *streamproof*) | Aucune sanction ne repose sur une capture : les preuves sont serveur. Les captures restent un complément. |
| **Spoofer HWID + nouveau compte** | Marqueur aléatoire conservé chez le joueur (KVP client + stockage NUI) : un banni qui revient est reconnu même avec de nouveaux tokens (`ban_evasion`). |
| **Godmode** | `GetPlayerInvincible` avec preuve de combat ; **godmode par immunités** (proofs) : dégâts mortels répétés sans aucune baisse de santé (`godmode_absorb`). |
| **Semi-godmode** (se soigne instantanément) | Remontée de santé non déclarée (`health_regen`) ; les soins des scripts sont déclarés par le shield. |
| **Silent aim, magic bullet** | Cible derrière le ped, cible hors du champ de la **caméra synchronisée** (`combat_camera`), portée, et **tirs à travers les murs** signalés par plusieurs victimes et recoupés par le serveur (`combat_wallbang`). |
| **Kill all, « fold », kill par fiente d'oiseau** | **Dégâts forgés** : arme environnementale (chute, noyade…) envoyée à un joueur, bloquée (`combat_forged`) ; kill aura. |
| **Munitions explosives / incendiaires** | Explosions contrôlées côté serveur ; type de dégâts modifié sur une arme à balles (`client_ammo`). |
| **Cages, pluie de véhicules, armée de PNJ sur un joueur** | Création **au contact d'un autre joueur, loin du créateur** (`entity_remote_spawn`) ; modèles interdits, débit, attachements. |
| **Money drop** | Ramassables limités en débit. |
| **Taser modifié / anti-ragdoll** | Portée du taser ; victime qui ne tombe jamais (`tazer_ragdoll`). |
| **Hitbox expander** | Dimensions des modèles de personnage modifiées (`client_hitbox`). |
| **Menus Lua** (Lynx, HamMafia, Brutan, Dopamine, Absolute…) | Variables globales, textures DUI créées à l'exécution, commandes, textures connues. |
| **Sondes de framework** (`esx:getSharedObject` sur un serveur sans ESX…) et exploits client de vieux scripts | **Pièges client** armés seulement si la ressource visée n'existe pas (`client_honeypot`). |
| **Injection dans le module anti-cheat lui-même** | Natives du module remplacées (`client_env_tamper`). |
| **DevTools NUI** (appel direct des callbacks) | Piège `debugger`. |
| **Noclip, téléportation, vitesse, véhicules modifiés** | Détections de mouvement, d'état et de véhicule serveur + client. |
| **Backdoors** (Cipher Panel…) | Scanner au démarrage. |

---

## Fonctionnalités

### Détections serveur (OneSync)

| Module | Source | Ce qui est détecté ou bloqué |
|---|---|---|
| **Entités** | `entityCreating` + `GetEntityScript` | **Exécuteurs Lua** : entité créée par un script qui n'existe pas sur le serveur (le thread d'une ressource cliente porte le hash `joaat(nom)` de la ressource). Ressources détournées (`chat`, `spawnmanager`… qui ne créent jamais d'entités). Modèles interdits (props de crash, cages, véhicules militaires). Spam de spawn et de ramassables. Objets attachés à un autre joueur. **Création au contact d'un autre joueur, loin du créateur** (cages). |
| **Explosions** | `explosionEvent` | Types interdits (canon orbital, bombes…), spam, explosion **attribuée à un autre joueur** (blame), explosions à distance, invisibles, silencieuses ou amplifiées. |
| **Armes** | `giveWeaponEvent`, `removeWeaponEvent`, `removeAllWeaponsEvent` | « Give/remove weapons all » sur d'autres joueurs (ces événements ne sont émis que pour un ped que le client ne possède pas). Armes interdites en main, retirées par le serveur. |
| **Combat** | `weaponDamageEvent` (annulable) + `GetPlayerCameraRotation` | **Dégâts forgés** (arme environnementale envoyée à un joueur), portée impossible (dont le taser), dégâts à travers les dimensions, **silent aim** (cible derrière le tireur ou hors du champ de sa caméra synchronisée), cadence impossible, **kill aura**, dégâts forcés, **godmode par immunités** (dégâts mortels sans effet), taser sans chute, **tirs à travers les murs** (témoignages recoupés). |
| **Effets** | `ptFxEvent`, `fireEvent`, `startProjectileEvent` | Particules interdites, géantes ou en rafale ; feux sur les joueurs ; projectiles « magic bullet ». |
| **Tâches** | `clearPedTasksEvent`, `givePedScriptedTaskEvent` | Éjection de véhicule, gel ou animation forcée sur un autre joueur. |
| **Mouvement** | positions synchronisées | Téléportation non déclarée (avec **apprentissage** des points légitimes), vitesse à pied impossible, noclip (collisions coupées ou position gelée en mouvement). |
| **État du joueur** | nœuds de synchro OneSync | Godmode (`GetPlayerInvincible`, avec preuve de combat), **semi-godmode** (soin instantané non déclaré), super saut, **multiplicateurs de dégâts/défense**, santé ou armure au-delà du maximum, invisibilité en mouvement, caméra libre éloignée, ped interdit, boost de traînée aérodynamique. |
| **Véhicules** | synchro véhicule | Santé au-delà du maximum, réparations non déclarées (`GetVehicleTotalRepairs`). |
| **Connexion** | `playerConnecting` + marqueur client | Bans (identifiants + tokens matériels + marqueur client), contournements, pseudos malveillants (HTML, caractères invisibles), flood de reconnexion, VPN (facultatif, proxycheck.io). |

### Événements réseau

- **Capteur global** (`rempart_sensor`) : il s'abonne au joker `*` de FXServer et voit **tous** les événements envoyés par les clients, même ceux qu'aucune ressource n'écoute. C'est exactement ce que font les menus avec leurs listes de « triggers ». Il signale les pièges, les floods, les rafales d'événements distincts (« trigger all »), les charges démesurées et les événements inexistants. Il garde aussi les 40 derniers événements de chaque joueur (trace jointe aux bans). Il ne fait qu'observer et vit dans sa propre ressource pour ne jamais perturber les autres.
- **Pièges (honeypots)** : 118 événements de vieux scripts ESX/vRP visés par les menus (dont la liste publique des événements abusés), 20 pièges « forts » (chaînes aléatoires de menus, événements d'anciens anti-cheats que les menus déclenchent pour se désactiver, faux menus admin) et le motif `DFWM` que certains menus insèrent dans leurs noms de triggers. Un piège n'est armé **que si l'événement n'existe pas** sur votre serveur. Rempart vérifie pour cela l'analyse statique de vos scripts, les préfixes de ressources et les ressources chiffrées, et revérifie au moment du déclenchement. Un piège classique se désarme tout seul si plusieurs joueurs distincts le déclenchent ; si le serveur contient des ressources chiffrées (illisibles), il ne vaut plus qu'un score.
- **Attestation** : le capteur compte, joueur par joueur, les événements protégés réellement reçus et les rapproche des compteurs attestés par le client anti-cheat. Les événements aussi déclenchés par des ressources sans shield (analyse statique de leur code client, scripts JS/C#) ou par plusieurs joueurs distincts (apprentissage) ne sont jamais signalés.
- **Shield** : pare-feu **bloquant** inclus dans vos ressources ([voir plus bas](#le-shield--protéger-vos-ressources)).

### Client anti-cheat

- **Canal signé HMAC-SHA256** (clé de session aléatoire de 256 bits, séquence anti-rejeu) et **heartbeat à défi** toutes les 15 s. Client absent ou muet ⇒ kick (jamais de ban : une connexion instable ne doit bannir personne). Réponse falsifiée ⇒ ban.
- **Messages filtrés** (*event blocker*) : chaque attestation signée porte le nombre de messages envoyés ; s'il manque des rapports de détection côté serveur, le filtre est démasqué.
- **Ressources injectées** (inconnues du serveur), **resource stoppers** et **resource blockers**. Un arrêt local n'est sanctionné que si le serveur le reconfirme 10 s plus tard, jamais à la déconnexion.
- **Menus Lua** : variables globales caractéristiques (dans ce module ET dans chaque ressource protégée), textures DUI créées à l'exécution, textures et commandes de menus connus, commandes enregistrées par une ressource inconnue.
- **Intégrité du module** : natives remplacées dans son environnement (injection dans l'anti-cheat lui-même).
- **Pièges client** : événements locaux que les menus déclenchent pour sonder le framework ou exploiter de vieux scripts absents du serveur.
- **Munitions modifiées** (explosives/incendiaires sur une arme à balles) et **hitbox agrandies**.
- **Témoin** : touché par un joueur sans ligne de vue (murs), la victime le signale ; le serveur recoupe.
- **Marqueur de ban** : identifiant aléatoire conservé en KVP client et dans le stockage NUI.
- Godmode, spectateur, invisibilité, noclip/vol, caméra libre, visions, ped miniature, anti-ragdoll, armes et modificateurs de dégâts, véhicule indestructible, boosté ou trop rapide.
- **DevTools NUI** (piège `debugger`) : bloque l'appel direct des callbacks NUI de vos inventaires et banques avec des données forgées.
- La configuration est envoyée par le serveur à l'exécution : le cache du client ne contient rien d'exploitable (ni seuils, ni webhooks).

### Contre les faux positifs

- **Score de risque** : demi-vie de 10 min ; seuils alerte 30 / kick 70 / ban 100. Une même détection répétée compte de moins en moins (×0,5, ×0,25…). Le score survit 1 h à une reconnexion.
- **Déclarations d'intention** : le shield voit quand **vos** scripts téléportent le joueur, le soignent, le rendent invisible ou invincible, activent une caméra, le mode spectateur, réparent un véhicule… L'anti-cheat ne les confond donc pas avec un tricheur. Un exécuteur qui appelle les natives directement ne déclare rien et reste détecté.
- **Apprentissage** : un point de téléportation utilisé par plusieurs joueurs distincts (ascenseur, intérieur, garage) est validé automatiquement. Les pièges et les événements « inconnus » sont désarmés de la même façon.
- **Preuves de comportement** : un joueur invincible et immobile (script de mort, zone safe) n'est pas en godmode ; il faut qu'il soit en combat. Un godmode par immunités exige deux rafales mortelles sans **aucune** baisse de santé (un serveur qui réduit les dégâts des armes n'est pas concerné).
- **Recoupements** : un témoignage de tir à travers un mur ne compte que si le serveur a vu le tir, et seulement quand plusieurs victimes distinctes accusent le même tireur ; un événement non attesté n'est signalé que s'il n'est jamais appelé hors shield.
- **Périodes de grâce** à l'apparition, à la réanimation, aux changements de ped et de dimension.
- **Immunités** : ACE `rempart.bypass` (globale, par détection ou par catégorie), admins txAdmin authentifiés (noclip/god du menu txAdmin), exemptions temporaires.
- **Mode audit** : tout est détecté et journalisé, rien n'est sanctionné.

### Sanctions et bans

- Kick ou ban avec un message clair (identifiant du ban, lien de contestation). **Capture d'écran** préalable si screenshot-basic est présent. **Quarantaine** du joueur pendant la procédure : les shields bloquent tous ses événements.
- Bans sur **tous les identifiants**, les **tokens matériels** (`GetPlayerTokens`) et le **marqueur client**. En cas de contournement, les nouveaux identifiants rejoignent le ban.
- Stockage **KVP** intégré (sans dépendance) ou **oxmysql** (bans partagés entre plusieurs serveurs).
- Journaux en console, en fichiers JSON quotidiens et sur **Discord** (4 webhooks).

### Sécurité du serveur

- **Audit** au démarrage (`rmp audit`) : OneSync, ScriptHook, `sv_entityLockdown`, `sv_filterRequestControl`, sons réseau, state bags stricts, pure level, RCON, `builtin.everyone`, ressources ayant accès à toute la console… Il produit une note sur 100 et les corrections à appliquer.
- **Scanner de backdoors** (`rmp scan`), en lecture seule. Il cherche les loaders Cipher Panel (`PerformHttpRequest` + `load`), les domaines C2 connus, le code reçu d'un client puis exécuté, le vol de secrets du `server.cfg`, les commandes système et les API sensibles cachées dans des chaînes obfusquées (`\x50\x65…`, `string.char(…)`).

---

## Installation

### Prérequis

- Un FXServer récent avec **OneSync activé**. C'est indispensable : la majorité des détections lisent la synchronisation OneSync.
- Facultatif : `screenshot-basic` (captures jointes aux bans), `oxmysql` (bans partagés), `chat` (alertes du staff en jeu).

### 1. Copier les ressources

Copiez le dossier `[rempart]` dans `resources/`. Il contient deux ressources :

| Ressource | Rôle |
|---|---|
| `rempart` | L'anti-cheat (serveur + client + shield). |
| `rempart_sensor` | Le capteur global des événements réseau (serveur uniquement). |

> 💡 **Renommez `rempart`** (par exemple `core_utils`) : les « resource stoppers » ciblent les noms connus. Choisissez ce nom **avant** la mise en production, car les bans KVP sont liés au nom de la ressource (oxmysql n'a pas ce problème). Si vous renommez, déclarez-le dans le `server.cfg` (`setr rempart:resource "core_utils"`) et utilisez `@core_utils/shield.lua` dans vos manifests.

### 2. Configurer le `server.cfg`

Un exemple complet est fourni dans [`docs/server.cfg.example`](docs/server.cfg.example). L'essentiel :

```cfg
set onesync on

# Nom de la ressource anti-cheat (obligatoire si vous l'avez renommée)
setr rempart:resource "rempart"

# Webhooks Discord, lisibles UNIQUEMENT par l'anti-cheat (une backdoor ne peut pas les voler)
set rempart_webhook_detections "https://discord.com/api/webhooks/..."
set rempart_webhook_bans       "https://discord.com/api/webhooks/..."
add_convar_permission rempart read rempart_webhook_detections
add_convar_permission rempart read rempart_webhook_bans

# Permissions
add_ace group.admin rempart.admin allow     # commandes rmp + alertes en jeu
add_ace group.admin rempart.bypass allow    # immunité totale aux détections

# L'anti-cheat en premier, le capteur juste après
# ensure oxmysql                            # seulement si Config.Bans.storage = 'oxmysql' (avant rempart)
ensure rempart
ensure rempart_sensor
ensure screenshot-basic                     # facultatif

# ... puis vos ressources
```

### 3. Démarrer en mode audit

Dans `config.lua`, mettez `Config.AuditMode = true` pendant **2 à 7 jours**. Tout est détecté et journalisé, mais personne n'est sanctionné. Lisez ensuite les journaux, ajoutez le shield aux ressources qui génèrent des faux positifs, ajustez les seuils, puis repassez à `false`. La commande `rmp observe on|off` bascule ce mode à chaud.

### 4. Vérifier

- `rmp status` : version, joueurs, bans, capteur, nombre de shields et de pièges.
- `rmp audit` : note de sécurité et corrections recommandées.
- `rmp shield` : liste des ressources qui n'incluent pas encore le shield.

---

## Le shield : protéger vos ressources

Ajoutez **une ligne, en premier**, dans le `fxmanifest.lua` de vos ressources, en priorité votre framework (ESX, QBCore…) et celles qui gèrent l'argent, les objets, les jobs, les téléportations, les caméras ou l'invisibilité :

```lua
shared_script '@rempart/shield.lua'   -- adaptez le nom si vous avez renommé la ressource
```

« En premier » compte : un script chargé avant le shield échappe au comptage des événements (Rempart l'indique au démarrage). Plus vos ressources sont protégées, plus l'attestation est précise.

Le shield est passif tant que l'anti-cheat n'est pas démarré. Chaque appel est protégé : il ne peut pas casser la ressource qui l'inclut.

**Côté serveur, il crée un pare-feu bloquant.** Avant que votre gestionnaire d'événement ne s'exécute, chaque appel venu d'un client est vérifié :

- débit par joueur et par événement (règles par défaut et règles personnalisées) ;
- arguments malformés : `NaN`, infini, nombres démesurés, chaînes géantes, tables trop profondes ou trop volumineuses ;
- règles déclaratives : `serverOnly`, `ace`, distance (`near`/`radius`), débit (`rate`/`per`) ;
- quarantaine : un joueur en cours de sanction ne peut plus rien déclencher.

Les intentions des scripts serveur (`SetEntityCoords`, `FreezeEntityPosition`, `SetPlayerInvincible`, `GiveWeaponToPed` sur un joueur) sont signalées comme légitimes.

**Côté client, il déclare les intentions.** Quand votre script téléporte le joueur, le soigne, le rend invisible ou invincible, coupe ses collisions, le gèle, active une caméra scriptée, le mode spectateur ou une vision, répare ou booste son véhicule… l'anti-cheat est prévenu et ne le confond pas avec un tricheur.

**Côté client, il compte et il inspecte.** Chaque `TriggerServerEvent` de la ressource est compté pour l'**attestation** (un trigger lancé hors de vos ressources est démasqué), et l'environnement Lua de la ressource est inspecté à la recherche des variables globales de menus injectés (les exécuteurs choisissent souvent une ressource légitime pour s'y loger).

Règles du pare-feu (dans `config.lua`, `Config.Events.firewall.rules`) :

```lua
rules = {
    ['esx_garbagejob:pay'] = { rate = 1, per = 60 },                       -- 1 paie par minute max
    ['bank:withdraw'] = { rate = 3, per = 10,
        near = { vector3(150.0, -1040.0, 29.0) }, radius = 30.0 },          -- seulement près d'un guichet
    ['admin:setJob'] = { serverOnly = true },                               -- jamais depuis un client
    ['police:cuff']  = { ace = 'job.police' },                              -- réservé à un principal ACE
},
```

> Le shield ne remplace pas les validations de vos scripts. Vérifiez toujours côté serveur l'argent, les objets, la position et les permissions (voir [Secure Your Events](https://docs.fivem.net/docs/developers/server-security/)). Il limite les dégâts quand ces validations manquent.

---

## Configuration

Tout se trouve dans [`config.lua`](%5Brempart%5D/rempart/config.lua), commenté section par section : risque, sanctions, bans, connexion, journaux, client, entités, explosions, armes, combat, effets, tâches, mouvement, état du joueur, véhicules, événements, audit, scanner.

Chaque détection peut être réglée individuellement :

```lua
Config.Detections = {
    ['teleport']        = { enabled = false },             -- désactiver
    ['explosion_blame'] = { action = 'ban' },               -- sanction immédiate
    ['freecam']         = { score = 0, action = 'log' },    -- simple journalisation
    ['combat_angle']    = { score = 6, cooldown = 10 },     -- moins sévère
}
```

Champs disponibles : `enabled`, `action` (`score` | `kick` | `ban` | `log`), `score`, `cooldown` (s), `banDuration` (s, 0 = définitif), `screenshot`.

Réglages issus de l'étude des cheats : `Config.Events.attestation` (attestation, apprentissage), `Config.Combat` (`forgedDamage`, `cameraCheck`/`cameraMaxAngle`, `absorbCheck`, `tazerRagdoll`, `wallbang`), `Config.PlayerState.healthRegen`, `Config.Entities.remoteSpawn`, `Config.Client.activityTimeout`, `Config.Bans.cookies`, et les contrôles client `globals`, `envTamper`, `honeypots`, `ammo`, `hitbox`, `witness`. Pour un réseau de serveurs aux bans partagés (oxmysql), définissez la même convar `rempart_cookie_secret` sur chaque serveur.

**Immunités ciblées** par ACE : `rempart.bypass.<détection>` ou `rempart.bypass.<catégorie>`. Exemple : `add_ace group.mod rempart.bypass.movement allow`. Catégories : `entity`, `explosion`, `weapon`, `combat`, `effect`, `task`, `movement`, `state`, `vehicle`, `event`, `client`, `connection`, `custom`.

---

## Commandes d'administration

Utilisables depuis la console serveur ou le chat avec l'ACE `rempart.admin`. Durées : `30m`, `12h`, `7d`, `2w`, `perm`.

| Commande | Effet |
|---|---|
| `rmp status` | État général (version, joueurs, bans, mode audit, capteur, shields, pièges). |
| `rmp player <id>` | Score de risque, identifiants, session anti-cheat et 10 dernières détections. |
| `rmp kick <id> <raison>` | Expulsion. |
| `rmp ban <id\|identifiant> <durée\|perm> <raison>` | Ban d'un joueur connecté, ou hors ligne par identifiant (`license:…`). |
| `rmp unban <ban\|identifiant>` | Levée d'un ban. |
| `rmp baninfo <ban>` / `rmp bans [recherche]` | Détails d'un ban / recherche. |
| `rmp screenshot <id>` | Capture d'écran envoyée sur Discord. |
| `rmp exempt <id> <détection\|catégorie\|all> <durée>` | Exemption temporaire. |
| `rmp reset <id>` | Remise à zéro du score. |
| `rmp observe on\|off` | Mode audit à chaud. |
| `rmp audit` / `rmp scan` | Audit de sécurité / scanner de backdoors. |
| `rmp shield` / `rmp events` / `rmp stats` | Couverture du shield / registre d'événements / statistiques d'entités. |

---

## API pour vos scripts

### Exports serveur

```lua
local AC = exports[GetConvar('rempart:resource', 'rempart')]

AC:Flag(source, 'money_exploit', { montant = 1e9 }, 80)    -- détection personnalisée (score 80)
AC:AllowTeleport(source, vector3(x, y, z))                  -- téléportation légitime à venir
AC:Exempt(source, 'noclip', 30)                             -- exemption temporaire (s)
AC:Declare(source, 'invisible', true)                       -- état légitime déclaré côté serveur
AC:Ban(source, 'Raison', 0)                                 -- 0 = définitif ; retourne l'identifiant du ban
AC:BanIdentifier('license:xxxx', 'Raison', 86400)
AC:Unban('RMP-AB12CD')
AC:IsBanned({ 'license:xxxx' }, tokens)                     -- enregistrement du ban ou false
AC:Kick(source, 'Raison')
AC:SetBypass(source, true)
AC:GetRisk(source)  AC:GetHistory(source)  AC:IsAuditMode()
```

### Export client

Le shield l'appelle pour vous. Vous pouvez aussi l'utiliser directement :

```lua
exports[GetConvar('rempart:resource', 'rempart')]:Declare('invisible', true, GetCurrentResourceName())
```

Types : `tp`, `heal`, `invisible`, `invincible`, `collision`, `frozen`, `camera`, `spectate`, `vision`, `ragdoll`, `superjump`, `vehiclegod`, `vehiclepower`, `repair`.

---

## Catalogue des détections

« +N » = points ajoutés au score de risque (alerte 30, kick 70, ban 100). `ban` / `kick` = sanction immédiate. Toutes les valeurs se règlent dans `Config.Detections`.

| Catégorie | Identifiant | Défaut | Description |
|---|---|---|---|
| Entités | `entity_attach_player` | +40 | Objet attaché à un autre joueur |
| Entités | `entity_blacklisted` | +50 | Spawn d'un modèle interdit |
| Entités | `entity_forbidden_res` | +80 | Entité créée depuis une ressource détournée |
| Entités | `entity_remote_spawn` | +40 | Entité créée sur un autre joueur, loin du créateur (cage, troll) |
| Entités | `entity_spam` | +35 | Spawn massif d'entités |
| Entités | `entity_unknown_script` | +100 | Entité créée par un script inconnu (exécuteur) |
| Explosions | `explosion_blame` | +60 | Explosion attribuée à un autre joueur |
| Explosions | `explosion_blocked` | +40 | Explosion d'un type interdit |
| Explosions | `explosion_modified` | +25 | Explosion invisible/silencieuse/amplifiée |
| Explosions | `explosion_remote` | +30 | Explosion à distance sur un joueur |
| Explosions | `explosion_spam` | +35 | Spam d'explosions |
| Armes | `weapon_blacklisted` | +60 | Arme interdite en main |
| Armes | `weapon_give_player` | ban | Arme donnée à un autre joueur |
| Armes | `weapon_remove_player` | ban | Arme retirée à un autre joueur |
| Combat | `combat_angle` | +12 | Tir dans un angle impossible (silent aim) |
| Combat | `combat_blacklisted` | +50 | Dégâts avec une arme interdite |
| Combat | `combat_bucket` | +50 | Dégâts à travers les dimensions |
| Combat | `combat_camera` | +10 | Cible touchée hors du champ de la caméra (silent aim) |
| Combat | `combat_distance` | +25 | Dégâts à une distance impossible |
| Combat | `combat_forged` | +80 | Dégâts forgés (arme environnementale envoyée à un joueur) |
| Combat | `combat_multitarget` | +45 | Touches simultanées sur de nombreuses cibles (kill aura) |
| Combat | `combat_override` | +40 | Dégâts forcés anormaux |
| Combat | `combat_rate` | +35 | Cadence de tir impossible |
| Combat | `combat_wallbang` | +30 | Tirs à travers les murs signalés par plusieurs victimes (magic bullet) |
| Effets | `fire_player` | +40 | Feu allumé sur un autre joueur |
| Effets | `fire_spam` | +30 | Spam de feux |
| Effets | `projectile_spam` | +35 | Spam de projectiles |
| Effets | `projectile_spawn` | +35 | Projectile créé hors de toute arme (magic bullet) |
| Effets | `ptfx_blocked` | +40 | Particule interdite ou géante |
| Effets | `ptfx_spam` | +30 | Spam de particules |
| Tâches | `task_clear_player` | +50 | Tâches d'un autre joueur annulées (éjection/gel) |
| Tâches | `task_force_player` | +60 | Tâche imposée à un autre joueur |
| Mouvement | `noclip` | +40 | Noclip (déplacement sans collision) |
| Mouvement | `speedhack` | +30 | Vitesse à pied impossible |
| Mouvement | `teleport` | +15 | Téléportation non déclarée |
| État du joueur | `air_drag` | +30 | Traînée aérodynamique modifiée (boost véhicule) |
| État du joueur | `damage_modifier` | +100 | Modificateur de dégâts |
| État du joueur | `defense_modifier` | +50 | Modificateur de défense |
| État du joueur | `freecam` | +8 | Caméra libre éloignée |
| État du joueur | `godmode` | +35 | Invincibilité (godmode) |
| État du joueur | `godmode_absorb` | +35 | Dégâts mortels encaissés sans effet (godmode par immunités) |
| État du joueur | `health_overflow` | +50 | Santé ou armure au-delà du maximum |
| État du joueur | `health_regen` | +15 | Soin instantané non déclaré (semi-godmode) |
| État du joueur | `invisible` | +30 | Invisibilité en mouvement |
| État du joueur | `ped_blacklisted` | +50 | Modèle de personnage interdit |
| État du joueur | `superjump` | +50 | Super saut |
| État du joueur | `tazer_ragdoll` | +15 | Aucune chute après un tir de taser (anti-ragdoll) |
| Véhicules | `vehicle_health` | +30 | Santé de véhicule au-delà du maximum |
| Véhicules | `vehicle_repair` | +5 | Réparation de véhicule non déclarée |
| Événements réseau | `event_burst` | +35 | Rafale d'événements distincts (trigger all) |
| Événements réseau | `event_firewall` | +20 | Règle du pare-feu d'événements violée |
| Événements réseau | `event_flood` | +40 | Flood d'événements réseau |
| Événements réseau | `event_honeypot` | ban | Événement-piège déclenché |
| Événements réseau | `event_malformed` | +30 | Arguments d'événement malformés |
| Événements réseau | `event_payload` | +25 | Événement réseau démesuré |
| Événements réseau | `event_unattested` | +30 | Événement protégé déclenché hors de toute ressource (exécuteur isolé) |
| Événements réseau | `event_unknown` | +3 | Événements inexistants déclenchés |
| Client anti-cheat | `client_ammo` | +40 | Munitions explosives ou incendiaires (arme modifiée) |
| Client anti-cheat | `client_blocked` | +40 | Messages anti-cheat bloqués (event blocker) |
| Client anti-cheat | `client_env_tamper` | +80 | Environnement du client anti-cheat modifié (injection) |
| Client anti-cheat | `client_freecam` | +10 | Caméra libre (client) |
| Client anti-cheat | `client_godmode` | +35 | Invincibilité (client) |
| Client anti-cheat | `client_hitbox` | +40 | Dimensions des personnages modifiées (hitbox) |
| Client anti-cheat | `client_honeypot` | +60 | Événement client piège déclenché |
| Client anti-cheat | `client_invisible` | +25 | Invisibilité (client) |
| Client anti-cheat | `client_missing` | kick | Module anti-cheat client absent |
| Client anti-cheat | `client_noclip` | +35 | Noclip / vol (client) |
| Client anti-cheat | `client_ragdoll` | +10 | Anti-ragdoll non déclaré |
| Client anti-cheat | `client_spectate` | +30 | Mode spectateur non autorisé |
| Client anti-cheat | `client_tiny_ped` | +40 | Personnage miniature (hitbox réduite) |
| Client anti-cheat | `client_vehicle` | +30 | Véhicule modifié (godmode/boost/vitesse) |
| Client anti-cheat | `client_vision` | +15 | Vision nocturne/thermique non déclarée |
| Client anti-cheat | `client_weapon` | +40 | Arme ou modificateur d'arme interdit (client) |
| Client anti-cheat | `command_injected` | +60 | Commande de menu de triche |
| Client anti-cheat | `heartbeat_tamper` | ban | Réponse anti-cheat falsifiée |
| Client anti-cheat | `heartbeat_timeout` | kick | Module anti-cheat client interrompu |
| Client anti-cheat | `lua_menu` | +100 | Menu Lua de triche détecté (variables globales) |
| Client anti-cheat | `nui_devtools` | +50 | Outils de développement NUI ouverts |
| Client anti-cheat | `resource_injected` | ban | Ressource injectée côté client (exécuteur) |
| Client anti-cheat | `resource_stopped` | ban | Ressource arrêtée côté client (resource stopper) |
| Client anti-cheat | `texture_menu` | +80 | Texture de menu de triche chargée |
| Client anti-cheat | `witness_stop` | +30 | Arrêt de l'anti-cheat signalé par une autre ressource |
| Connexion | `ban_evasion` | ban | Contournement de bannissement |
| Externe | `custom` | +25 | Détection externe (export `Flag`) |

---

## Journaux

- **Console** : chaque détection, avec le joueur, le score et les preuves.
- **Fichiers** : `logs/AAAA-MM-JJ.log`, une ligne JSON par événement (connexions, détections, sanctions, bans et débannissements). Facile à analyser ou à importer.
- **Discord** : quatre canaux (`detections`, `bans`, `admin`, `system`), configurés de préférence par convars (`rempart_webhook_<canal>`) protégées par `add_convar_permission`. Les bans incluent les preuves, la capture d'écran et la trace des derniers événements réseau.

---

## Tests

```bash
./tools/check.sh      # luacheck (0 avertissement attendu) + tous les scénarios
```

Prérequis : `lua5.4` et `luacheck`. Le dossier `tests/` contient un **simulateur FXServer** (ordonnanceur de threads, événements annulables, `source`, KVP, ACE, joueurs, entités, synchro OneSync, ressources et fichiers virtuels). Il charge les vrais fichiers de la ressource selon l'ordre du `fxmanifest.lua`. Les 85 scénarios couvrent :

- SHA-256 / HMAC (vecteurs FIPS 180 et RFC 4231) et les utilitaires ;
- le pipeline de détection : score, décroissance, seuils, mode audit, immunités, bans et contournement par tokens, persistance, commandes ;
- les détections serveur : exécuteur, ressource détournée, explosions, armes, combat, tâches, projectiles, téléportation et apprentissage, godmode avec preuve de combat, modificateurs, invisibilité, réparations ;
- le canal signé : poignée de main, heartbeat, falsification, rejeu, ressources injectées et arrêtées ;
- les pièges : armement, désarmement, ressource démarrée à chaud, usurpation du capteur ; le scanner (Cipher et obfuscation détectés, ox_lib non signalé) ;
- le shield : débit, arguments malformés, `serverOnly`/ACE/distance, quarantaine, intentions, intégration avec l'anti-cheat ; côté client : compteurs d'attestation, menu Lua injecté, soin déclaré ;
- les contre-mesures issues de l'étude des cheats : dégâts forgés, portée du taser, caméra synchronisée, godmode par immunités, taser sans chute, tirs à travers les murs recoupés, semi-godmode, cages créées à distance, ramassables, attestation (appel extérieur détecté, pertes tolérées, apprentissage, code JS/C#, shield mal placé), event blocker, resource blocker, marqueur de ban face à un spoofer, pièges forts/motifs/ressources chiffrées, pièges client, capteur.

> Les tests valident la logique, pas le comportement réel du jeu. Validez toujours sur un serveur de test, puis en mode audit en production.

---

## Limites

Aucun anti-cheat n'est infaillible. Voici ce que Rempart **ne peut pas** faire, ou seulement en partie :

- **Cheats externes ou kernel** (lecture mémoire, DMA, ESP en overlay) : invisibles depuis Lua. L'anti-cheat intégré de Cfx.re (adhesive) s'en charge. Rempart en limite l'impact par les contrôles serveur (portée, angles, cadence, kill aura).
- **ESP / wallhack purement visuels** : ils n'envoient rien au serveur, donc on ne peut pas les détecter côté serveur.
- **Aimbot « humanisé »** : seules des heuristiques s'appliquent (silent aim, cadence, cibles multiples). Un aimbot discret reste difficile à prouver.
- **Falsification de la synchronisation** : les détections d'état s'appuient sur ce que le client synchronise. Un cheat avancé peut masquer certains drapeaux (invincibilité…), d'où le recoupement avec le client et le score cumulatif.
- **Module client** : un exécuteur avancé peut le bloquer, mais son silence se voit (heartbeat ⇒ kick ; détections filtrées ⇒ `client_blocked`).
- **Exécuteur logé dans une ressource protégée** : ses `TriggerServerEvent` passent par le shield de cette ressource et sont donc attestés. Restent les globales de menus, les détections serveur et les pièges. L'attestation vise les exécuteurs en « ressource isolée » et les rejeux de triggers.
- **Captures d'écran** : les cheats récents sont *streamproof* ou bloquent screenshot-basic. Rempart ne fonde aucune sanction sur une capture.
- **Marqueur de ban** : un tricheur qui nettoie entièrement son installation FiveM (KVP + cache NUI) le perd ; il reste alors les identifiants et les tokens.
- **Témoignages « sans ligne de vue »** : heuristique (latence, géométrie) ; ils ne comptent qu'à plusieurs victimes et ne valent qu'un score.
- **Ressources chiffrées (escrow)** : non analysables par le scanner ni par le registre statique d'événements. Elles sont traitées prudemment : aucun piège armé sur leur préfixe, pièges classiques dégradés en score, ressource exclue de l'attestation si son code client est chiffré.
- **Faux positifs** : des scripts qui téléportent, soignent, rendent invisible ou invincible **sans** le shield peuvent déclencher des détections. C'est tout l'intérêt du mode audit et du shield.
- Rempart n'a pas encore été éprouvé sur un serveur en production. Commencez en mode audit, et ajustez les seuils selon vos journaux.

---

## Recherche et références

Rempart s'appuie sur :

- la documentation officielle Cfx.re : [événements serveur](https://docs.fivem.net/docs/scripting-reference/events/server-events/), [interception des événements de jeu OneSync](https://docs.fivem.net/docs/cookbook/2019/08/19/onesync-intercepting-game-events-such-as-explosions/), [sécurisation des événements](https://docs.fivem.net/docs/developers/server-security/), [sandbox](https://docs.fivem.net/docs/developers/sandbox/), [commandes et convars serveur](https://docs.fivem.net/docs/server-manual/server-commands/), [référence des natives](https://docs.fivem.net/natives/) ;
- le [code source de FXServer](https://github.com/citizenfx/fivem) : routage des événements de jeu (`ServerGameState`), dispatch des événements (`ResourceEventComponent`, `EventScriptFunctions`, `ServerEventPacketHandler`), natives serveur (`GetEntityScript`, nœuds de synchro joueur) ;
- les [événements txAdmin](https://github.com/tabarra/txAdmin/blob/master/docs/events.md) et [screenshot-basic](https://github.com/citizenfx/screenshot-basic) ;
- les retours de la communauté : [guide « protect your server »](https://forum.cfx.re/t/how-to-protect-your-server-from-most-cheaters-easily-101/5160816), [conception d'un anti-cheat serveur proactif](https://forum.cfx.re/t/looking-for-community-feedback-designing-a-proactive-server-side-oriented-fivem-anti-cheat/5376605), [protection contre l'injection Lua](https://fiveuxe.com/es/blog/fivem-lua-injection-protection) ;
- l'étude de projets open source ([executor-detection-fivem](https://github.com/kusinkaa/executor-detection-fivem), [Anti-Eulen-Lua-Injection](https://github.com/Szpachlan/Anti-Eulen-Lua-Injection-FiveM), [TigoAntiCheat](https://github.com/ThymonA/TigoAntiCheat), [Icarus Advanced Anticheat](https://github.com/EinS4ckZwiebeln/IcarusAdvancedAnticheat), [SecureServe](https://github.com/peleg-development/SecureServe-AC), [anticheese](https://github.com/Blumlaut/anticheese-anticheat), [Valkyrie](https://github.com/NotSomething0/Valkyrie)) et des backdoors Cipher Panel ([analyse](https://fivesecured.com/guides/fivem-cipher-panel)) ;
- l'étude des cheats en circulation : fonctions annoncées de [redENGINE](https://luamenu.xyz/) (« isolated resource », resource stopper, event logger & blocker, trigger finder, spoofer), d'[Eulen](https://emcheats.com/product/eulen-fivem/) (Lua executor, resource blocker, SHBypass, streamproof), [guide des cheats Eulen/redENGINE/HamMafia](https://www.ravenac.net/blog/eulen-redengine-hammafia-2024-field-guide), [menus visés par HUNK-AC](https://forum.cfx.re/t/hunk-ac-anticheat-anti-eule-n-anti-redengine/4891405) (Phaze, Susano, Lumia, Keyser, TZ…), [liste publique des événements abusés](https://forum.cfx.re/t/how-to-create-an-anti-cheat-list-of-vulnerable-and-abused-events-updated-january-2020/789618) ([gist](https://gist.github.com/d0p3t/1ad255374d68fcc3f252e13015b028cb)) ;
- le code de FXServer pour les détails utilisés par ces contre-mesures : limiteur d'événements réseau (`ServerEventPacketHandler`), nœud de synchro caméra (`CPlayerCameraDataNode`, `GetPlayerCameraRotation`), chargement paresseux des natives Lua (`natives_loader.lua`).
