/*
 * Store.kt
 * TokenLib
 *
 * The repository pattern: keys, settings and usage behind small interfaces,
 * with an in-memory store for tests and a SQLite store for apps. Keys are
 * stored as ciphertext; the cipher (Keystore, Keychain) is the platform's.
 */
package us.apphaus.tokenlib

/** Encrypts API keys at rest. Apps supply a platform cipher; `PlainCipher` is for tests only. */
interface SecretCipher {
    fun encrypt(plaintext: ByteArray): ByteArray
    fun decrypt(ciphertext: ByteArray): ByteArray
}

object PlainCipher : SecretCipher {
    override fun encrypt(plaintext: ByteArray) = plaintext
    override fun decrypt(ciphertext: ByteArray) = ciphertext
}

interface KeyRepository {
    /** The stored ciphertext for a provider's key. */
    fun keyData(provider: ProviderKind): ByteArray?
    fun setKeyData(data: ByteArray?, provider: ProviderKind)
    fun providersWithKeys(): List<ProviderKind>
}

/**
 * A provider balance the user read off the provider's billing page, and what TokenLib has charged that provider since.
 * Providers do not report balances to API keys, so this is TokenLib's own count: use of the key elsewhere is not seen.
 */
data class Credit(
    /** The balance entered, in millionths of a dollar. */
    val micros: Long,
    val spentMicros: Long = 0,
) {
    val remainingMicros: Long get() = maxOf(0, micros - spentMicros)
    val remainingUsd: Double get() = remainingMicros / 1_000_000.0
    val totalUsd: Double get() = micros / 1_000_000.0
}

data class Settings(
    /** The provider requests go to; `null` until the app picks one. */
    val activeProvider: ProviderKind? = null,
    /** For LOCAL: the OpenAI-compatible server, e.g. `http://192.168.1.20:11434/v1`. */
    val localBaseUrl: String? = null,
    /** For LOCAL: the model name the server loads. */
    val localModel: String? = null,
    /** Total tokens allowed per calendar day across every session; `null` is unlimited. */
    val dailyTokenCap: Int? = null,
    /** Whether prompts and replies are kept with the usage rows (off by default). */
    val logPrompts: Boolean = false,
    /** The balance entered per provider and the spend counted against it; empty until the user enters one. */
    val credits: Map<ProviderKind, Credit> = emptyMap(),
    /** The master switch: off means no request is sent anywhere, whatever else is configured (on by default). */
    val enabled: Boolean = true,
)

interface SettingsRepository {
    fun settings(): Settings
    fun save(settings: Settings)
}

data class UsageRecord(
    val id: Long? = null,
    /** Epoch milliseconds. */
    val at: Long = System.currentTimeMillis(),
    /** Who asked (an actor id, a screen name); free text. */
    val consumer: String,
    val profile: Profile,
    val provider: ProviderKind,
    val model: String,
    val promptTokens: Int,
    val replyTokens: Int,
    val costMicros: Long,
    val stop: StopReason,
    /** Only when `Settings.logPrompts` is on. */
    val prompt: String? = null,
    val reply: String? = null,
) {
    val totalTokens: Int get() = promptTokens + replyTokens
}

data class UsageTotals(val requests: Int = 0, val promptTokens: Int = 0, val replyTokens: Int = 0, val costMicros: Long = 0) {
    val totalTokens: Int get() = promptTokens + replyTokens
    val costUsd: Double get() = costMicros / 1_000_000.0
}

interface UsageRepository {
    fun record(usage: UsageRecord): UsageRecord
    /** Totals since `sinceMillis`, optionally for one consumer. */
    fun totals(sinceMillis: Long, consumer: String? = null): UsageTotals
    /** Most recent rows first. */
    fun recent(limit: Int, consumer: String? = null): List<UsageRecord>
    fun deleteAll()
}

interface TokenStore : KeyRepository, SettingsRepository, UsageRepository

// MARK: - In memory (tests, previews)

class InMemoryStore : TokenStore {
    private val keys = HashMap<ProviderKind, ByteArray>()
    private var current = Settings()
    private val usage = ArrayList<UsageRecord>()
    private var nextId = 1L

    @Synchronized override fun keyData(provider: ProviderKind): ByteArray? = keys[provider]
    @Synchronized override fun setKeyData(data: ByteArray?, provider: ProviderKind) { if (data == null) keys.remove(provider) else keys[provider] = data }
    @Synchronized override fun providersWithKeys(): List<ProviderKind> = ProviderKind.entries.filter { keys.containsKey(it) }
    @Synchronized override fun settings(): Settings = current
    @Synchronized override fun save(settings: Settings) { current = settings }

    @Synchronized override fun record(usage: UsageRecord): UsageRecord = usage.copy(id = nextId++).also { this.usage += it }

