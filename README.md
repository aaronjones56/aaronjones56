# 🛡️ Rempart — anti-cheat FiveM serveur-autoritaire

> **Le serveur est la seule source de vérité.** Le client signale ; le serveur recoupe, prouve et décide.

Rempart est un anti-cheat complet pour serveurs FiveM avec OneSync. Il a été conçu à partir de la documentation officielle Cfx.re, du **code source de FXServer** et de l'étude des anti-cheats, des menus de triche et des backdoors existants. Il ne compte ni sur le secret ni sur l'obfuscation. Sa force vient de contrôles que le tricheur **ne peut pas désactiver**, parce qu'ils ne tournent pas sur sa machine.

| | |
|---|---|
| 🧠 **Serveur-autoritaire** | **50 détections exécutées sur le serveur**, à partir des données de synchronisation OneSync et des événements de jeu que FXServer route (et qui peuvent être **annulés avant d'atteindre les autres joueurs**). |
| 🧱 **Pare-feu d'événements** | Un *shield* **bloquant** à inclure dans vos ressources (débit, arguments malformés, ACE, distance, `serverOnly`, quarantaine). S'y ajoute un **capteur global** qui voit tous les événements réseau grâce à l'abonnement joker `*`. |
| 🔐 **Client signé** | Un canal HMAC-SHA256 avec clé de session, anti-rejeu et heartbeat à défi. Un client anti-cheat arrêté, bloqué ou falsifié est démasqué. |
| 🎯 **Pas de ban sur un faux positif isolé** | Score de risque qui décroît avec le temps, déclarations d'intention des scripts légitimes, apprentissage automatique, preuves de comportement, mode audit. |
| 🔨 **Bans difficiles à contourner** | Tous les identifiants + tokens matériels, extension automatique en cas de contournement. Stockage KVP ou MySQL (bans partagés entre plusieurs serveurs). |
| 🩺 **Sécurité du serveur** | Audit des convars de sécurité Cfx.re et scanner de backdoors (Cipher Panel & co.) au démarrage. |

Aucune dépendance obligatoire (screenshot-basic et oxmysql sont facultatifs). Lua 5.4. Vérifié par **65 scénarios automatisés** sur un simulateur FXServer inclus, et par `luacheck` (0 avertissement).

---

## Sommaire

1. [Principe](#principe)
2. [Fonctionnalités](#fonctionnalités)
3. [Installation](#installation)
4. [Le shield : protéger vos ressources](#le-shield--protéger-vos-ressources)
5. [Configuration](#configuration)
6. [Commandes d'administration](#commandes-dadministration)
7. [API pour vos scripts](#api-pour-vos-scripts)
8. [Catalogue des détections](#catalogue-des-détections)
9. [Journaux](#journaux)
10. [Tests](#tests)
11. [Limites](#limites)
12. [Recherche et références](#recherche-et-références)

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
 TriggerServerEvent ──┬──────────────────────▶  rempart_sensor (joker *) : observe ───┤
                      └──────────────────────▶  shield (vos ressources) : bloque ─────┤
 client Rempart ─── HMAC-SHA256 + heartbeat ─▶  canal signé ──────────────────────────┤
                                                                                      ▼
                         Detect ─▶ immunités ─▶ score (décroissance) ─▶ logs / Discord
                                ─▶ quarantaine ─▶ capture d'écran ─▶ kick / ban (ids + HWID)
```

---

## Fonctionnalités

### Détections serveur (OneSync)

| Module | Source | Ce qui est détecté ou bloqué |
|---|---|---|
| **Entités** | `entityCreating` + `GetEntityScript` | **Exécuteurs Lua** : entité créée par un script qui n'existe pas sur le serveur (le thread d'une ressource cliente porte le hash `joaat(nom)` de la ressource). Ressources détournées (`chat`, `spawnmanager`… qui ne créent jamais d'entités). Modèles interdits (props de crash, cages, véhicules militaires). Spam de spawn. Objets attachés à un autre joueur. |
| **Explosions** | `explosionEvent` | Types interdits (canon orbital, bombes…), spam, explosion **attribuée à un autre joueur** (blame), explosions à distance, invisibles, silencieuses ou amplifiées. |
| **Armes** | `giveWeaponEvent`, `removeWeaponEvent`, `removeAllWeaponsEvent` | « Give/remove weapons all » sur d'autres joueurs (ces événements ne sont émis que pour un ped que le client ne possède pas). Armes interdites en main, retirées par le serveur. |
| **Combat** | `weaponDamageEvent` (annulable) | Portée impossible, dégâts à travers les dimensions, **silent aim** (cible derrière le tireur), cadence impossible, **kill aura** (nombreuses cibles en 2 s), dégâts forcés. |
| **Effets** | `ptFxEvent`, `fireEvent`, `startProjectileEvent` | Particules interdites, géantes ou en rafale ; feux sur les joueurs ; projectiles « magic bullet ». |
| **Tâches** | `clearPedTasksEvent`, `givePedScriptedTaskEvent` | Éjection de véhicule, gel ou animation forcée sur un autre joueur. |
| **Mouvement** | positions synchronisées | Téléportation non déclarée (avec **apprentissage** des points légitimes), vitesse à pied impossible, noclip (collisions coupées ou position gelée en mouvement). |
| **État du joueur** | nœuds de synchro OneSync | Godmode (`GetPlayerInvincible`, avec preuve de combat), super saut, **multiplicateurs de dégâts/défense**, santé ou armure au-delà du maximum, invisibilité en mouvement, caméra libre éloignée, ped interdit, boost de traînée aérodynamique. |
| **Véhicules** | synchro véhicule | Santé au-delà du maximum, réparations non déclarées (`GetVehicleTotalRepairs`). |
| **Connexion** | `playerConnecting` | Bans (identifiants + tokens matériels), contournements, pseudos malveillants (HTML, caractères invisibles), flood de reconnexion, VPN (facultatif, proxycheck.io). |

### Événements réseau

- **Capteur global** (`rempart_sensor`) : il s'abonne au joker `*` de FXServer et voit **tous** les événements envoyés par les clients, même ceux qu'aucune ressource n'écoute. C'est exactement ce que font les menus avec leurs listes de « triggers ». Il signale les pièges, les floods, les rafales d'événements distincts (« trigger all »), les charges démesurées et les événements inexistants. Il garde aussi les 40 derniers événements de chaque joueur (trace jointe aux bans). Il ne fait qu'observer et vit dans sa propre ressource pour ne jamais perturber les autres.
- **Pièges (honeypots)** : 78 événements de vieux scripts ESX/vRP visés par les menus. Un piège n'est armé **que si l'événement n'existe pas** sur votre serveur. Rempart vérifie pour cela l'analyse statique de vos scripts, les préfixes de ressources et les ressources chiffrées, et revérifie au moment du déclenchement. Un piège se désarme tout seul si plusieurs joueurs distincts le déclenchent.
- **Shield** : pare-feu **bloquant** inclus dans vos ressources ([voir plus bas](#le-shield--protéger-vos-ressources)).

### Client anti-cheat

- **Canal signé HMAC-SHA256** (clé de session aléatoire de 256 bits, séquence anti-rejeu) et **heartbeat à défi** toutes les 15 s. Client absent ou muet ⇒ kick (jamais de ban : une connexion instable ne doit bannir personne). Réponse falsifiée ⇒ ban.
- **Ressources injectées** (inconnues du serveur) et **resource stoppers**. Un arrêt local n'est sanctionné que si le serveur le reconfirme 10 s plus tard, jamais à la déconnexion.
- Commandes et **textures de menus connus**, et commandes enregistrées par une ressource inconnue.
- Godmode, spectateur, invisibilité, noclip/vol, caméra libre, visions, ped miniature, anti-ragdoll, armes et modificateurs de dégâts, véhicule indestructible, boosté ou trop rapide.
- **DevTools NUI** (piège `debugger`) : bloque l'appel direct des callbacks NUI de vos inventaires et banques avec des données forgées.
- La configuration est envoyée par le serveur à l'exécution : le cache du client ne contient rien d'exploitable (ni seuils, ni webhooks).

### Contre les faux positifs

- **Score de risque** : demi-vie de 10 min ; seuils alerte 30 / kick 70 / ban 100. Une même détection répétée compte de moins en moins (×0,5, ×0,25…). Le score survit 1 h à une reconnexion.
- **Déclarations d'intention** : le shield voit quand **vos** scripts téléportent le joueur, le rendent invisible ou invincible, activent une caméra, le mode spectateur, réparent un véhicule… L'anti-cheat ne les confond donc pas avec un tricheur. Un exécuteur qui appelle les natives directement ne déclare rien et reste détecté.
- **Apprentissage** : un point de téléportation utilisé par plusieurs joueurs distincts (ascenseur, intérieur, garage) est validé automatiquement. Les pièges et les événements « inconnus » sont désarmés de la même façon.
- **Preuves de comportement** : un joueur invincible et immobile (script de mort, zone safe) n'est pas en godmode ; il faut qu'il soit en combat.
- **Périodes de grâce** à l'apparition, à la réanimation, aux changements de ped et de dimension.
- **Immunités** : ACE `rempart.bypass` (globale, par détection ou par catégorie), admins txAdmin authentifiés (noclip/god du menu txAdmin), exemptions temporaires.
- **Mode audit** : tout est détecté et journalisé, rien n'est sanctionné.

### Sanctions et bans

- Kick ou ban avec un message clair (identifiant du ban, lien de contestation). **Capture d'écran** préalable si screenshot-basic est présent. **Quarantaine** du joueur pendant la procédure : les shields bloquent tous ses événements.
- Bans sur **tous les identifiants** et les **tokens matériels** (`GetPlayerTokens`). En cas de contournement, les nouveaux identifiants rejoignent le ban.
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

Ajoutez **une ligne, en premier**, dans le `fxmanifest.lua` de vos ressources, en priorité celles qui gèrent l'argent, les objets, les jobs, les téléportations, les caméras ou l'invisibilité :

```lua
shared_script '@rempart/shield.lua'   -- adaptez le nom si vous avez renommé la ressource
```

Le shield est passif tant que l'anti-cheat n'est pas démarré. Chaque appel est protégé : il ne peut pas casser la ressource qui l'inclut.

**Côté serveur, il crée un pare-feu bloquant.** Avant que votre gestionnaire d'événement ne s'exécute, chaque appel venu d'un client est vérifié :

- débit par joueur et par événement (règles par défaut et règles personnalisées) ;
- arguments malformés : `NaN`, infini, nombres démesurés, chaînes géantes, tables trop profondes ou trop volumineuses ;
- règles déclaratives : `serverOnly`, `ace`, distance (`near`/`radius`), débit (`rate`/`per`) ;
- quarantaine : un joueur en cours de sanction ne peut plus rien déclencher.

Les intentions des scripts serveur (`SetEntityCoords`, `FreezeEntityPosition`, `SetPlayerInvincible`, `GiveWeaponToPed` sur un joueur) sont signalées comme légitimes.

**Côté client, il déclare les intentions.** Quand votre script téléporte le joueur, le rend invisible ou invincible, coupe ses collisions, le gèle, active une caméra scriptée, le mode spectateur ou une vision, répare ou booste son véhicule… l'anti-cheat est prévenu et ne le confond pas avec un tricheur.

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

Types : `tp`, `invisible`, `invincible`, `collision`, `frozen`, `camera`, `spectate`, `vision`, `ragdoll`, `superjump`, `vehiclegod`, `vehiclepower`, `repair`.

---

## Catalogue des détections

« +N » = points ajoutés au score de risque (alerte 30, kick 70, ban 100). `ban` / `kick` = sanction immédiate. Toutes les valeurs se règlent dans `Config.Detections`.

| Catégorie | Identifiant | Défaut | Description |
|---|---|---|---|
| Entités | `entity_attach_player` | +40 | Objet attaché à un autre joueur |
| Entités | `entity_blacklisted` | +50 | Spawn d'un modèle interdit |
| Entités | `entity_forbidden_res` | +80 | Entité créée depuis une ressource détournée |
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
| Combat | `combat_distance` | +25 | Dégâts à une distance impossible |
| Combat | `combat_multitarget` | +45 | Touches simultanées sur de nombreuses cibles (kill aura) |
| Combat | `combat_override` | +40 | Dégâts forcés anormaux |
| Combat | `combat_rate` | +35 | Cadence de tir impossible |
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
| État du joueur | `health_overflow` | +50 | Santé ou armure au-delà du maximum |
| État du joueur | `invisible` | +30 | Invisibilité en mouvement |
| État du joueur | `ped_blacklisted` | +50 | Modèle de personnage interdit |
| État du joueur | `superjump` | +50 | Super saut |
| Véhicules | `vehicle_health` | +30 | Santé de véhicule au-delà du maximum |
| Véhicules | `vehicle_repair` | +5 | Réparation de véhicule non déclarée |
| Événements réseau | `event_burst` | +35 | Rafale d'événements distincts (trigger all) |
| Événements réseau | `event_firewall` | +20 | Règle du pare-feu d'événements violée |
| Événements réseau | `event_flood` | +40 | Flood d'événements réseau |
| Événements réseau | `event_honeypot` | ban | Événement-piège déclenché |
| Événements réseau | `event_malformed` | +30 | Arguments d'événement malformés |
| Événements réseau | `event_payload` | +25 | Événement réseau démesuré |
| Événements réseau | `event_unknown` | +3 | Événements inexistants déclenchés |
| Client anti-cheat | `client_freecam` | +10 | Caméra libre (client) |
| Client anti-cheat | `client_godmode` | +35 | Invincibilité (client) |
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

Prérequis : `lua5.4` et `luacheck`. Le dossier `tests/` contient un **simulateur FXServer** (ordonnanceur de threads, événements annulables, `source`, KVP, ACE, joueurs, entités, synchro OneSync, ressources et fichiers virtuels). Il charge les vrais fichiers de la ressource selon l'ordre du `fxmanifest.lua`. Les 65 scénarios couvrent :

- SHA-256 / HMAC (vecteurs FIPS 180 et RFC 4231) et les utilitaires ;
- le pipeline de détection : score, décroissance, seuils, mode audit, immunités, bans et contournement par tokens, persistance, commandes ;
- les détections serveur : exécuteur, ressource détournée, explosions, armes, combat, tâches, projectiles, téléportation et apprentissage, godmode avec preuve de combat, modificateurs, invisibilité, réparations ;
- le canal signé : poignée de main, heartbeat, falsification, rejeu, ressources injectées et arrêtées ;
- les pièges : armement, désarmement, ressource démarrée à chaud, usurpation du capteur ; le scanner (Cipher et obfuscation détectés, ox_lib non signalé) ;
- le shield : débit, arguments malformés, `serverOnly`/ACE/distance, quarantaine, intentions, intégration avec l'anti-cheat.

> Les tests valident la logique, pas le comportement réel du jeu. Validez toujours sur un serveur de test, puis en mode audit en production.

---

## Limites

Aucun anti-cheat n'est infaillible. Voici ce que Rempart **ne peut pas** faire, ou seulement en partie :

- **Cheats externes ou kernel** (lecture mémoire, DMA, ESP en overlay) : invisibles depuis Lua. L'anti-cheat intégré de Cfx.re (adhesive) s'en charge. Rempart en limite l'impact par les contrôles serveur (portée, angles, cadence, kill aura).
- **ESP / wallhack purement visuels** : ils n'envoient rien au serveur, donc on ne peut pas les détecter côté serveur.
- **Aimbot « humanisé »** : seules des heuristiques s'appliquent (silent aim, cadence, cibles multiples). Un aimbot discret reste difficile à prouver.
- **Falsification de la synchronisation** : les détections d'état s'appuient sur ce que le client synchronise. Un cheat avancé peut masquer certains drapeaux (invincibilité…), d'où le recoupement avec le client et le score cumulatif.
- **Module client** : un exécuteur avancé peut le bloquer, mais son silence se voit (heartbeat ⇒ kick).
- **Ressources chiffrées (escrow)** : non analysables par le scanner ni par le registre statique d'événements. Elles sont traitées prudemment (aucun piège armé sur leur préfixe).
- **Faux positifs** : des scripts qui téléportent, rendent invisible ou invincible **sans** le shield peuvent déclencher des détections. C'est tout l'intérêt du mode audit et du shield.
- Rempart n'a pas encore été éprouvé sur un serveur en production. Commencez en mode audit, et ajustez les seuils selon vos journaux.

---

## Recherche et références

Rempart s'appuie sur :

- la documentation officielle Cfx.re : [événements serveur](https://docs.fivem.net/docs/scripting-reference/events/server-events/), [interception des événements de jeu OneSync](https://docs.fivem.net/docs/cookbook/2019/08/19/onesync-intercepting-game-events-such-as-explosions/), [sécurisation des événements](https://docs.fivem.net/docs/developers/server-security/), [sandbox](https://docs.fivem.net/docs/developers/sandbox/), [commandes et convars serveur](https://docs.fivem.net/docs/server-manual/server-commands/), [référence des natives](https://docs.fivem.net/natives/) ;
- le [code source de FXServer](https://github.com/citizenfx/fivem) : routage des événements de jeu (`ServerGameState`), dispatch des événements (`ResourceEventComponent`, `EventScriptFunctions`, `ServerEventPacketHandler`), natives serveur (`GetEntityScript`, nœuds de synchro joueur) ;
- les [événements txAdmin](https://github.com/tabarra/txAdmin/blob/master/docs/events.md) et [screenshot-basic](https://github.com/citizenfx/screenshot-basic) ;
- les retours de la communauté : [guide « protect your server »](https://forum.cfx.re/t/how-to-protect-your-server-from-most-cheaters-easily-101/5160816), [conception d'un anti-cheat serveur proactif](https://forum.cfx.re/t/looking-for-community-feedback-designing-a-proactive-server-side-oriented-fivem-anti-cheat/5376605), [protection contre l'injection Lua](https://fiveuxe.com/es/blog/fivem-lua-injection-protection) ;
- l'étude de projets open source ([executor-detection-fivem](https://github.com/kusinkaa/executor-detection-fivem), [Anti-Eulen-Lua-Injection](https://github.com/Szpachlan/Anti-Eulen-Lua-Injection-FiveM), [TigoAntiCheat](https://github.com/ThymonA/TigoAntiCheat)) et des backdoors Cipher Panel ([analyse](https://fivesecured.com/guides/fivem-cipher-panel)).
