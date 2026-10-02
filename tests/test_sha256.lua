-- Vecteurs officiels FIPS 180-4 (SHA-256) et RFC 4231 (HMAC-SHA256).
local T = dofile('tests/lib/t.lua')
dofile('[rempart]/rempart/shared/sha256.lua')

T.case('sha256 vecteurs FIPS', function()
    T.eq(Sha256.hex(''), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')
    T.eq(Sha256.hex('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
    T.eq(Sha256.hex('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1')
    T.eq(Sha256.hex(string.rep('a', 1000000)), 'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0')
end)

T.case('sha256 longueurs limites de padding', function()
    -- 55, 56, 63, 64 octets : cas limites du remplissage
    T.eq(Sha256.hex(string.rep('a', 55)), '9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318')
    T.eq(Sha256.hex(string.rep('a', 56)), 'b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a')
    T.eq(Sha256.hex(string.rep('a', 64)), 'ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb')
end)

T.case('hmac-sha256 RFC 4231', function()
    -- cas 1
    T.eq(Sha256.hmacHex(string.rep('\x0b', 20), 'Hi There'),
        'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7')
    -- cas 2
    T.eq(Sha256.hmacHex('Jefe', 'what do ya want for nothing?'),
        '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843')
    -- cas 6 : clé > taille de bloc
    T.eq(Sha256.hmacHex(string.rep('\xaa', 131), 'Test Using Larger Than Block-Size Key - Hash Key First'),
        '60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54')
end)

return T.finish()
