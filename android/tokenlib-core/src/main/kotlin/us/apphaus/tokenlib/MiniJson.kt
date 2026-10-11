/*
 * MiniJson.kt
 * TokenLib
 *
 * A small JSON reader and writer over Map/List/String/Number/Boolean so the
 * core has no serialization dependency. Providers only need flat request
 * bodies and a few fields out of streamed events.
 */
package us.apphaus.tokenlib

object MiniJson {
    fun stringify(value: Any?): String = StringBuilder().also { write(value, it) }.toString()

    private fun write(value: Any?, out: StringBuilder) {
        when (value) {
            null -> out.append("null")
            is String -> quote(value, out)
            is Boolean -> out.append(value)
            is Int, is Long -> out.append(value)
            is Number -> { val d = value.toDouble(); if (d == Math.rint(d) && Math.abs(d) < 1e15) out.append(d.toLong()) else out.append(d) }
            is Map<*, *> -> {
                out.append('{')
                var first = true
                for ((k, v) in value.entries.sortedBy { it.key.toString() }) { if (!first) out.append(','); first = false; quote(k.toString(), out); out.append(':'); write(v, out) }
                out.append('}')
            }
            is Iterable<*> -> { out.append('['); var first = true; for (v in value) { if (!first) out.append(','); first = false; write(v, out) }; out.append(']') }
            else -> quote(value.toString(), out)
        }
    }

    private fun quote(s: String, out: StringBuilder) {
        out.append('"')
        for (c in s) when (c) {
            '"' -> out.append("\\\""); '\\' -> out.append("\\\\"); '\n' -> out.append("\\n"); '\r' -> out.append("\\r"); '\t' -> out.append("\\t")
            else -> if (c < ' ') out.append(String.format("\\u%04x", c.code)) else out.append(c)
        }
        out.append('"')
    }

    /** Parses JSON into Map / List / String / Double / Boolean / null; returns null for invalid text. */
    fun parse(text: String): Any? = runCatching { Reader(text).run { val v = value(); skip(); if (i != s.length) throw IllegalArgumentException("trailing"); v } }.getOrNull()

    private class Reader(val s: String) {
        var i = 0
        fun skip() { while (i < s.length && s[i].isWhitespace()) i++ }
        fun value(): Any? {
            skip()
            if (i >= s.length) throw IllegalArgumentException("eof")
            return when (s[i]) {
                '{' -> obj(); '[' -> arr(); '"' -> str()
                't' -> lit("true", true); 'f' -> lit("false", false); 'n' -> lit("null", null)
                else -> num()
            }
        }
        fun lit(word: String, v: Any?): Any? { if (!s.startsWith(word, i)) throw IllegalArgumentException("literal"); i += word.length; return v }
        fun obj(): Map<String, Any?> {
            val m = LinkedHashMap<String, Any?>(); i++; skip()
            if (s[i] == '}') { i++; return m }
            while (true) {
                skip(); val k = str(); skip(); if (s[i] != ':') throw IllegalArgumentException(":"); i++
                m[k] = value(); skip()
                when (s[i]) { ',' -> i++; '}' -> { i++; return m }; else -> throw IllegalArgumentException("obj") }
            }
        }
        fun arr(): List<Any?> {
            val l = ArrayList<Any?>(); i++; skip()
            if (s[i] == ']') { i++; return l }
            while (true) {
                l += value(); skip()
                when (s[i]) { ',' -> i++; ']' -> { i++; return l }; else -> throw IllegalArgumentException("arr") }
            }
        }
        fun str(): String {
            if (s[i] != '"') throw IllegalArgumentException("string"); i++
            val b = StringBuilder()
            while (true) {
                val c = s[i++]
                when (c) {
                    '"' -> return b.toString()
                    '\\' -> when (val e = s[i++]) {
                        'n' -> b.append('\n'); 'r' -> b.append('\r'); 't' -> b.append('\t'); 'b' -> b.append('\b'); 'f' -> b.append('\u000C')
                        'u' -> { b.append(s.substring(i, i + 4).toInt(16).toChar()); i += 4 }
                        else -> b.append(e)
                    }
                    else -> b.append(c)
                }
            }
        }
        fun num(): Double {
            val start = i
            while (i < s.length && (s[i].isDigit() || s[i] in "+-.eE")) i++
            return s.substring(start, i).toDoubleOrNull() ?: throw IllegalArgumentException("number")
        }
    }
}

// Typed accessors for parsed JSON.
internal fun Any?.obj(key: String): Map<String, Any?>? = (this as? Map<*, *>)?.get(key) as? Map<String, Any?>
internal fun Any?.str(key: String): String? = (this as? Map<*, *>)?.get(key) as? String
internal fun Any?.int(key: String): Int? = ((this as? Map<*, *>)?.get(key) as? Number)?.toInt()
internal fun Any?.list(key: String): List<Any?>? = (this as? Map<*, *>)?.get(key) as? List<Any?>
