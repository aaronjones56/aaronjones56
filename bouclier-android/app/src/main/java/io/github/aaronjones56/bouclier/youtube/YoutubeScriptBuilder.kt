package io.github.aaronjones56.bouclier.youtube

/**
 * Fonctions de la bibliothèque AdGuard Scriptlets (celles qu'exécutent les extensions et les
 * applications d'AdGuard), retrouvables par tous leurs noms : AdGuard, uBlock Origin…
 */
class ScriptletLibrary private constructor(
    val version: String,
    /** Nom ou alias → nom principal et code de la fonction. */
    private val functions: Map<String, Pair<String, String>>,
) {
    fun resolve(name: String): Pair<String, String>? = functions[name]

    companion object {
        /** [entries] : pour chaque fonction, ses noms (le premier est le principal) et son code. */
        fun of(version: String, entries: List<Pair<List<String>, String>>): ScriptletLibrary {
            val functions = HashMap<String, Pair<String, String>>()
            for ((names, code) in entries) {
                val main = names.firstOrNull() ?: continue
                for (name in names) functions.putIfAbsent(name, main to code)
            }
            return ScriptletLibrary(version, functions)
        }
    }
}

/**
 * Assemble les scripts injectés dans le lecteur YouTube, dans l'ordre :
 * les protections intégrées, les scriptlets des listes, le JavaScript des listes de confiance,
 * puis le masquage CSS. Chaque script est injecté séparément : une erreur dans l'un n'empêche
 * pas les autres de fonctionner.
 */
object YoutubeScriptBuilder {

    fun build(builtIn: String, rules: YoutubeRules, library: ScriptletLibrary): List<String> {
        val scripts = mutableListOf(builtIn)
        scriptletScript(rules.scriptlets, library)?.let { scripts += it }
        rules.scripts.forEach { scripts += "try {\n$it\n} catch (e) {\n  // règle défaillante : ignorée\n}\n" }
        cssScript(rules.hiddenSelectors)?.let { scripts += it }
        return scripts
    }

    private fun scriptletScript(calls: List<ScriptletCall>, library: ScriptletLibrary): String? {
        val resolved = calls.mapNotNull { call -> library.resolve(call.name)?.let { (main, code) -> Triple(main, code, call) } }
        if (resolved.isEmpty()) return null
        val script = StringBuilder()
        script.append("/* Règles des listes AdGuard et uBlock Origin, exécutées par AdGuard Scriptlets ")
            .append(library.version.replace("*/", "")).append(" (GPL-3.0). */\n")
        script.append("(function () {\n")
        script.append("  function run(scriptlet, name, args, ruleText) {\n")
        script.append("    try {\n")
        script.append("      scriptlet({ name: name, args: args, engine: 'extension', version: ")
            .append(jsString(library.version))
            .append(", verbose: false, ruleText: ruleText, domainName: location.hostname, uniqueId: 'bouclier' }, args);\n")
        script.append("    } catch (e) {\n      // une règle défaillante n'empêche pas les suivantes\n    }\n")
        script.append("  }\n")
        val variables = LinkedHashMap<String, String>()
        for ((main, code, _) in resolved) {
            if (main in variables) continue
            val variable = "s${variables.size}"
            variables[main] = variable
            script.append("  var ").append(variable).append(" = ").append(code).append(";\n")
        }
        for ((main, _, call) in resolved) {
            script.append("  run(").append(variables.getValue(main)).append(", ").append(jsString(main)).append(", ")
                .append(jsArray(call.args)).append(", ").append(jsString(call.ruleText)).append(");\n")
        }
        script.append("})();\n")
        return script.toString()
    }

    private fun cssScript(selectors: List<String>): String? {
        if (selectors.isEmpty()) return null
        return """
            (function () {
              var selectors = ${jsArray(selectors)};
              function apply() {
                var root = document.head || document.documentElement;
                if (!root) return false;
                var style = document.createElement('style');
                style.id = 'bouclier-rules';
                root.appendChild(style);
                for (var i = 0; i < selectors.length; i++) {
                  try {
                    style.sheet.insertRule(selectors[i] + ' { display: none !important; }', style.sheet.cssRules.length);
                  } catch (e) {
                    // sélecteur non reconnu par ce navigateur : ignoré
                  }
                }
                return true;
              }
              if (!apply()) document.addEventListener('DOMContentLoaded', apply, { once: true });
            })();
        """.trimIndent() + "\n"
    }

    private fun jsArray(values: List<String>): String = values.joinToString(", ", "[", "]") { jsString(it) }

    /** Chaîne JavaScript entre guillemets : toute valeur venue d'une liste y reste une simple donnée. */
    internal fun jsString(value: String): String {
        val result = StringBuilder(value.length + 2).append('"')
        for (c in value) {
            when (c) {
                '\\' -> result.append("\\\\")
                '"' -> result.append("\\\"")
                '\n' -> result.append("\\n")
                '\r' -> result.append("\\r")
                '\t' -> result.append("\\t")
                '\u2028' -> result.append("\\u2028")
                '\u2029' -> result.append("\\u2029")
                else -> if (c < ' ') result.append(String.format("\\u%04x", c.code)) else result.append(c)
            }
        }
        return result.append('"').toString()
    }
}
