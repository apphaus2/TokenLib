/*
 * AndroidSqlDatabase.kt
 * TokenLib (Android)
 *
 * The SqlDatabase adapter over android.database.sqlite, so SQLiteStore runs
 * on Android without a JDBC driver.
 */
package us.apphaus.tokenlib.android

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import us.apphaus.tokenlib.SQLiteStore
import us.apphaus.tokenlib.SqlDatabase
import us.apphaus.tokenlib.SqlRow
import java.io.File

class AndroidSqlDatabase(private val db: SQLiteDatabase) : SqlDatabase {
    constructor(context: Context, name: String = "tokenlib.sqlite") : this(SQLiteDatabase.openOrCreateDatabase(File(context.noBackupFilesDir, name), null))

    @Synchronized override fun execute(sql: String, args: List<Any?>) {
        db.compileStatement(sql).use { statement ->
            for ((i, arg) in args.withIndex()) {
                val index = i + 1
                when (arg) {
                    null -> statement.bindNull(index)
                    is String -> statement.bindString(index, arg)
                    is Int -> statement.bindLong(index, arg.toLong())
                    is Long -> statement.bindLong(index, arg)
                    is Double -> statement.bindDouble(index, arg)
                    is ByteArray -> statement.bindBlob(index, arg)
                    else -> statement.bindString(index, arg.toString())
                }
            }
            statement.execute()
        }
    }

    @Synchronized override fun <T> query(sql: String, args: List<Any?>, map: (SqlRow) -> T): List<T> {
        // rawQuery binds strings only; numbers and blobs are inlined as literals (values come from the store, not users).
        var index = 0
        val inlined = StringBuilder()
        for (c in sql) {
            if (c == '?' && index < args.size) {
                when (val a = args[index++]) {
                    null -> inlined.append("NULL")
                    is String -> inlined.append('?')
                    is ByteArray -> inlined.append("X'").append(a.joinToString("") { "%02x".format(it) }).append("'")
                    else -> inlined.append(a.toString())
                }
            } else inlined.append(c)
        }
        val strings = args.filterIsInstance<String>().toTypedArray()
        db.rawQuery(inlined.toString(), strings).use { cursor ->
            val row = object : SqlRow {
                override fun string(index: Int): String? = if (cursor.isNull(index)) null else cursor.getString(index)
                override fun long(index: Int): Long = cursor.getLong(index)
                override fun double(index: Int): Double = cursor.getDouble(index)
                override fun blob(index: Int): ByteArray? = if (cursor.isNull(index)) null else cursor.getBlob(index)
            }
            val out = ArrayList<T>()
            while (cursor.moveToNext()) out += map(row)
            return out
        }
    }

    @Synchronized override fun lastInsertRowId(): Long = db.rawQuery("SELECT last_insert_rowid()", null).use { if (it.moveToFirst()) it.getLong(0) else 0L }

    override fun close() = db.close()

    companion object {
        /** A store in the app's no-backup files directory. */
        fun store(context: Context, name: String = "tokenlib.sqlite"): SQLiteStore = SQLiteStore(AndroidSqlDatabase(context, name))
    }
}
