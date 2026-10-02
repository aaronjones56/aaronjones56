--[[
    Événements-pièges (honeypots).

    Ces noms correspondent à des événements de vieilles ressources (ESX/vRP de 2018-2021)
    que les menus de triche déclenchent "à l'aveugle" via leurs listes de triggers
    (argent, items, révives, prisons…). Sur un serveur qui N'A PAS ces ressources,
    un client qui les déclenche ne peut être qu'un tricheur.

    Sécurité anti-faux-positif (automatique) :
      • un piège est DÉSARMÉ si une ressource démarrée porte le préfixe de l'événement
        (ex. ressource 'esx_garbagejob' => 'esx_garbagejob:pay' n'est pas un piège) ;
      • un piège est DÉSARMÉ si l'analyse statique trouve un RegisterNetEvent/RegisterServerEvent
        de ce nom dans une ressource du serveur ;
      • un piège déclenché par plusieurs joueurs distincts en peu de temps est désarmé
        et signalé (probable événement légitime d'un script inconnu).
]]

Lists = Lists or {}

Lists.Honeypots = {
    -- Paies de jobs ESX historiques
    'esx_truckerjob:pay', 'esx_godirtyjob:pay', 'esx_ranger:pay', 'esx_pizza:pay', 'esx_garbagejob:pay',
    'esx_garbage:pay', 'esx_postejob:pay', 'esx_carteirojob:pay', 'esx_brinksjob:pay', 'esx_gopostaljob:pay',
    'esx_tankerjob:pay', 'esx_fueldeliver:pay', 'esx_carthief:pay', 'esx_pilot:success', 'esx_taxijob:success',
    'esx_jobs:caution', 'esx_loffe_fangelse:Pay', 'esx_deliveries:AddCashMoney', 'esx_vehicletrunk:giveDirty',
    'esx_mugging:giveMoney', 'esx_robnpc:giveMoney', 'esx_fishing:receiveFish', 'esx_mecanojob:onNPCJobCompleted',
    'esx_mechanicjob:startCraft', 'esx_mechanicjob:startHarvest', 'esx_vangelico_robbery:gioielli1',
    'esx_moneywash:deposit', 'esx_moneywash:withdraw', 'esx_slotmachine:sv:2', 'esx_blanchisseur:startWhitening',
    'esx_mafiajob:confiscatePlayerItem', 'esx_carthief:alertcops',
    -- Drogues ESX
    'esx_drugs:startHarvestWeed', 'esx_drugs:startTransformWeed', 'esx_drugs:startSellWeed',
    'esx_drugs:startHarvestCoke', 'esx_drugs:startTransformCoke', 'esx_drugs:startSellCoke',
    'esx_drugs:startHarvestMeth', 'esx_drugs:startTransformMeth', 'esx_drugs:startSellMeth',
    'esx_drugs:startHarvestOpium', 'esx_drugs:startTransformOpium', 'esx_drugs:startSellOpium',
    'esx_drugs:stopTransformCoke',
    -- Prisons / sanctions forcées sur autrui
    'esx_jailer:sendToJail', 'esx-qalle-jail:jailPlayer', 'esx_jail:sendToJail', 'js:jailuser', 'ljail:jailplayer',
    'esx_policejob:handcuffPasta', 'BsCuff:Cuff696999', 'OG_cuffs:cuffCheckNearest',
    -- Faux menus admin
    'AdminMenu:giveDirtyMoney', 'AdminMenu:giveBank', 'AdminMenu:giveCash', 'adminmenu:setsalary',
    'adminmenu:allowall', 'llotrainer:adminKick', 'hentailover:xdlol', 'NB:recruterplayer',
    'NB:destituerplayer', 'Esx-MenuPessoal:Boss_recruterplayer',
    -- vRP / divers
    'vrp_slotmachine:server:2', 'lscustoms:payGarag', 'lenzh_chopshop:sell', '99kr-burglary:addMoney',
    'napadtransport:graczZrobilnapad', 'tost:zgarnijsiano', 'loffe_prisonwork', 'truckerJob:success',
    'truckerfuel:success', 'mission:completed', 'PayForRepairNow', 'gambling:spend',
    'ambulancier:selfRespawn', 'whoapd:revive', 'paramedic:revive',
    -- Liste publique des événements abusés (gist d0p3t, forum Cfx.re), noms préfixés uniquement
    'eden_garage:payhealth', 'esx_ambulancejob:revive', 'esx_ambulancejob:setDeathStatus', 'esx_billing:sendBill',
    'esx_banksecurity:pay', 'esx_dmvschool:addLicense', 'esx_dmvschool:pay', 'esx_drugs:stopHarvestCoke',
    'esx_drugs:stopSellCoke', 'esx_drugs:stopHarvestMeth', 'esx_drugs:stopTransformMeth', 'esx_drugs:stopSellMeth',
    'esx_drugs:stopHarvestWeed', 'esx_drugs:stopTransformWeed', 'esx_drugs:stopSellWeed', 'esx_drugs:stopHarvestOpium',
    'esx_drugs:stopTransformOpium', 'esx_drugs:stopSellOpium', 'esx:enterpolicecar', 'esx_fueldelivery:pay',
    'esx:giveInventoryItem', 'esx:removeInventoryItem', 'esx_handcuffs:cuffing', 'esx_jail:unjailQuest',
    'esx_jailer:unjailTime', 'esx_policejob:handcuff', 'esx_policejob:requestarrest', 'esx-qalle-jail:jailPlayerNew',
    'esx-qalle-hunting:reward', 'esx-qalle-hunting:sell', 'esx_skin:responseSaveSkin', 'esx_society:getOnlinePlayers',
    'esx_society:setJob', 'esx_vehicleshop:setVehicleOwned', 'js:removejailtime', 'LegacyFuel:PayFuel',
    'lscustoms:payGarage', 'mellotrainer:adminTempBan', 'mellotrainer:adminKick', 'mellotrainer:s_adminKill',
}

-- Pièges « forts » : noms qu'aucun script légitime n'utilise (chaînes aléatoires de menus,
-- événements d'anciens anti-cheats que les menus déclenchent pour se désactiver, faux menus
-- admin). Toujours sanctionnés par un ban, même si le serveur contient des ressources chiffrées.
Lists.HoneypotsStrong = {
    '8321hiue89js', 'Tem2LPs5Para5dCyjuHm87y2catFkMpV', 'dqd36JWLRC72k8FDttZ5adUKwvwq9n9m', 'h:xd',
    'hentailover:xdlol', 'HCheat:TempDisableDetection',
    'antilynx8:anticheat', 'antilynxr4:detect', 'antilynxr6:detection', 'ynx8:anticheat', 'antilynx8r4a:anticheat',
    'lynx8:anticheat', 'AntiLynxR4:kick', 'AntiLynxR4:log',
    'AdminMenu:giveDirtyMoney', 'AdminMenu:giveBank', 'AdminMenu:giveCash', 'adminmenu:setsalary',
    'adminmenu:allowall', 'adminmenu:cashoutall',
}

-- Motifs : certains menus insèrent « DFWM » dans leurs noms de triggers (esx_pizza:pDFWMay…)
-- pour échapper aux listes ; un événement INEXISTANT qui contient ce motif est un piège fort.
Lists.HoneypotPatterns = { 'DFWM' }