    @Synchronized override fun totals(sinceMillis: Long, consumer: String?): UsageTotals {
        var t = UsageTotals()
        for (r in usage) if (r.at >= sinceMillis && (consumer == null || r.consumer == consumer)) {
            t = UsageTotals(t.requests + 1, t.promptTokens + r.promptTokens, t.replyTokens + r.replyTokens, t.costMicros + r.costMicros)
        }
        return t
    }

    @Synchronized override fun recent(limit: Int, consumer: String?): List<UsageRecord> = usage.filter { consumer == null || it.consumer == consumer }.takeLast(limit).reversed()

    @Synchronized override fun deleteAll() { usage.clear() }
}

// MARK: - SQLite

/** The few operations the SQLite store needs, so the same store runs on JDBC (desktop, tests) and Android. */
interface SqlDatabase {
    fun execute(sql: String, args: List<Any?> = emptyList())
    /** Runs a query and maps each row; a row exposes columns by index. */
    fun <T> query(sql: String, args: List<Any?> = emptyList(), map: (SqlRow) -> T): List<T>
    fun lastInsertRowId(): Long
    fun close()
}

interface SqlRow {
    fun string(index: Int): String?
    fun long(index: Int): Long
    fun double(index: Int): Double
    fun blob(index: Int): ByteArray?
}

class SQLiteStore(private val db: SqlDatabase) : TokenStore {
    companion object {
        /**
         * Moves a database and its WAL, shared-memory and journal files to a new path, for a rename of the file.
         * Returns false, and moves nothing, when there is no file at `from` or one already exists at `to`.
         * Call it before either path is opened.
         */
        fun moveDatabase(from: java.io.File, to: java.io.File): Boolean {
            if (!from.exists() || to.exists()) return false
            for (suffix in listOf("", "-wal", "-shm", "-journal")) {
                val source = java.io.File(from.path + suffix)
                if (source.exists() && !source.renameTo(java.io.File(to.path + suffix))) throw java.io.IOException("cannot move ${source.path}")
            }
            return true
        }
    }

