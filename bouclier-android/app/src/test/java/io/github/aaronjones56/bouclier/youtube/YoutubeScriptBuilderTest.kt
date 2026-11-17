package io.github.aaronjones56.bouclier.youtube

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class YoutubeScriptBuilderTest {

    private val library = ScriptletLibrary.of(
        "2.6.0",
        listOf(
            listOf("set-constant", "set.js", "ubo-set") to "function setConstant(source, args) {}",
            listOf("json-prune", "json-prune.js") to "function jsonPrune(source, args) {}",
        ),
    )

    @Test
    fun findsScriptletsByAlias() {
        assertEquals("set-constant", library.resolve("ubo-set")?.first)
        assertEquals("json-prune", library.resolve("json-prune.js")?.first)
        assertEquals(null, library.resolve("inconnu"))
    }

    @Test
    fun assemblesSeparateScripts() {
        val rules = YoutubeRules(
            scriptlets = listOf(
                ScriptletCall("set-constant", listOf("a", "undefined"), "r1"),
                ScriptletCall("set.js", listOf("b", "true"), "r2"),
                ScriptletCall("inconnu", listOf("x"), "r3"),
            ),
            scripts = listOf("window.raw = 1;"),
            hiddenSelectors = listOf("ytm-rich-item-renderer > ad-slot-renderer"),
        )
        val scripts = YoutubeScriptBuilder.build("/* intégré */", rules, library)
        assertEquals(4, scripts.size)
        assertEquals("/* intégré */", scripts[0])

        val scriptlets = scripts[1]
        assertEquals(1, Regex("function setConstant").findAll(scriptlets).count())
        assertTrue(scriptlets.contains("""run(s0, "set-constant", ["a", "undefined"], "r1");"""))
        assertTrue(scriptlets.contains("""run(s0, "set-constant", ["b", "true"], "r2");"""))
        assertFalse(scriptlets.contains("inconnu"))
        assertTrue(scriptlets.contains("""version: "2.6.0""""))

        assertTrue(scripts[2].contains("window.raw = 1;"))
        assertTrue(scripts[2].startsWith("try {"))
        assertTrue(scripts[3].contains(""""ytm-rich-item-renderer > ad-slot-renderer""""))
    }

    @Test
    fun withoutRulesOnlyTheBuiltInScriptRemains() {
        assertEquals(listOf("intégré"), YoutubeScriptBuilder.build("intégré", YoutubeRules(), library))
    }

    @Test
    fun listValuesStayData() {
        assertEquals("\"a\\\"b\\\\c\\n\\u2028</script>\"", YoutubeScriptBuilder.jsString("a\"b\\c\n\u2028</script>"))
        assertEquals(""""\u0001"""", YoutubeScriptBuilder.jsString("\u0001"))
        val rules = YoutubeRules(scriptlets = listOf(ScriptletCall("set-constant", listOf("x\"); alert(1); (\""), "r")))
        val script = YoutubeScriptBuilder.build("", rules, library)[1]
        assertTrue(script.contains("""["x\"); alert(1); (\""]"""))
    }
}
