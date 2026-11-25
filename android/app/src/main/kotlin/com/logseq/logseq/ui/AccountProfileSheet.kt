package com.logseq.logseq.ui

import android.content.ContentResolver
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import com.logseq.logseq.AccountProfile
import com.logseq.logseq.R
import com.logseq.logseq.profileAvatar
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@OptIn(ExperimentalMaterial3Api::class)
@Composable internal fun AccountProfileSheet(
    readProfile: suspend () -> AccountProfile,
    updateProfile: suspend (String, ByteArray?) -> Unit,
    dismiss: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf("") }
    var originalName by remember { mutableStateOf("") }
    var originalPhoto by remember { mutableStateOf<Bitmap?>(null) }
    var photo by remember { mutableStateOf<ByteArray?>(null) }
    var loading by remember { mutableStateOf(true) }
    var saving by remember { mutableStateOf(false) }
    var processing by remember { mutableStateOf(false) }
    var loadFailed by remember { mutableStateOf(false) }
    var error by remember { mutableIntStateOf(0) }
    var photoJob by remember { mutableStateOf<Job?>(null) }

    suspend fun load() {
        loading = true
        loadFailed = false
        error = 0
        try {
            val profile = readProfile()
            name = profile.fullName
            originalName = profile.fullName
            originalPhoto = profile.photo?.let { withContext(Dispatchers.IO) { profileAvatar(it) } }
        } catch (failure: CancellationException) {
            throw failure
        } catch (_: Exception) {
            loadFailed = true
            error = R.string.account_profile_load_failed
        } finally {
            loading = false
        }
    }
    LaunchedEffect(Unit) { load() }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        photoJob?.cancel()
        photoJob = scope.launch {
            processing = true
            error = 0
            try {
                photo = withContext(Dispatchers.IO) { compressPhoto(context.contentResolver, uri) }
            } catch (failure: CancellationException) {
                throw failure
            } catch (_: Exception) {
                error = R.string.account_profile_photo_failed
            } finally {
                processing = false
            }
        }
    }

    ModalBottomSheet(onDismissRequest = { if (!saving) dismiss() }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
                Text(stringResource(R.string.account_profile_edit), style = MaterialTheme.typography.titleLarge)
                TextButton(onClick = dismiss, enabled = !saving) { Text(stringResource(android.R.string.cancel)) }
            }
            if (loading) CircularProgressIndicator()
            else if (loadFailed) {
                TextButton(onClick = { scope.launch { load() } }) { Text(stringResource(R.string.account_profile_retry)) }
            } else {
                val preview = remember(photo, originalPhoto) { photo?.let { BitmapFactory.decodeByteArray(it, 0, it.size) } ?: originalPhoto }
                TextButton(enabled = !saving && !processing, onClick = { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }) {
                    if (preview != null) Image(preview.asImageBitmap(), null, Modifier.size(44.dp).clip(CircleShape), contentScale = ContentScale.Crop)
                    else Surface(Modifier.size(44.dp), shape = CircleShape, color = MaterialTheme.colorScheme.secondaryContainer) {
                        Box(contentAlignment = Alignment.Center) { Text(name.take(1).uppercase()) }
                    }
                    Spacer(Modifier.width(12.dp))
                    Text(stringResource(R.string.account_profile_change_photo))
                }
                TextField(value = name, onValueChange = { name = it }, modifier = Modifier.fillMaxWidth().testTag("field.account.full-name"),
                    label = { Text(stringResource(R.string.account_profile_full_name)) }, singleLine = true,
                    enabled = !saving, keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words))
                Button(
                    enabled = !processing && !saving && name.codePointCount(0, name.length) <= 80 &&
                        (name.isNotBlank() || originalName.isEmpty()) && (name.trim() != originalName || photo != null),
                    onClick = {
                        scope.launch {
                            saving = true
                            error = 0
                            try {
                                updateProfile(name.trim(), photo)
                                dismiss()
                            } catch (failure: CancellationException) {
                                throw failure
                            } catch (_: Exception) {
                                error = R.string.account_profile_save_failed
                            } finally {
                                saving = false
                            }
                        }
                    },
                ) { Text(stringResource(R.string.account_profile_save)) }
            }
            if (error != 0) Text(stringResource(error), color = MaterialTheme.colorScheme.error)
        }
    }
}

private fun compressPhoto(resolver: ContentResolver, uri: Uri): ByteArray {
    val photo = ImageDecoder.decodeBitmap(ImageDecoder.createSource(resolver, uri)) { decoder, info, _ ->
        decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        val longest = maxOf(info.size.width, info.size.height)
        if (longest > 512) decoder.setTargetSize(
            maxOf(1, info.size.width.toLong().times(512).div(longest).toInt()),
            maxOf(1, info.size.height.toLong().times(512).div(longest).toInt()),
        )
    }
    return compressProfilePhoto(photo)
}

internal fun compressProfilePhoto(photo: Bitmap): ByteArray {
    val longest = maxOf(photo.width, photo.height)
    for (size in listOf(512, 448, 384)) {
        val resized = if (size >= longest) photo else Bitmap.createScaledBitmap(photo,
            maxOf(1, photo.width * size / longest), maxOf(1, photo.height * size / longest), true)
        for (quality in listOf(90, 82, 74)) {
            val bytes = ByteArrayOutputStream()
            if (resized.compress(Bitmap.CompressFormat.JPEG, quality, bytes) && bytes.size() <= 128 * 1024) return bytes.toByteArray()
        }
    }
    error("The photo exceeds the avatar upload limit")
}