    init {
        db.execute("CREATE TABLE IF NOT EXISTS keys (provider TEXT PRIMARY KEY, data BLOB NOT NULL, updated_at REAL NOT NULL)")
        db.execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT)")
        db.execute("""CREATE TABLE IF NOT EXISTS usage (
            id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, consumer TEXT NOT NULL, profile TEXT NOT NULL,
            provider TEXT NOT NULL, model TEXT NOT NULL, prompt_tokens INTEGER NOT NULL, reply_tokens INTEGER NOT NULL,
            cost_micros INTEGER NOT NULL, stop TEXT NOT NULL, prompt TEXT, reply TEXT)""")
        db.execute("CREATE INDEX IF NOT EXISTS usage_at ON usage(at)")
        db.execute("CREATE INDEX IF NOT EXISTS usage_consumer ON usage(consumer, at)")
    }

    override fun keyData(provider: ProviderKind): ByteArray? = db.query("SELECT data FROM keys WHERE provider = ?", listOf(provider.id)) { it.blob(0) }.firstOrNull()

    override fun setKeyData(data: ByteArray?, provider: ProviderKind) {
        if (data != null) db.execute("INSERT INTO keys(provider, data, updated_at) VALUES(?, ?, ?) ON CONFLICT(provider) DO UPDATE SET data = excluded.data, updated_at = excluded.updated_at", listOf(provider.id, data, System.currentTimeMillis() / 1000.0))
        else db.execute("DELETE FROM keys WHERE provider = ?", listOf(provider.id))
    }

    override fun providersWithKeys(): List<ProviderKind> = db.query("SELECT provider FROM keys ORDER BY provider") { ProviderKind.of(it.string(0)) }.filterNotNull()

    override fun settings(): Settings {
        var s = Settings()
        for ((key, value) in db.query("SELECT key, value FROM settings") { (it.string(0) ?: "") to it.string(1) }) {
            s = when (key) {
                "enabled" -> s.copy(enabled = value != "0")
                "activeProvider" -> s.copy(activeProvider = ProviderKind.of(value))
                "localBaseURL" -> s.copy(localBaseUrl = value)
                "localModel" -> s.copy(localModel = value)
                "dailyTokenCap" -> s.copy(dailyTokenCap = value?.toIntOrNull())
                "logPrompts" -> s.copy(logPrompts = value == "1")
                else -> {
                    // credit.<provider> = "<micros> <spentMicros>"
                    val provider = if (key.startsWith("credit.")) ProviderKind.of(key.removePrefix("credit.")) else null
                    val parts = value.orEmpty().split(" ").mapNotNull { it.toLongOrNull() }
                    if (provider != null && parts.size == 2) s.copy(credits = s.credits + (provider to Credit(parts[0], parts[1]))) else s
                }
            }
        }
        return s
    }

    override fun save(settings: Settings) {
        val pairs = listOf("enabled" to (if (settings.enabled) "1" else "0"), "activeProvider" to settings.activeProvider?.id, "localBaseURL" to settings.localBaseUrl, "localModel" to settings.localModel,
            "dailyTokenCap" to settings.dailyTokenCap?.toString(), "logPrompts" to if (settings.logPrompts) "1" else "0") +
            ProviderKind.entries.map { "credit." + it.id to settings.credits[it]?.let { c -> "${c.micros} ${c.spentMicros}" } }
        for ((k, v) in pairs) db.execute("INSERT INTO settings(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", listOf(k, v))
    }

    override fun record(usage: UsageRecord): UsageRecord {
        db.execute("INSERT INTO usage(at, consumer, profile, provider, model, prompt_tokens, reply_tokens, cost_micros, stop, prompt, reply) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
            listOf(usage.at / 1000.0, usage.consumer, usage.profile.id, usage.provider.id, usage.model, usage.promptTokens, usage.replyTokens, usage.costMicros, usage.stop.id, usage.prompt, usage.reply))
        return usage.copy(id = db.lastInsertRowId())
    }

    override fun totals(sinceMillis: Long, consumer: String?): UsageTotals {
        val sql = "SELECT COUNT(*), COALESCE(SUM(prompt_tokens),0), COALESCE(SUM(reply_tokens),0), COALESCE(SUM(cost_micros),0) FROM usage WHERE at >= ?" + if (consumer == null) "" else " AND consumer = ?"
        val args = if (consumer == null) listOf<Any?>(sinceMillis / 1000.0) else listOf(sinceMillis / 1000.0, consumer)
        return db.query(sql, args) { UsageTotals(it.long(0).toInt(), it.long(1).toInt(), it.long(2).toInt(), it.long(3)) }.firstOrNull() ?: UsageTotals()
    }

    override fun recent(limit: Int, consumer: String?): List<UsageRecord> {
        val sql = "SELECT id, at, consumer, profile, provider, model, prompt_tokens, reply_tokens, cost_micros, stop, prompt, reply FROM usage" + (if (consumer == null) "" else " WHERE consumer = ?") + " ORDER BY id DESC LIMIT ?"
        val args = if (consumer == null) listOf<Any?>(limit) else listOf(consumer, limit)
        return db.query(sql, args) { r ->
            UsageRecord(r.long(0), (r.double(1) * 1000).toLong(), r.string(2) ?: "", Profile.of(r.string(3)) ?: Profile.ASSISTANT, ProviderKind.of(r.string(4)) ?: ProviderKind.ANTHROPIC,
                r.string(5) ?: "", r.long(6).toInt(), r.long(7).toInt(), r.long(8), StopReason.of(r.string(9)), r.string(10), r.string(11))
        }
    }

    override fun deleteAll() = db.execute("DELETE FROM usage")
}

/** JDBC implementation (desktop and tests); needs a SQLite JDBC driver on the classpath. */
class JdbcSqlDatabase(path: String) : SqlDatabase {
    private val connection: java.sql.Connection = java.sql.DriverManager.getConnection("jdbc:sqlite:$path")

    private fun bind(statement: java.sql.PreparedStatement, args: List<Any?>) {
        for ((i, arg) in args.withIndex()) {
            val index = i + 1
            when (arg) {
                null -> statement.setNull(index, java.sql.Types.NULL)
                is String -> statement.setString(index, arg)
                is Int -> statement.setLong(index, arg.toLong())
                is Long -> statement.setLong(index, arg)
                is Double -> statement.setDouble(index, arg)
                is ByteArray -> statement.setBytes(index, arg)
                else -> statement.setString(index, arg.toString())
            }
        }
    }

    @Synchronized override fun execute(sql: String, args: List<Any?>) { connection.prepareStatement(sql).use { bind(it, args); it.executeUpdate() } }

    @Synchronized override fun <T> query(sql: String, args: List<Any?>, map: (SqlRow) -> T): List<T> = connection.prepareStatement(sql).use { statement ->
        bind(statement, args)
        statement.executeQuery().use { rs ->
            val row = object : SqlRow {
                override fun string(index: Int): String? = rs.getString(index + 1)
                override fun long(index: Int): Long = rs.getLong(index + 1)
                override fun double(index: Int): Double = rs.getDouble(index + 1)
                override fun blob(index: Int): ByteArray? = rs.getBytes(index + 1)
            }
            val out = ArrayList<T>()
            while (rs.next()) out += map(row)
            out
        }
    }

    @Synchronized override fun lastInsertRowId(): Long = connection.createStatement().use { s -> s.executeQuery("SELECT last_insert_rowid()").use { rs -> if (rs.next()) rs.getLong(1) else 0L } }

    override fun close() = connection.close()
}
