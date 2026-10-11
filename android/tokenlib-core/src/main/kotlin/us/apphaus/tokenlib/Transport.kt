/*
 * Transport.kt
 * TokenLib
 *
 * HTTP with streaming bodies, small enough to fake in tests. Providers
 * build an HttpRequest and read the body line by line (server-sent events
 * and newline-delimited JSON both arrive that way).
 */
package us.apphaus.tokenlib

import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

data class HttpRequest(val url: String, val method: String = "POST", val headers: Map<String, String> = emptyMap(), val body: ByteArray? = null) {
    val bodyJson: Map<String, Any?>? get() = body?.let { MiniJson.parse(String(it, Charsets.UTF_8)) as? Map<String, Any?> }
    override fun equals(other: Any?): Boolean = other is HttpRequest && other.url == url && other.method == method && other.headers == headers && (other.body ?: ByteArray(0)).contentEquals(body ?: ByteArray(0))
    override fun hashCode(): Int = url.hashCode()
}

/** A handle to cancel an in-flight request. */
fun interface Cancellable { fun cancel() }

object NoopCancellable : Cancellable { override fun cancel() {} }

interface HttpTransport {
    /**
     * Sends the request; `onStatus` gets the HTTP status once, `onLine` each line of the body as it
     * arrives (without the newline), `completion` the end (with the whole body when the status is not 2xx).
     */
    fun stream(request: HttpRequest, onStatus: (Int) -> Unit, onLine: (String) -> Unit, completion: (Result<Unit>) -> Unit): Cancellable
}

/** Server-sent events: `event:` and `data:` lines, blank line ends an event. */
class SseParser {
    data class Event(val name: String?, val data: String)
    private var name: String? = null
    private val data = mutableListOf<String>()

    /** Feeds one line; returns the event it completed, if any. */
    fun feed(line: String): Event? {
        if (line.isEmpty()) {
            if (data.isEmpty()) { name = null; return null }
            val event = Event(name, data.joinToString("\n"))
            name = null; data.clear()
            return event
        }
        if (line.startsWith(":")) return null
        val colon = line.indexOf(':')
        val field = if (colon >= 0) line.substring(0, colon) else line
        val value = if (colon >= 0) line.substring(colon + 1).removePrefix(" ") else ""
        when (field) {
            "event" -> name = value
            "data" -> data += value
        }
        return null
    }
}

/** HttpURLConnection on a background thread; works on the JVM and Android without dependencies. */
class HttpUrlConnectionTransport(private val executor: ExecutorService = Executors.newCachedThreadPool { r -> Thread(r, "tokenlib-http").apply { isDaemon = true } }, private val timeoutMs: Int = 120_000) : HttpTransport {
    override fun stream(request: HttpRequest, onStatus: (Int) -> Unit, onLine: (String) -> Unit, completion: (Result<Unit>) -> Unit): Cancellable {
        val cancelled = java.util.concurrent.atomic.AtomicBoolean(false)
        var connection: HttpURLConnection? = null
        executor.execute {
            try {
                val c = (URL(request.url).openConnection() as HttpURLConnection).also { connection = it }
                c.requestMethod = request.method
                c.connectTimeout = 15_000
                c.readTimeout = timeoutMs
                for ((k, v) in request.headers) c.setRequestProperty(k, v)
                request.body?.let { c.doOutput = true; c.outputStream.use { out -> out.write(it) } }
                val status = c.responseCode
                onStatus(status)
                if (status in 200..299) {
                    BufferedReader(InputStreamReader(c.inputStream, Charsets.UTF_8)).use { reader ->
                        while (!cancelled.get()) {
                            val line = reader.readLine() ?: break
                            onLine(line)
                        }
                    }
                    completion(if (cancelled.get()) Result.failure(TokenLibException.Cancelled) else Result.success(Unit))
                } else {
                    val body = (c.errorStream ?: c.inputStream)?.use { String(it.readBytes(), Charsets.UTF_8) } ?: ""
                    completion(Result.failure(TokenLibException.Http(status, body)))
                }
            } catch (e: Exception) {
                completion(Result.failure(if (cancelled.get()) TokenLibException.Cancelled else TokenLibException.Transport(e.message ?: e.toString())))
            } finally {
                connection?.disconnect()
            }
        }
        return Cancellable { cancelled.set(true); connection?.disconnect() }
    }
}
