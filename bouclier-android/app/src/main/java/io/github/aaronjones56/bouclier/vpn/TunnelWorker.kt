package io.github.aaronjones56.bouclier.vpn

import android.os.ParcelFileDescriptor
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructPollfd
import android.util.Log
import java.io.FileDescriptor
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/**
 * Lit les paquets de l'interface TUN dans un fil dédié et y écrit les réponses.
 * Les requêtes transmises au serveur DNS partent dans un petit groupe de fils, pour
 * qu'une réponse lente n'en retarde pas d'autres.
 */
class TunnelWorker(
    tunnel: ParcelFileDescriptor,
    private val handler: DnsPacketHandler,
    private val forwarder: UpstreamForwarder,
    private val onFailure: (Throwable?) -> Unit,
) {
    private val tunnelFd: FileDescriptor = tunnel.fileDescriptor
    private val input = FileInputStream(tunnelFd)
    private val output = FileOutputStream(tunnelFd)
    private val stopPipe: Array<FileDescriptor> = Os.pipe()
    private val executor = ThreadPoolExecutor(
        MAX_THREADS,
        MAX_THREADS,
        30,
        TimeUnit.SECONDS,
        LinkedBlockingQueue(MAX_PENDING),
        { runnable -> Thread(runnable, "bouclier-dns").apply { isDaemon = true } },
        ThreadPoolExecutor.DiscardPolicy(),
    ).apply { allowCoreThreadTimeOut(true) }
    private val thread = Thread(::readLoop, "bouclier-tun")

    @Volatile
    private var running = false

    fun start() {
        running = true
        thread.start()
    }

    /** Arrête la lecture et attend la fin du fil. L'interface TUN reste à fermer par l'appelant. */
    fun stop() {
        running = false
        try {
            Os.write(stopPipe[1], ByteArray(1), 0, 1)
        } catch (e: Exception) {
            Log.w(TAG, "Impossible de réveiller le fil du VPN", e)
        }
        if (Thread.currentThread() != thread) thread.join(STOP_TIMEOUT_MS)
        executor.shutdownNow()
        stopPipe.forEach(::closeQuietly)
    }

    private fun readLoop() {
        val buffer = ByteArray(MAX_PACKET_SIZE)
        val tunnelPoll = StructPollfd().apply {
            fd = tunnelFd
            events = OsConstants.POLLIN.toShort()
        }
        val stopPoll = StructPollfd().apply {
            fd = stopPipe[0]
            events = OsConstants.POLLIN.toShort()
        }
        val polls = arrayOf(tunnelPoll, stopPoll)
        var failure: Throwable? = null
        try {
            while (running) {
                tunnelPoll.revents = 0
                stopPoll.revents = 0
                try {
                    Os.poll(polls, -1)
                } catch (e: ErrnoException) {
                    if (e.errno == OsConstants.EINTR) continue
                    throw e
                }
                if (stopPoll.revents.toInt() != 0) break
                val events = tunnelPoll.revents.toInt()
                if (events and (OsConstants.POLLERR or OsConstants.POLLHUP or OsConstants.POLLNVAL) != 0) {
                    throw IOException("Interface VPN fermée")
                }
                if (events and OsConstants.POLLIN == 0) continue
                val length = input.read(buffer)
                if (length < 0) throw IOException("Fin de l'interface VPN")
                if (length > 0) dispatch(buffer, length)
            }
        } catch (e: Exception) {
            failure = e
        }
        if (running) {
            running = false
            Log.w(TAG, "Arrêt inattendu du VPN", failure)
            onFailure(failure)
        }
    }

    private fun dispatch(buffer: ByteArray, length: Int) {
        val result = try {
            handler.handle(buffer, length)
        } catch (e: RuntimeException) {
            Log.w(TAG, "Paquet ignoré", e)
            return
        }
        when (result) {
            DnsPacketHandler.Result.Drop -> Unit
            is DnsPacketHandler.Result.Reply -> write(result.packet)
            is DnsPacketHandler.Result.Forward -> executor.execute {
                val response = forwarder.resolve(result.query) ?: return@execute
                if (running) write(result.wrapResponse(response))
            }
        }
    }

    private fun write(packet: ByteArray) {
        try {
            synchronized(output) { output.write(packet) }
        } catch (e: IOException) {
            if (running) Log.w(TAG, "Écriture impossible sur l'interface VPN", e)
        }
    }

    private fun closeQuietly(fd: FileDescriptor) {
        try {
            Os.close(fd)
        } catch (e: ErrnoException) {
            // déjà fermé
        }
    }

    companion object {
        private const val TAG = "TunnelWorker"
        private const val MAX_THREADS = 16
        private const val MAX_PENDING = 512
        private const val STOP_TIMEOUT_MS = 2000L

        /** Taille des paquets échangés avec l'interface TUN (son MTU). */
        const val MAX_PACKET_SIZE = 16 * 1024
    }
}
