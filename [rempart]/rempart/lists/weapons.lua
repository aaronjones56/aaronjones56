--[[
    Armes GTA V regroupées par famille, avec des bornes physiques volontairement
    larges (×2 à ×3 la réalité) pour absorber la latence réseau :
      range : distance max tireur -> victime (m) pour qu'un dégât soit plausible
      rate  : touches max par seconde (les tirs ratés ne génèrent pas d'événement)
      aim   : arme visée (le contrôle d'angle « tir dans le dos » s'applique)
    Les armes inconnues (armes custom, armes de véhicule…) ne sont jamais contrôlées.
]]

Lists = Lists or {}

Lists.WeaponGroups = {
    melee   = { range = 12.0,   rate = 8,  aim = false },
    stungun = { range = 25.0,   rate = 3,  aim = true },   -- portée réelle ≈ 10-12 m
    pistol  = { range = 220.0,  rate = 14, aim = true },
    smg     = { range = 220.0,  rate = 35, aim = true },
    shotgun = { range = 120.0,  rate = 90, aim = true },  -- plombs multiples par tir
    rifle   = { range = 550.0,  rate = 30, aim = true },
    mg      = { range = 550.0,  rate = 35, aim = true },
    sniper  = { range = 1600.0, rate = 6,  aim = true },
    heavy   = { range = 1600.0, rate = 40, aim = false },
    thrown  = { range = 160.0,  rate = 40, aim = false },
}

Lists.Weapons = {
    stungun = { 'WEAPON_STUNGUN', 'WEAPON_STUNGUN_MP' },
    melee = {
        'WEAPON_UNARMED', 'WEAPON_DAGGER', 'WEAPON_BAT', 'WEAPON_BOTTLE', 'WEAPON_CROWBAR', 'WEAPON_FLASHLIGHT',
        'WEAPON_GOLFCLUB', 'WEAPON_HAMMER', 'WEAPON_HATCHET', 'WEAPON_KNUCKLE', 'WEAPON_KNIFE', 'WEAPON_MACHETE',
        'WEAPON_SWITCHBLADE', 'WEAPON_NIGHTSTICK', 'WEAPON_WRENCH', 'WEAPON_BATTLEAXE', 'WEAPON_POOLCUE',
        'WEAPON_STONE_HATCHET', 'WEAPON_CANDYCANE', 'WEAPON_STUNROD',
    },
    pistol = {
        'WEAPON_PISTOL', 'WEAPON_PISTOL_MK2', 'WEAPON_COMBATPISTOL',
        'WEAPON_PISTOL50', 'WEAPON_SNSPISTOL', 'WEAPON_SNSPISTOL_MK2', 'WEAPON_HEAVYPISTOL', 'WEAPON_VINTAGEPISTOL',
        'WEAPON_FLAREGUN', 'WEAPON_MARKSMANPISTOL', 'WEAPON_REVOLVER', 'WEAPON_REVOLVER_MK2', 'WEAPON_DOUBLEACTION',
        'WEAPON_RAYPISTOL', 'WEAPON_CERAMICPISTOL', 'WEAPON_NAVYREVOLVER', 'WEAPON_GADGETPISTOL', 'WEAPON_PISTOLXM3',
    },
    smg = {
        'WEAPON_APPISTOL', 'WEAPON_MACHINEPISTOL', 'WEAPON_MICROSMG', 'WEAPON_SMG', 'WEAPON_SMG_MK2',
        'WEAPON_ASSAULTSMG', 'WEAPON_COMBATPDW', 'WEAPON_MINISMG', 'WEAPON_RAYCARBINE', 'WEAPON_TECPISTOL',
    },
    shotgun = {
        'WEAPON_PUMPSHOTGUN', 'WEAPON_PUMPSHOTGUN_MK2', 'WEAPON_SAWNOFFSHOTGUN', 'WEAPON_ASSAULTSHOTGUN',
        'WEAPON_BULLPUPSHOTGUN', 'WEAPON_MUSKET', 'WEAPON_HEAVYSHOTGUN', 'WEAPON_DBSHOTGUN', 'WEAPON_AUTOSHOTGUN',
        'WEAPON_COMBATSHOTGUN',
    },
    rifle = {
        'WEAPON_ASSAULTRIFLE', 'WEAPON_ASSAULTRIFLE_MK2', 'WEAPON_CARBINERIFLE', 'WEAPON_CARBINERIFLE_MK2',
        'WEAPON_ADVANCEDRIFLE', 'WEAPON_SPECIALCARBINE', 'WEAPON_SPECIALCARBINE_MK2', 'WEAPON_BULLPUPRIFLE',
        'WEAPON_BULLPUPRIFLE_MK2', 'WEAPON_COMPACTRIFLE', 'WEAPON_MILITARYRIFLE', 'WEAPON_HEAVYRIFLE',
        'WEAPON_TACTICALRIFLE', 'WEAPON_BATTLERIFLE',
    },
    mg = {
        'WEAPON_MG', 'WEAPON_COMBATMG', 'WEAPON_COMBATMG_MK2', 'WEAPON_GUSENBERG',
    },
    sniper = {
        'WEAPON_SNIPERRIFLE', 'WEAPON_HEAVYSNIPER', 'WEAPON_HEAVYSNIPER_MK2', 'WEAPON_MARKSMANRIFLE',
        'WEAPON_MARKSMANRIFLE_MK2', 'WEAPON_PRECISIONRIFLE',
    },
    heavy = {
        'WEAPON_RPG', 'WEAPON_GRENADELAUNCHER', 'WEAPON_GRENADELAUNCHER_SMOKE', 'WEAPON_MINIGUN', 'WEAPON_FIREWORK',
        'WEAPON_RAILGUN', 'WEAPON_HOMINGLAUNCHER', 'WEAPON_COMPACTLAUNCHER', 'WEAPON_RAYMINIGUN', 'WEAPON_EMPLAUNCHER',
        'WEAPON_RAILGUNXM3',
    },
    thrown = {
        'WEAPON_GRENADE', 'WEAPON_BZGAS', 'WEAPON_MOLOTOV', 'WEAPON_STICKYBOMB', 'WEAPON_PROXMINE',
        'WEAPON_SNOWBALL', 'WEAPON_PIPEBOMB', 'WEAPON_BALL', 'WEAPON_SMOKEGRENADE', 'WEAPON_FLARE',
        'WEAPON_ACIDPACKAGE',
    },
}

-- Dégâts « environnementaux » : le jeu les applique localement (chute, noyade, saignement…).
-- Un client n'envoie JAMAIS ces armes dans un weaponDamageEvent visant un autre joueur :
-- c'est la signature de menus qui tuent ou plient (« fold ») les joueurs à distance.
-- (WEAPON_FALL apparaît sous deux hashes ; source : Icarus Advanced Anticheat.)
Lists.ForgedDamageWeapons = {
    'WEAPON_FALL', 2725352035, 'WEAPON_DROWNING', 'WEAPON_DROWNING_IN_VEHICLE', 'WEAPON_BLEEDING',
    'WEAPON_EXHAUSTION', 'WEAPON_ELECTRIC_FENCE', 'WEAPON_BARBED_WIRE',
}
-- Fiente d'oiseau : arme réelle (ped oiseau), mais jamais avec des dégâts démesurés.
Lists.BirdCrap = { weapon = 'WEAPON_BIRD_CRAP', maxDamage = 1000 }

-- Armes MK2 : munitions spéciales légitimes (explosives, incendiaires) — exclues du contrôle
-- client du type de dégâts.
Lists.SpecialAmmoWeapons = {
    'WEAPON_PISTOL_MK2', 'WEAPON_SNSPISTOL_MK2', 'WEAPON_REVOLVER_MK2', 'WEAPON_SMG_MK2', 'WEAPON_PUMPSHOTGUN_MK2',
    'WEAPON_ASSAULTRIFLE_MK2', 'WEAPON_CARBINERIFLE_MK2', 'WEAPON_SPECIALCARBINE_MK2', 'WEAPON_BULLPUPRIFLE_MK2',
    'WEAPON_COMBATMG_MK2', 'WEAPON_HEAVYSNIPER_MK2', 'WEAPON_MARKSMANRIFLE_MK2',
}
