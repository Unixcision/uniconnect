package com.unixcision.uniconnect.android.data

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.PowerManager
import android.app.ActivityManager
import androidx.core.content.FileProvider
import com.unixcision.uniconnect.android.domain.ConnectionEvent
import com.unixcision.uniconnect.android.domain.CrashReport
import com.unixcision.uniconnect.android.domain.DiagnosticEnvironment
import com.unixcision.uniconnect.android.domain.DiagnosticReport
import java.io.File

/**
 * Lee del sistema lo que hace falta para explicar un fallo de conexión sin preguntar nada.
 *
 * Cada dato está aquí porque distingue una causa de otra, no por completar una ficha:
 * la red dice si el problema aparece solo fuera de casa, el ahorro de batería y la restricción en
 * segundo plano explican cortes que **no son de la app**, y la versión evita diagnosticar sobre una
 * compilación que ya no es la instalada.
 */
class AndroidDiagnostics(private val context: Context) {

    /**
     * Lo que se sabe del móvil, sin que ninguna lectura pueda tumbar nada.
     *
     * Cada dato va envuelto porque **este código ya mató la app una vez**: `describeNetwork` lanzó
     * `SecurityException` por un permiso sin declarar, se llamaba desde la composición, y el botón
     * de diagnóstico —lo único que había para explicar un fallo— se convirtió en el fallo. Un
     * diagnóstico que revienta es peor que no tener diagnóstico: un dato que no se puede leer se
     * cuenta como desconocido y el informe sale igual.
     */
    fun environment(): DiagnosticEnvironment {
        val packageInfo = runCatching {
            context.packageManager.getPackageInfo(context.packageName, 0)
        }.getOrNull()
        val power = runCatching { context.getSystemService(Context.POWER_SERVICE) as? PowerManager }.getOrNull()
        val activity = runCatching { context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager }.getOrNull()
        return DiagnosticEnvironment(
            appVersion = packageInfo?.versionName ?: "desconocida",
            appBuild = packageInfo?.let {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) it.longVersionCode.toString()
                else @Suppress("DEPRECATION") it.versionCode.toString()
            } ?: "?",
            androidRelease = Build.VERSION.RELEASE ?: "?",
            sdkInt = Build.VERSION.SDK_INT,
            deviceModel = "${Build.MANUFACTURER} ${Build.MODEL}".trim(),
            network = describeNetwork(),
            networkOperator = operatorName(),
            batterySaver = runCatching { power?.isPowerSaveMode }.getOrNull(),
            // Con esto activado Android corta la app en segundo plano y las conexiones mueren sin
            // que la app tenga arte ni parte. Sin el dato, ese fallo se busca donde no está.
            backgroundRestricted = runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) activity?.isBackgroundRestricted else null
            }.getOrNull(),
        )
    }

    /**
     * Qué red hay **ahora mismo**: `wifi`, `móvil`, `sin red`…
     *
     * Público porque cada apunte del diario lo necesita en su propio instante, no solo el informe
     * al generarse: el fallo que se quiere explicar es precisamente «por wifi va, con datos no»,
     * y eso no se ve si todos los intentos comparten la red del momento de mirar el informe.
     */
    fun describeNetwork(): String = runCatching { readNetwork() }.getOrElse { "desconocida (${it::class.java.simpleName})" }

    private fun readNetwork(): String {
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return "desconocida"
        val capabilities = manager.getNetworkCapabilities(manager.activeNetwork)
            ?: return "sin red"
        return buildString {
            append(
                when {
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "móvil"
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                    else -> "otra"
                }
            )
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) append("+vpn")
            // Una red «conectada» que el sistema no ha validado es la causa clásica de que todo
            // parezca bien y nada funcione.
            if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) {
                append(" (sin validar)")
            }
            if (!capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)) {
                append(" (de pago)")
            }
        }
    }

    private fun operatorName(): String? = runCatching {
        val manager = context.getSystemService(Context.TELEPHONY_SERVICE)
            as? android.telephony.TelephonyManager
        manager?.networkOperatorName?.takeIf { it.isNotBlank() }
    }.getOrNull()

    /** Escribe el informe en la caché de la app y devuelve algo que se pueda compartir. */
    fun writeReport(events: List<ConnectionEvent>, crashes: List<CrashReport> = emptyList()): File {
        val folder = File(context.cacheDir, "diagnostico").apply { mkdirs() }
        // Se limpia lo viejo: el diagnóstico no debe convertirse él mismo en un problema de espacio.
        folder.listFiles()?.sortedBy { it.lastModified() }?.dropLast(4)?.forEach { it.delete() }
        val file = File(folder, DiagnosticReport.fileName())
        file.writeText(DiagnosticReport.render(runCatching { environment() }.getOrNull(), events, crashes = crashes))
        return file
    }

    /**
     * Abre el menú de compartir con el informe.
     *
     * Como fichero **y** como texto: el fichero para adjuntarlo a un correo o guardarlo, y el texto
     * para pegarlo en un chat sin abrir nada. Compartir funciona sin conexión, que es justo cuando
     * este informe hace falta.
     */
    fun share(events: List<ConnectionEvent>, crashes: List<CrashReport> = emptyList()) {
        val file = writeReport(events, crashes)
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
        val send = Intent(Intent.ACTION_SEND)
            .setType("text/plain")
            .putExtra(Intent.EXTRA_STREAM, uri)
            .putExtra(Intent.EXTRA_SUBJECT, "UniConnect · ${DiagnosticReport.headline(events, crashes)}")
            .putExtra(Intent.EXTRA_TEXT, file.readText().take(60_000))
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        context.startActivity(
            Intent.createChooser(send, "Compartir informe de conexión")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }
}
