package com.unixcision.uniconnect.android

import android.content.Context
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.preferencesDataStoreFile
import com.unixcision.uniconnect.android.data.NativeMachineClient
import com.unixcision.uniconnect.android.data.FramedRpcClient
import com.unixcision.uniconnect.android.data.StoredMachineRepository
import com.unixcision.uniconnect.android.data.AndroidDictation
import com.unixcision.uniconnect.android.data.AndroidNotificationConnections
import com.unixcision.uniconnect.android.data.ContentReader
import com.unixcision.uniconnect.android.data.HttpFileSender
import com.unixcision.uniconnect.android.data.NativeFilePutClient
import com.unixcision.uniconnect.android.data.HttpSpeechModelStore
import com.unixcision.uniconnect.android.data.MediaCodecAudioDecoder
import com.unixcision.uniconnect.android.data.MediaRecorderVoice
import com.unixcision.uniconnect.android.data.WhisperTranscription
import com.unixcision.uniconnect.android.data.NativeHostTranscription
import com.unixcision.uniconnect.android.data.NativeNotificationClient
import com.unixcision.uniconnect.android.data.StoredNoticeDeliveryRepository
import com.unixcision.uniconnect.android.data.StoredNoticeNameCatalog
import com.unixcision.uniconnect.android.data.StoredDraftRepository
import com.unixcision.uniconnect.android.data.StoredBoxOverridesRepository
import com.unixcision.uniconnect.android.data.StoredSettingsRepository
import com.unixcision.uniconnect.android.data.StoredUploadHistoryRepository
import com.unixcision.uniconnect.android.domain.AudioDecoder
import com.unixcision.uniconnect.android.domain.Dictation
import com.unixcision.uniconnect.android.domain.FilePutClient
import com.unixcision.uniconnect.android.domain.FileSender
import com.unixcision.uniconnect.android.domain.HostDictation
import com.unixcision.uniconnect.android.domain.HostTranscription
import com.unixcision.uniconnect.android.domain.LocalDictation
import com.unixcision.uniconnect.android.domain.LocalTranscription
import com.unixcision.uniconnect.android.domain.SpeechModelStore
import com.unixcision.uniconnect.android.domain.VoiceRecorder
import com.unixcision.uniconnect.android.domain.NotificationClient
import com.unixcision.uniconnect.android.domain.NoticeDeliveryRepository
import com.unixcision.uniconnect.android.domain.NoticeNameCatalog
import com.unixcision.uniconnect.android.domain.DraftRepository
import com.unixcision.uniconnect.android.domain.BoxOverridesRepository
import com.unixcision.uniconnect.android.domain.MachineClient
import com.unixcision.uniconnect.android.domain.MachineRepository
import com.unixcision.uniconnect.android.domain.SettingsRepository
import com.unixcision.uniconnect.android.domain.UploadHistoryRepository
import java.io.File
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
    val settings: SettingsRepository = StoredSettingsRepository(store)
    val rpc = FramedRpcClient(ioScope)
    val machineClient: MachineClient = NativeMachineClient(rpc)
    val notificationConnections = AndroidNotificationConnections(context, store, ioScope)
    val noticeDeliveries: NoticeDeliveryRepository = StoredNoticeDeliveryRepository(store)
    val noticeNames: NoticeNameCatalog = StoredNoticeNameCatalog(store)
    val drafts: DraftRepository = StoredDraftRepository(store)
    val boxOverrides: BoxOverridesRepository = StoredBoxOverridesRepository(store)
    val notificationClient: NotificationClient = NativeNotificationClient(rpc)
    val fileSender: FileSender = HttpFileSender()
    val uploadHistory: UploadHistoryRepository = StoredUploadHistoryRepository(store)
    val contentReader = ContentReader(context.contentResolver)
    val filePutClient: FilePutClient = NativeFilePutClient(rpc)
    val dictation: Dictation = AndroidDictation(context)
    val voiceRecorder: VoiceRecorder = MediaRecorderVoice(context)
    val hostTranscription: HostTranscription = NativeHostTranscription(rpc)
    val hostDictation = HostDictation(voiceRecorder, hostTranscription, ioScope)
    // Models live beside the app's own files: uninstalling takes them, and nothing else can read them.
    val speechModels: SpeechModelStore = HttpSpeechModelStore(File(context.filesDir, "whisper"), ioScope)
    val audioDecoder: AudioDecoder = MediaCodecAudioDecoder()
    val localTranscription: LocalTranscription = WhisperTranscription()
    val localDictation = LocalDictation(voiceRecorder, audioDecoder, localTranscription, speechModels, ioScope)
}
