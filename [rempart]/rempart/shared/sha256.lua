--[[
    Rempart — SHA-256 / HMAC-SHA256 en Lua 5.4 pur.

    Utilisé pour signer le canal client <-> serveur (heartbeat challenge-réponse,
    rapports de détection). Implémentation conforme FIPS 180-4 / RFC 2104,
    vérifiée par les vecteurs de test officiels (voir tests/test_sha256.lua).
]]

local spack, sunpack, srep, sbyte, schar, sformat = string.pack, string.unpack, string.rep, string.byte, string.char, string.format
local tconcat = table.concat

local MASK = 0xffffffff

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function rrot(x, n)
    return ((x >> n) | (x << (32 - n))) & MASK
end

local w = {}

local function compress(H, msg, offset)
    for j = 1, 16 do
        w[j] = sunpack('>I4', msg, offset + (j - 1) * 4)
    end
    for j = 17, 64 do
        local a, b = w[j - 15], w[j - 2]
        local s0 = rrot(a, 7) ~ rrot(a, 18) ~ (a >> 3)
        local s1 = rrot(b, 17) ~ rrot(b, 19) ~ (b >> 10)
        w[j] = (w[j - 16] + s0 + w[j - 7] + s1) & MASK
    end

    local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
    for j = 1, 64 do
        local S1 = rrot(e, 6) ~ rrot(e, 11) ~ rrot(e, 25)
        local ch = (e & f) ~ ((~e) & g)
        local t1 = (h + S1 + ch + K[j] + w[j]) & MASK
        local S0 = rrot(a, 2) ~ rrot(a, 13) ~ rrot(a, 22)
        local maj = (a & b) ~ (a & c) ~ (b & c)
        local t2 = (S0 + maj) & MASK
        h, g, f, e, d, c, b, a = g, f, e, (d + t1) & MASK, c, b, a, (t1 + t2) & MASK
    end

    H[1] = (H[1] + a) & MASK
    H[2] = (H[2] + b) & MASK
    H[3] = (H[3] + c) & MASK
    H[4] = (H[4] + d) & MASK
    H[5] = (H[5] + e) & MASK
    H[6] = (H[6] + f) & MASK
    H[7] = (H[7] + g) & MASK
    H[8] = (H[8] + h) & MASK
end

--- Empreinte SHA-256 binaire (32 octets).
local function digest(msg)
    msg = tostring(msg)
    local len = #msg
    local pad = (64 - ((len + 9) % 64)) % 64
    msg = msg .. '\128' .. srep('\0', pad) .. spack('>I8', len * 8)

    local H = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
    for offset = 1, #msg, 64 do
        compress(H, msg, offset)
    end

    return spack('>I4I4I4I4I4I4I4I4', H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8])
end

local function tohex(bin)
    local out = {}
    for i = 1, #bin do
        out[i] = sformat('%02x', sbyte(bin, i))
    end
    return tconcat(out)
end

local function xorPad(key, byte)
    local out = {}
    for i = 1, 64 do
        out[i] = schar((sbyte(key, i) or 0) ~ byte)
    end
    return tconcat(out)
end

--- HMAC-SHA256 binaire.
local function hmac(key, msg)
    key = tostring(key)
    if #key > 64 then
        key = digest(key)
    end
    return digest(xorPad(key, 0x5c) .. digest(xorPad(key, 0x36) .. tostring(msg)))
end

Sha256 = {
    digest = digest,
    hex = function(msg) return tohex(digest(msg)) end,
    hmac = hmac,
    hmacHex = function(key, msg) return tohex(hmac(key, msg)) end,
    tohex = tohex,
}

return Sha256
