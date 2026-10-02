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
}
