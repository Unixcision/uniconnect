package com.unixcision.uniconnect.android.domain

import java.time.Instant

/**
 * Los reseteos gratis que ofrece Codex a una cuenta (`usage.reset_credits`, §2.4): cuántos quedan y
 * cuándo caduca el primero. Solo en Codex; sin reseteos, la clave no viene.
 */
data class ResetCredits(val available: Int, val nextExpiresAt: Instant?)
