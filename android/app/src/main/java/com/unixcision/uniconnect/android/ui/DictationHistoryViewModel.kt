package com.unixcision.uniconnect.android.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.unixcision.uniconnect.android.domain.DictationHistory
import com.unixcision.uniconnect.android.domain.DictationRecord
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/** The dictation history for the screen: the list as it changes, and deletions off the main thread. */
class DictationHistoryViewModel(private val history: DictationHistory) : ViewModel() {
    val records: StateFlow<List<DictationRecord>> = history.records

    fun delete(ids: Set<String>) {
        if (ids.isNotEmpty()) viewModelScope.launch(Dispatchers.IO) { history.delete(ids) }
    }

    fun deleteAudio(ids: Set<String>) {
        if (ids.isNotEmpty()) viewModelScope.launch(Dispatchers.IO) { history.deleteAudio(ids) }
    }
}
