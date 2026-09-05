package com.unixcision.uniconnect.android

import android.app.Application

class UniConnectApplication : Application() {
    val container by lazy { AppContainer(this) }
}
