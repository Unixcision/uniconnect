package com.unixcision.uniconnect.android.domain

import java.time.Instant

/** Una muestra del histórico que guarda el escritorio: el porcentaje de cada límite en [at]. */
data class UsageSample(val at: Instant, val limits: Map<String, Double>)
