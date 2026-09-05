package com.unixcision.uniconnect.android

import android.content.Context
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.preferencesDataStoreFile
import com.unixcision.uniconnect.android.data.NativeMachineClient
import com.unixcision.uniconnect.android.data.FramedRpcClient
import com.unixcision.uniconnect.android.data.StoredMachineRepository
import com.unixcision.uniconnect.android.data.AndroidNotificationConnections
import com.unixcision.uniconnect.android.data.NativeNotificationClient
import com.unixcision.uniconnect.android.data.StoredNoticeDeliveryRepository
import com.unixcision.uniconnect.android.domain.NotificationClient
import com.unixcision.uniconnect.android.domain.NoticeDeliveryRepository
import com.unixcision.uniconnect.android.domain.MachineClient
import com.unixcision.uniconnect.android.domain.MachineRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

/** Application composition root; concrete services are injected into view-models. */
class AppContainer(context: Context) {
    private val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val store = PreferenceDataStoreFactory.create(scope = ioScope) {
        context.preferencesDataStoreFile("uniconnect_machines")
    }
    val machines: MachineRepository = StoredMachineRepository(store)
    val rpc = FramedRpcClient(ioScope)
    val machineClient: MachineClient = NativeMachineClient(rpc)
    val notificationConnections = AndroidNotificationConnections(context, store, ioScope)
    val noticeDeliveries: NoticeDeliveryRepository = StoredNoticeDeliveryRepository(store)
    val notificationClient: NotificationClient = NativeNotificationClient(rpc)
}
