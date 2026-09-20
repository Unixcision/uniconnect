package com.unixcision.uniconnect.android

import android.app.Application

class UniConnectApplication : Application() {
    val container by lazy { AppContainer(this) }

    override fun onCreate() {
        super.onCreate()
        // Lo primero de todo: un fallo que ocurra montando cualquier otra cosa ya queda apuntado.
        container.crashVault.install()
    }
}
