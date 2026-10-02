-- Mini framework de tests (aucune dépendance).
local T = { passed = 0, failed = 0, current = '?' }

local function fmt(v)
    if type(v) == 'string' then return string.format('%q', v) end
    return tostring(v)
end

function T.case(name, fn)
    T.current = name
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        T.passed = T.passed + 1
        print(('  \27[32mOK\27[0m   %s'):format(name))
    else
        T.failed = T.failed + 1
        print(('  \27[31mFAIL\27[0m %s\n%s'):format(name, err))
    end
end

function T.eq(actual, expected, msg)
    if actual ~= expected then
        error(('%s attendu=%s obtenu=%s'):format(msg or 'égalité', fmt(expected), fmt(actual)), 2)
    end
end

function T.ok(cond, msg)
    if not cond then error(msg or 'assertion échouée', 2) end
end

function T.near(a, b, eps, msg)
    if math.abs(a - b) > (eps or 1e-6) then
        error(('%s attendu≈%s obtenu=%s'):format(msg or 'proximité', tostring(b), tostring(a)), 2)
    end
end

function T.finish()
    print(('  -> %d réussi(s), %d échec(s)'):format(T.passed, T.failed))
    return T.failed == 0
end

return T
