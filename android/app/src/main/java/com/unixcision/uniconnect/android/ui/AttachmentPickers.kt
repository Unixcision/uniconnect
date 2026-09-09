package com.unixcision.uniconnect.android.ui

import android.content.Context
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.FileProvider
import com.unixcision.uniconnect.android.R
import java.io.File

/** The three ways a file gets into the app, ready to launch. */
class AttachmentPickers(val takePhoto: () -> Unit, val pickImages: () -> Unit, val pickFiles: () -> Unit)

/**
 * The pickers "Enviar archivos" and "Adjuntar" share: the system photo picker, the document
 * picker and a camera app writing into a file this app provides. None needs a declared
 * permission. [onPicked] receives the URIs; [onUnavailable] a message when the phone has no app
 * for the request.
 */
@Composable
fun rememberAttachmentPickers(onPicked: (List<Uri>) -> Unit, onUnavailable: (Int) -> Unit): AttachmentPickers {
    val context = LocalContext.current
    val picked by rememberUpdatedState(onPicked)
    val unavailable by rememberUpdatedState(onUnavailable)
    val pickImages = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia()) { uris -> picked(uris) }
    val pickFiles = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris -> picked(uris) }
    // The photo's destination survives the camera app taking over the screen.
    var photo by rememberSaveable { mutableStateOf<Uri?>(null) }
    val takePhoto = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { taken ->
        val target = photo
        photo = null
        if (taken && target != null) picked(listOf(target))
    }
    return remember {
        AttachmentPickers(
            takePhoto = {
                val target = newPhotoUri(context)
                photo = target
                runCatching { takePhoto.launch(target) }.onFailure { photo = null; unavailable(R.string.upload_no_camera) }
            },
            pickImages = {
                runCatching { pickImages.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo)) }.onFailure { unavailable(R.string.upload_no_picker) }
            },
            pickFiles = {
                runCatching { pickFiles.launch(arrayOf("*/*")) }.onFailure { unavailable(R.string.upload_no_picker) }
            },
        )
    }
}

/** A fresh file under the app's own cache for a camera app to write into, shared through the FileProvider. */
private fun newPhotoUri(context: Context): Uri {
    val directory = File(context.cacheDir, "photos").apply { mkdirs() }
    val file = File(directory, "IMG_${System.currentTimeMillis()}.jpg")
    return FileProvider.getUriForFile(context, "${context.packageName}.files", file)
}
