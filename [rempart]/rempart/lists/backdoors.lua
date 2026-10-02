--[[
    Signatures du scanner de backdoors (ressources serveur infectées : Cipher Panel,
    loaders distants, vols d'identifiants, exécution de code envoyé par un client…).

    Le scanner décode d'abord les chaînes obfusquées (\x50\x65…, \080\101…, string.char(80,101…))
    puis applique ces signatures sur le texte brut ET sur le texte décodé.

    kind :
      'callback' une API (a) dont le callback passe SON PARAMÈTRE à un "puits" d'exécution (sinks).
                 C'est la signature exacte de Cipher :
                   PerformHttpRequest(url, function(e, d) local s = assert(load(d)) s() end)
                 ou d'une porte dérobée réseau :
                   RegisterNetEvent('x', function(code) load(code)() end)
      'pattern'  motif Lua recherché tel quel
      'near'     deux motifs à moins de `within` caractères
      'decoded'  motif cherché uniquement dans les chaînes décodées (preuve d'obfuscation)
    severity : critical | high | medium | low
]]

Lists = Lists or {}

-- Domaines de panneaux de contrôle de backdoors connus (motifs Lua).
Lists.BackdoorDomains = {
    'cipher%-panel%.me', 'ciphercheats%.com', 'keyx%.club', 'dark%-utilities%.xyz', 'blum%-panel',
    '/_i/i%?to=', 'codexpanel', 'luaxpanel',
}

Lists.BackdoorSignatures = {
    -- Exécution de code téléchargé (Cipher & co.)
    { id = 'http_load', kind = 'callback', severity = 'critical', a = 'PerformHttpRequest',
      sinks = { 'load', 'loadstring', 'assert%s*%(%s*load' },
      desc = 'Code téléchargé puis exécuté (load) — schéma Cipher Panel / loader distant' },
    { id = 'js_http_eval', kind = 'callback', severity = 'critical', a = 'https?%.get',
      sinks = { 'eval', 'new%s+Function', 'Function' },
      desc = 'Code JS téléchargé puis évalué' },

    -- Exécution de code envoyé par un client (exécution à distance)
    { id = 'net_load', kind = 'callback', severity = 'critical', a = 'RegisterNetEvent',
      sinks = { 'load', 'loadstring' },
      desc = 'Événement réseau qui exécute le code reçu d\'un client' },
    { id = 'net_load2', kind = 'callback', severity = 'critical', a = 'RegisterServerEvent',
      sinks = { 'load', 'loadstring' },
      desc = 'Événement réseau qui exécute le code reçu d\'un client' },
    { id = 'net_load3', kind = 'callback', severity = 'critical', a = 'AddEventHandler',
      sinks = { 'load', 'loadstring' },
      desc = 'Gestionnaire d\'événement qui exécute le code reçu' },
    { id = 'net_eval', kind = 'callback', severity = 'critical', a = 'onNet',
      sinks = { 'eval', 'new%s+Function', 'Function' },
      desc = 'Événement réseau JS qui évalue le code reçu d\'un client' },

    -- Vol de secrets du server.cfg
    { id = 'steal_license', kind = 'near', severity = 'critical',
      a = 'sv_licenseKey', b = 'PerformHttpRequest', within = 2000,
      desc = 'Lecture de la clé de licence + requête HTTP (exfiltration probable)' },
    { id = 'steal_rcon', kind = 'near', severity = 'high',
      a = 'rcon_password', b = 'PerformHttpRequest', within = 2000,
      desc = 'Lecture du mot de passe RCON + requête HTTP' },
    { id = 'steal_mysql', kind = 'near', severity = 'high',
      a = 'mysql_connection_string', b = 'PerformHttpRequest', within = 2000,
      desc = 'Lecture de la chaîne de connexion MySQL + requête HTTP' },

    -- API sensibles cachées dans des chaînes obfusquées
    { id = 'hidden_http', kind = 'decoded', severity = 'high', a = 'PerformHttpRequest',
      desc = 'PerformHttpRequest caché dans une chaîne obfusquée' },
    { id = 'hidden_load', kind = 'decoded', severity = 'high', a = '^%s*load%s*$',
      desc = '"load" caché dans une chaîne obfusquée' },
    { id = 'hidden_exec', kind = 'decoded', severity = 'high', a = 'ExecuteCommand',
      desc = 'ExecuteCommand caché dans une chaîne obfusquée' },
    { id = 'hidden_convar', kind = 'decoded', severity = 'high', a = 'GetConvar',
      desc = 'GetConvar caché dans une chaîne obfusquée' },
    { id = 'hidden_handler', kind = 'decoded', severity = 'medium', a = 'AddEventHandler',
      desc = 'AddEventHandler caché dans une chaîne obfusquée' },

    -- Élévation de privilèges / commandes système
    { id = 'ace_escalation', kind = 'pattern', severity = 'medium',
      a = 'ExecuteCommand%s*%(%s*[\'"%[=]*%s*add_principal',
      desc = 'Ajout dynamique d\'un principal ACE (légitime pour certains frameworks, à vérifier)' },
    { id = 'os_execute', kind = 'pattern', severity = 'high', a = 'os%.execute%s*%(',
      desc = 'os.execute (commande système) — aucune ressource de jeu n\'en a besoin' },
    { id = 'io_popen', kind = 'pattern', severity = 'high', a = 'io%.popen%s*%(',
      desc = 'io.popen (commande système)' },
    { id = 'js_child_process', kind = 'pattern', severity = 'high', a = 'child_process',
      desc = 'Node child_process (exécution de commandes système)' },
}
