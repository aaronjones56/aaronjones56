--[[
    Modèles interdits au spawn par les clients (entityCreating).

    ⚠ Ne JAMAIS ajouter ici des objets de carte "destructibles" (pompes à essence,
    bonbonnes de propane, barils…) : FXServer les recrée en réseau quand ils
    explosent (CDummyObject) — les bloquer provoque des explosions en boucle.

    Les entités de population (circulation, piétons) ne sont jamais sanctionnées :
    seules les entités créées par script le sont.
]]

Lists = Lists or {}

-- Props utilisés pour faire crasher des clients, encager ou « troller » des joueurs.
Lists.BlacklistedObjects = {
    -- Structures géantes / LOD (crash de rendu)
    'prop_ld_ferris_wheel', 'p_ferris_wheel_amo_l', 'p_ferris_wheel_amo_p', 'prop_ferris_car_01', 'p_ferris_car_01',
    'prop_windmill_01', 'prop_windmill_01_l1', 'p_cablecar_s', 'prop_air_bigradar', 'p_tram_crash_s',
    'p_crahsed_heli_s', 'hei_prop_carrier_jet', 'hei_prop_carrier_cargo_02a',
    'dt1_05_build1_damage', 'dt1_lod_slod3', 'cs4_lod_04_slod2', 'po1_lod_slod4', 'id2_lod_slod4',
    'ap1_lod_slod4', 'sm_lod_slod2_22', 'ce_xr_ctr2', 'csx_seabed_rock3_', 'csx_seabed_bldr4_',
    -- Pistes/rampes de cascade géantes (lancement de véhicules, blocage de zones)
    'stt_prop_stunt_track_start', 'stt_prop_stunt_track_start_02', 'stt_prop_stunt_tube_l',
    'stt_prop_stunt_track_dwuturn', 'stt_prop_stunt_track_uturn', 'stt_prop_stunt_track_turnice',
    'stt_prop_ramp_jump_xxl', 'stt_prop_ramp_spiral_l', 'stt_prop_ramp_spiral_l_l', 'stt_prop_ramp_spiral_l_xxl',
    'stt_prop_ramp_spiral_xxl', 'stt_prop_ramp_multi_loop_rb', 'stt_prop_stunt_bblock_huge_01',
    'stt_prop_stunt_bblock_huge_02', 'stt_prop_stunt_bblock_huge_03', 'stt_prop_stunt_bblock_huge_04',
    'stt_prop_stunt_bblock_huge_05', 'stt_prop_stunt_jump_loop', 'stt_prop_stunt_landing_zone_01',
    'stt_prop_stunt_bowling_ball', 'sr_prop_spec_tube_xxs_01a', 'ar_prop_ar_bblock_huge_01',
    -- Cages et pièges à joueurs
    'prop_gold_cont_01', 'prop_fnclink_05crnr1', 'prop_rub_cage01a', 'prop_container_ld2',
    -- Props « troll » classiques des menus
    'p_spinning_anus_s', 'prop_cs_dildo_01', 'xs_prop_hamburgher_wl', 'xs_prop_plastic_bottle_wl',
    'prop_alien_egg_01', 'p_bloodsplat_s',
}

-- Véhicules militaires armés, volants « fusée » et véhicules Arena War.
-- Retirez ceux que votre serveur propose légitimement (garages, concessionnaires).
Lists.BlacklistedVehicles = {
    -- Blindés et chars
    'rhino', 'khanjali', 'apc', 'halftrack', 'minitank', 'scarab', 'scarab2', 'scarab3', 'chernobog', 'trailersmall2',
    -- Avions / hélicoptères armés et géants
    'hydra', 'lazer', 'strikeforce', 'starling', 'molotok', 'pyro', 'rogue', 'nokota', 'seabreeze',
    'savage', 'hunter', 'akula', 'annihilator2', 'valkyrie', 'valkyrie2',
    'bombushka', 'volatol', 'avenger', 'avenger2', 'avenger3', 'avenger4', 'cargoplane', 'cargoplane2', 'jet',
    'blimp', 'blimp2', 'blimp3', 'kosatka',
    -- Véhicules volants / à roquettes
    'oppressor', 'oppressor2', 'deluxo', 'ruiner2', 'scramjet', 'vigilante', 'thruster', 'stromberg', 'toreador',
    -- Véhicules terrestres armés
    'tampa3', 'dune3', 'dune4', 'dune5', 'technical2', 'technical3', 'insurgent3', 'menacer', 'barrage', 'caracara',
    -- Arena War (armés)
    'deathbike', 'deathbike2', 'deathbike3', 'bruiser', 'bruiser2', 'bruiser3', 'cerberus', 'cerberus2', 'cerberus3',
    'monster3', 'monster4', 'monster5', 'brutus', 'brutus2', 'brutus3', 'dominator4', 'dominator5', 'dominator6',
    'impaler2', 'impaler3', 'impaler4', 'imperator', 'imperator2', 'imperator3', 'issi4', 'issi5', 'issi6',
    'slamvan4', 'slamvan5', 'slamvan6', 'zr380', 'zr3802', 'zr3803',
}

-- Peds interdits au spawn (bêtes géantes, zombies « raid », mascottes troll).
Lists.BlacklistedPeds = {
    'a_c_killerwhale', 'a_c_humpback', 'a_c_sharkhammer', 'a_c_sharktiger', 'a_c_dolphin', 'a_c_stingray',
    'u_m_y_zombie_01', 'u_m_m_jesus_01', 'u_m_y_juggernaut_01', 's_m_y_clown_01', 'u_m_y_imporage',
    'u_m_m_streetart_01', 'u_m_y_pogo_01', 'u_m_y_rsranger_01', 'mp_m_niko_01',
}
