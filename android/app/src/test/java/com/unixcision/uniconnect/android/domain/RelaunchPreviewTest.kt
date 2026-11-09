package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Una petición a uno o a varios equipos («todo») en un solo diálogo: qué se enseña, qué se
 * pregunta y qué se ejecuta, y cómo se cuenta al terminar. Un equipo que no contesta se nombra; no
 * desaparece dentro del total de otro.
 */
class RelaunchPreviewTest {
    private fun targets(n: Int, machine: String) = List(n) { RelaunchTarget("$machine-$it", "$machine · ventana $it", "claude") }

    private fun plan(targets: List<RelaunchTarget>, verb: RelaunchVerb = RelaunchVerb.RELAUNCH, exclusions: List<RelaunchExclusion> = emptyList()) =
        RelaunchPlan("op", "token", verb, targets, exclusions)

    private fun request(vararg machines: String, verb: RelaunchVerb = RelaunchVerb.RELAUNCH, everywhere: Boolean = machines.size > 1) =
        RelaunchRequest(verb, machines.map { RelaunchScope.Machine(it) }, everywhere = everywhere)

    @Test fun `las opciones solo valen para actualizar`() {
        assertThrows(IllegalArgumentException::class.java) {
            RelaunchRequest(RelaunchVerb.RELAUNCH, listOf(RelaunchScope.Machine("m")), RelaunchOptions(model = "opus[1m]"))
        }
        assertNull(RelaunchRequest(RelaunchVerb.UPDATE, listOf(RelaunchScope.Machine("m"))).wireOptions)
        assertEquals(
            RelaunchOptions(effort = "max"),
            RelaunchRequest(RelaunchVerb.UPDATE, listOf(RelaunchScope.Machine("m")), RelaunchOptions(effort = "max")).wireOptions,
        )
    }

    @Test fun `un equipo solo decide como siempre`() {
        val preview = RelaunchPreview(request("mac", everywhere = false), listOf(RelaunchHostPlan("mac", "Mac", plan(targets(2, "mac")))))
        assertEquals(RelaunchPreview.Step.APPLY, preview.step)
        val sinPlan = RelaunchPreview(request("mac", everywhere = false), listOf(RelaunchHostPlan("mac", "Mac", null, RelaunchHostProblem.PLAN_FAILED)))
        assertEquals(RelaunchPreview.Step.FAILED, sinPlan.step)
    }

    @Test fun `todo se pregunta siempre, aunque sea un equipo con dos ventanas`() {
        val preview = RelaunchPreview(request("mac", everywhere = true), listOf(RelaunchHostPlan("mac", "Mac", plan(targets(2, "mac")))))
        assertEquals(RelaunchPreview.Step.CONFIRM, preview.step)
    }

    @Test fun `varios equipos suman lo ejecutable y nombran al que no contesto`() {
        val bloqueado = RelaunchPlan("op", "t", RelaunchVerb.RELAUNCH, targets(4, "prepro"), emptyList(), unavailableReason = "Sin identidad.")
        val preview = RelaunchPreview(
            request("mac", "minipc", "prepro", "xunis"),
            listOf(
                RelaunchHostPlan("mac", "Mac", plan(targets(2, "mac"))),
                RelaunchHostPlan("minipc", "MINIPC", plan(targets(3, "minipc"))),
                RelaunchHostPlan("prepro", "PREPRO", bloqueado),
                RelaunchHostPlan("xunis", "XUNIS", null, RelaunchHostProblem.PLAN_FAILED, "alcance_no_valido"),
            ),
        )

        assertEquals(RelaunchPreview.Step.CONFIRM, preview.step)
        assertEquals(5, preview.targetCount)
        assertEquals(listOf("mac", "minipc"), preview.runnable.map { it.machineID })
        assertEquals(listOf("xunis"), preview.failed.map { it.machineID })
    }

    @Test fun `varios equipos sin nada que ejecutar se ensenyan, y sin nada que contar no`() {
        val excluido = plan(emptyList(), exclusions = listOf(RelaunchExclusion("MINIPC · codex", RelaunchReason.of("proveedor_no_soportado"))))
        val conAlgo = RelaunchPreview(
            request("mac", "minipc"),
            listOf(RelaunchHostPlan("mac", "Mac", plan(emptyList())), RelaunchHostPlan("minipc", "MINIPC", excluido)),
        )
        assertEquals(RelaunchPreview.Step.SHOW, conAlgo.step)

        val vacio = RelaunchPreview(
            request("mac", "minipc"),
            listOf(RelaunchHostPlan("mac", "Mac", plan(emptyList())), RelaunchHostPlan("minipc", "MINIPC", plan(emptyList()))),
        )
        assertEquals(RelaunchPreview.Step.NOTHING, vacio.step)

        // Ninguno contestó: se enseña quién, no un «no se pudo» sin nombres.
        val nadie = RelaunchPreview(
            request("mac", "minipc"),
            listOf(
                RelaunchHostPlan("mac", "Mac", null, RelaunchHostProblem.PLAN_FAILED),
                RelaunchHostPlan("minipc", "MINIPC", null, RelaunchHostProblem.PLAN_FAILED),
            ),
        )
        assertEquals(RelaunchPreview.Step.SHOW, nadie.step)
    }

    @Test fun `el resultado de varios equipos se cuenta por ventana y nombra los problemas`() {
        val mac = RelaunchOperation("a", recovered = false, operationState = RelaunchOperation.FINISHED, results = listOf(
            RelaunchResult("1", RelaunchTargetState.VERIFIED, backgroundSaved = 2, messageSent = true),
            RelaunchResult("2", RelaunchTargetState.NEEDS_USER, RelaunchReason.of("confianza_carpeta")),
        ), updates = listOf(RelaunchUpdate("local:Mac", "ya_al_dia", "2.1.321", "2.1.321")))
        val minipc = RelaunchOperation("b", recovered = false, operationState = RelaunchOperation.FINISHED, results = listOf(
            RelaunchResult("3", RelaunchTargetState.VERIFIED, draftRestored = true, droppedOptions = listOf("--foo")),
            RelaunchResult("4", RelaunchTargetState.SKIPPED, RelaunchReason.of("actualizacion_fallida")),
        ), updates = listOf(RelaunchUpdate("local:MINIPC", "fallida", "2.1.300")))

        val outcome = RelaunchOutcome(RelaunchVerb.UPDATE, listOf(
            RelaunchHostResult("mac", "Mac", mac),
            RelaunchHostResult("minipc", "MINIPC", minipc),
            RelaunchHostResult("xunis", "XUNIS", null, RelaunchHostProblem.RESULT_UNKNOWN),
        ))

        assertEquals(2, outcome.verified)
        assertEquals(4, outcome.total)
        assertEquals(1, outcome.needingUser.size)
        assertEquals(1, outcome.untouched.size)
        assertEquals(listOf(RelaunchCause.FOLDER_TRUST, RelaunchCause.UPDATE_FAILED), outcome.reasons.map { it.cause })
        assertEquals(listOf(RelaunchUpdate.Kind.UP_TO_DATE, RelaunchUpdate.Kind.FAILED), outcome.updates.map { it.kind })
        assertEquals(2, outcome.monitorsSaved)
        assertEquals(1, outcome.messagesSent)
        assertEquals(1, outcome.draftsRestored)
        assertEquals(listOf("--foo"), outcome.droppedOptions)
        assertEquals(listOf("xunis"), outcome.problems.map { it.machineID })
        assertTrue(outcome.reportedModels.isEmpty())
    }
}
