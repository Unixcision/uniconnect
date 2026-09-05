package com.unixcision.uniconnect.android.domain

data class MachineSnapshot(val serverName: String, val workspaces: List<RemoteWorkspace>)
