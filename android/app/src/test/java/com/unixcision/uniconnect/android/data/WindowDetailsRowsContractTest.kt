package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.DetailsLineKind
import com.unixcision.uniconnect.android.domain.DetailsSheet
import com.unixcision.uniconnect.android.domain.DetailsText
import com.unixcision.uniconnect.android.domain.WindowDetailsRows
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Las filas del modal «Detalles» para cada respuesta de `contracts/window-details-v1`, con el texto
 * que de verdad sale en el teléfono.
 *
 * `filas.json` es el mismo fichero contra el que se miden el Mac y Linux (D3: mismo texto, letra por
 * letra, en las tres plataformas). La respuesta pasa por el decodificador real y por
 * [WindowDetailsRows], y cada texto sale del `strings.xml` que empaqueta la app: las pruebas JVM no
 * tienen `Resources`, así que se lee el fichero y se resuelve como lo resolvería `getString`.
 */
class WindowDetailsRowsContractTest {
    private val client = NativeMachineClient(FramedRpcClient(CoroutineScope(Dispatchers.Unconfined)))
    private val strings: Map<String, String> by lazy { AppStrings.load() }

    private fun resource(name: String): String =
        requireNotNull(javaClass.classLoader?.getResourceAsStream("window-details-v1/$name")) {
            "falta el fixture del contrato: contracts/window-details-v1/$name"
        }.bufferedReader().readText()

    private fun text(text: DetailsText): String =
        requireNotNull(strings[text.resource]) { "falta ${text.resource} en strings.xml" }

    private fun render(fixture: String, change: (JSONObject) -> Unit = {}): DetailsSheet {
        val response = JSONObject(resource(fixture)).also(change)
        return WindowDetailsRows.render(client.decodeDetails(response), ::text)
    }

    private fun DetailsSheet.row(label: String): String? = lines.firstOrNull { it.label == label }?.value

    @Test fun `cada respuesta del contrato da exactamente sus filas`() {
        val casos = JSONObject(resource("filas.json")).getJSONArray("casos")
        assertTrue("filas.json tiene que traer las nueve respuestas", casos.length() >= 9)
        for (index in 0 until casos.length()) {
            val caso = casos.getJSONObject(index)
            val fixture = caso.getString("fixture")
            val sheet = render(fixture)
            assertEquals("$fixture: aviso", caso.textOrNull("aviso"), sheet.notice)
            assertEquals("$fixture: filas", caso.getJSONArray("filas").pairs(), sheet.lines.map { it.label to it.value })
            assertEquals("$fixture: nota de la orden", caso.textOrNull("nota_orden"), sheet.commandNote)
        }
    }

    @Test fun `la orden y los datos para copiar se pintan monoespaciados`() {
        val sheet = render("details-response-ssh.json")
        assertEquals(DetailsLineKind.COMMAND, sheet.lines.last().kind)
        assertEquals(DetailsLineKind.CODE, sheet.lines.first { it.label == "ID de conversación" }.kind)
        assertEquals(DetailsLineKind.CODE, sheet.lines.first { it.label == "Carpeta" }.kind)
        assertEquals(DetailsLineKind.TEXT, sheet.lines.first { it.label == "IA" }.kind)
    }

    @Test fun `dos IA a la vez ganan aunque haya una guardada`() {
        val sheet = render("details-response-saved-shell.json") { it.put("reason", "identidad_ambigua") }
        assertEquals("Hay más de una IA en esta ventana", sheet.row("IA"))
        // Lo guardado se sigue enseñando debajo: la ambigüedad no lo borra.
        assertEquals("Guardada (no comprobada ahora)", sheet.row("Estado"))
        assertEquals("01a0ac81-57c7-7af3-8ac2-fe8a957c8b17", sheet.row("ID de conversación"))
    }

    @Test fun `una IA guardada sin identificador lo dice sin inventar ninguno`() {
        val sheet = render("details-response-interrupted.json") { response ->
            response.getJSONObject("agent").put("session_id", JSONObject.NULL).put("resume", JSONObject.NULL).put("state", "guardado")
        }
        assertEquals("Claude Code: sin identificador guardado", sheet.row("IA"))
        assertEquals("—", sheet.row("ID de conversación"))
        assertNull(sheet.row("Orden para reanudarla"))
    }

    @Test fun `sin IA guardada y sin poder comprobar`() {
        val sheet = render("details-response-vault-closed.json") { it.put("agent", JSONObject.NULL) }
        assertEquals("No se pudo comprobar el servidor; se muestra lo guardado", sheet.notice)
        assertEquals("Sin IA guardada", sheet.row("IA"))
        assertNull(sheet.row("Estado"))
    }

    @Test fun `grok avisa de que no tiene modo sin preguntas verificado`() {
        val sheet = render("details-response-local.json") { response ->
            val agent = response.getJSONObject("agent").put("provider", "grok").put("display_name", "Grok")
            agent.getJSONObject("resume")
                .put("argv", JSONArray(listOf("grok", "-r", "3f6a9c12-8d4e-4b7a-b5c1-0e2f7d9a6b84")))
                .put("command", "cd -- '/home/dani/grokbot' && grok -r 3f6a9c12-8d4e-4b7a-b5c1-0e2f7d9a6b84")
                .put("no_prompt_verified", false)
        }
        assertEquals("Grok", sheet.row("IA"))
        assertEquals("Sin modo sin preguntas verificado para esta IA", sheet.commandNote)
    }

    @Test fun `un estado o un origen que esta version no conoce se ensena tal cual`() {
        val sheet = render("details-response-local.json") { response ->
            response.getJSONObject("agent").put("state", "pausado").put("source", "satelite")
        }
        assertEquals("pausado", sheet.row("Estado"))
        assertEquals("satelite", sheet.row("Origen del dato"))
    }

    @Test fun `una caja SSH sin etiqueta se llama VPS a secas`() {
        val sheet = render("details-response-vault-closed.json") { it.getJSONObject("workspace").put("host_label", JSONObject.NULL) }
        assertEquals("VPS", sheet.row("Tipo"))
    }

    private fun JSONObject.textOrNull(key: String): String? = if (!has(key) || isNull(key)) null else getString(key)

    private fun JSONArray.pairs(): List<Pair<String, String>> = List(length()) { index ->
        val row = getJSONArray(index)
        row.getString(0) to row.getString(1)
    }
}

/** Los textos de `src/main/res/values/strings.xml`, resueltos como los devolvería `getString`. */
private object AppStrings {
    private val entry = Regex("""<string name="([^"]+)"[^>]*>(.*?)</string>""", RegexOption.DOT_MATCHES_ALL)

    fun load(): Map<String, String> =
        entry.findAll(locate().readText()).associate { it.groupValues[1] to unescape(it.groupValues[2]) }

    /** Sube desde el directorio de trabajo de Gradle (el del módulo) hasta encontrar el fichero. */
    private fun locate(): File {
        val start = File(System.getProperty("user.dir")).absoluteFile
        var folder: File? = start
        while (folder != null) {
            for (candidate in listOf("src/main/res/values/strings.xml", "app/src/main/res/values/strings.xml", "android/app/src/main/res/values/strings.xml")) {
                val file = File(folder, candidate)
                if (file.isFile) return file
            }
            folder = folder.parentFile
        }
        error("No se encuentra app/src/main/res/values/strings.xml subiendo desde $start")
    }

    private fun unescape(raw: String): String = raw
        .replace("\\'", "'").replace("\\\"", "\"").replace("\\n", "\n")
        .replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")
}
