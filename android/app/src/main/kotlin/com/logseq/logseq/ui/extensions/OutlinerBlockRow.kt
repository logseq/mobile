package com.logseq.logseq.ui.extensions

import android.content.ClipData
import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.draganddrop.dragAndDropSource
import androidx.compose.foundation.draganddrop.dragAndDropTarget
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draganddrop.DragAndDropEvent
import androidx.compose.ui.draganddrop.DragAndDropTarget
import androidx.compose.ui.draganddrop.DragAndDropTransferData
import androidx.compose.ui.draganddrop.toAndroidDragEvent
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.changedToUpIgnoreConsumed
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onPlaced
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.logseq.logseq.runtime.logseqIconResolver
import dev.lui.LuiExtensionContext
import dev.lui.LuiExtensionEventSchema
import dev.lui.LuiExtensionProperty
import dev.lui.LuiExtensionRegistry
import dev.lui.LuiExtensionValueKind
import dev.lui.luiThemeColor
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject

private const val OUTLINER_BLOCK_ROW_FINGERPRINT =
    "lui-extension-v1|18:outliner-block-row|profiles:android/kotlin,ios/swiftui|" +
        "standard-children:1|children:|" +
        "properties:7:payload:string:required:none|" +
        "events:10:drag-start[4:uuid:string:required]," +
        "10:long-press[4:uuid:string:required]," +
        "10:remove-tag[4:uuid:string:required]," +
        "10:set-status[4:uuid:string:required,5:count:int:required]," +
        "11:menu-action[7:payload:string:required]," +
        "12:set-priority[8:priority:string:required]," +
        "16:toggle-selection[4:uuid:string:required]," +
        "4:drop[4:uuid:string:required,9:placement:string:required]," +
        "4:edit[18:caret-utf16-offset:int:optional,4:uuid:string:required]," +
        "8:collapse[4:uuid:string:required]," +
        "9:open-node[4:uuid:string:required]"

internal fun LuiExtensionRegistry.registerOutlinerBlockRow(
    resolveAssetPath: (String) -> String,
    youtubeStarts: MutableMap<String, Int>,
    onOpenImage: ((String, String) -> Unit)? = null,
    loadImage: (suspend (String, String) -> String)? = null,
) {
    val uuid = LuiExtensionProperty("uuid", LuiExtensionValueKind.STRING, required = true)
    register(
        "outliner-block-row",
        OUTLINER_BLOCK_ROW_FINGERPRINT,
        acceptsStandardChildren = true,
        properties = listOf(
            LuiExtensionProperty("payload", LuiExtensionValueKind.STRING, required = true),
        ),
        events = listOf(
            LuiExtensionEventSchema("edit", listOf(
                uuid,
                LuiExtensionProperty("caret-utf16-offset", LuiExtensionValueKind.INTEGER, required = false),
            )),
            LuiExtensionEventSchema("open-node", listOf(uuid)),
            LuiExtensionEventSchema("remove-tag", listOf(uuid)),
            LuiExtensionEventSchema("collapse", listOf(uuid)),
            LuiExtensionEventSchema("long-press", listOf(uuid)),
            LuiExtensionEventSchema("drag-start", listOf(uuid)),
            LuiExtensionEventSchema("toggle-selection", listOf(uuid)),
            LuiExtensionEventSchema("menu-action", listOf(
                LuiExtensionProperty("payload", LuiExtensionValueKind.STRING, required = true),
            )),
            LuiExtensionEventSchema("drop", listOf(
                uuid,
                LuiExtensionProperty("placement", LuiExtensionValueKind.STRING, required = true),
            )),
            LuiExtensionEventSchema("set-priority", listOf(
                LuiExtensionProperty("priority", LuiExtensionValueKind.STRING, required = true),
            )),
            LuiExtensionEventSchema("set-status", listOf(
                uuid,
                LuiExtensionProperty("count", LuiExtensionValueKind.INTEGER, required = true),
            )),
        ),
    ) {
        OutlinerBlockRow(this, resolveAssetPath, youtubeStarts, onOpenImage, loadImage)
    }
}

private data class OutlinerRowStatus(val uuid: String, val title: String, val icon: String, val foreground: String)
private data class OutlinerRowPriority(val uuid: String, val title: String, val icon: String)
private data class OutlinerRowTag(val uuid: String, val title: String)

private data class OutlinerRowPayload(
    val raw: JSONObject,
    val uuid: String,
    val title: String,
    val embedSourceUuid: String?,
    val listNumber: Int?,
    val nodeIconJson: String?,
    val markupJson: String,
    val plainText: String?,
    val depth: Int,
    val hasChildren: Boolean,
    val collapsed: Boolean,
    val isAsset: Boolean,
    val assetType: String,
    val localPath: String,
    val completed: Boolean,
    val selectionMode: Boolean,
    val selectionMember: Boolean,
    val editing: Boolean,
    val allowsDrag: Boolean,
    val hasCustomContent: Boolean,
    val openLabel: String,
    val collapseLabel: String,
    val status: OutlinerRowStatus?,
    val statuses: List<OutlinerRowStatus>,
    val priority: OutlinerRowPriority?,
    val tags: List<OutlinerRowTag>,
)

private fun parseOutlinerRowPayload(encoded: String?): OutlinerRowPayload? {
    if (encoded.isNullOrEmpty()) return null
    val raw = runCatching { JSONObject(encoded) }.getOrNull() ?: return null
    val statusObj = raw.optJSONObject("status")
    val status = statusObj?.let {
        OutlinerRowStatus(
            uuid = it.optString("uuid"),
            title = it.optString("title"),
            icon = it.optString("icon"),
            foreground = it.optString("foreground"),
        )
    }
    val statuses = if (status == null) emptyList() else parseRowStatuses(raw)
    val priorityObj = raw.optJSONObject("priority")
    val priority = priorityObj?.let {
        OutlinerRowPriority(
            uuid = it.optString("uuid"),
            title = it.optString("title"),
            icon = it.optString("icon"),
        )
    }
    val tagsArray = raw.optJSONArray("tags")
    val tags = if (tagsArray == null || tagsArray.length() == 0) emptyList() else {
        List(tagsArray.length()) { index ->
            val item = tagsArray.getJSONObject(index)
            OutlinerRowTag(uuid = item.optString("uuid"), title = item.optString("title"))
        }
    }
    val nodeIconObj = raw.optJSONObject("nodeIcon")
    val title = raw.optString("title")
    val markupArray = raw.optJSONArray("markup")
    val plainText = when {
        markupArray == null || markupArray.length() == 0 -> title
        markupArray.length() == 1 -> {
            val first = markupArray.optJSONObject(0)
            if (first?.optString("type") == "text") first.optString("text", title) else null
        }
        else -> null
    }
    val markup = if (plainText != null) "" else markupArray?.toString() ?: "[]"
    return OutlinerRowPayload(
        raw = raw,
        uuid = raw.optString("uuid"),
        title = title,
        embedSourceUuid = raw.optString("embedSourceUuid").takeIf { it.isNotEmpty() },
        listNumber = if (raw.isNull("listNumber")) null else raw.optInt("listNumber"),
        nodeIconJson = nodeIconObj?.toString(),
        markupJson = markup,
        plainText = plainText,
        depth = raw.optInt("depth"),
        hasChildren = raw.optBoolean("hasChildren"),
        collapsed = raw.optBoolean("collapsed"),
        isAsset = raw.optBoolean("isAsset"),
        assetType = raw.optString("assetType"),
        localPath = raw.optString("localPath"),
        completed = raw.optBoolean("completed"),
        selectionMode = raw.optBoolean("selectionMode"),
        selectionMember = raw.optBoolean("selectionMember"),
        editing = raw.optBoolean("editing"),
        allowsDrag = raw.optBoolean("allowsDrag", true),
        hasCustomContent = raw.optBoolean("hasCustomContent"),
        openLabel = raw.optString("openLabel"),
        collapseLabel = raw.optString("collapseLabel"),
        status = status,
        statuses = statuses,
        priority = priority,
        tags = tags,
    )
}

private fun parseRowStatuses(raw: JSONObject): List<OutlinerRowStatus> {
    val statusesArray = raw.optJSONArray("statuses")
    if (statusesArray == null || statusesArray.length() == 0) return emptyList()
    return List(statusesArray.length()) { index ->
        val item = statusesArray.getJSONObject(index)
        OutlinerRowStatus(
            uuid = item.optString("uuid"),
            title = item.optString("title"),
            icon = item.optString("icon"),
            foreground = item.optString("foreground"),
        )
    }
}

private fun buildMenuActionsJson(row: OutlinerRowPayload): JSONObject {
    val raw = row.raw
    val statuses = row.statuses.ifEmpty { parseRowStatuses(raw) }
    val statusesJson = JSONArray()
    for (s in statuses) {
        statusesJson.put(
            JSONObject()
                .put("title", s.title)
                .put("icon", s.icon)
                .put("foreground", s.foreground)
                .put("selected", row.status?.uuid == s.uuid),
        )
    }
    return JSONObject()
        .put("isTask", raw.optBoolean("isTask"))
        .put("selectionMode", row.selectionMode)
        .put("selectionMember", row.selectionMember)
        .put("allowsDrag", row.allowsDrag)
        .put("discussionsAvailable", raw.optBoolean("discussionsAvailable"))
        .put("labels", raw.optJSONObject("menuLabels") ?: JSONObject())
        .put("statuses", statusesJson)
        .put("reactions", raw.optJSONArray("reactionChoices") ?: JSONArray())
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun OutlinerBlockRow(
    context: LuiExtensionContext,
    resolveAssetPath: (String) -> String,
    youtubeStarts: MutableMap<String, Int>,
    onOpenImage: ((String, String) -> Unit)?,
    loadImage: (suspend (String, String) -> String)?,
) {
    val payloadJson = context.string("payload")
    val row = remember(payloadJson) { parseOutlinerRowPayload(payloadJson) } ?: return
    val currentContext by rememberUpdatedState(context)
    val guideColor = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.18f)
    val bulletColor = if (row.collapsed && row.hasChildren) {
        MaterialTheme.colorScheme.onSurfaceVariant
    } else {
        MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.72f)
    }
    val guideCount = row.depth + if (row.hasChildren && !row.collapsed) 1 else 0
    val bulletDepth = if (row.hasChildren && !row.collapsed) row.depth else -1
    val markerInset = row.depth * 22 + if (row.listNumber != null) 0 else 3

    val guideModifier = if (guideCount <= 0) {
        Modifier.fillMaxWidth()
    } else {
        Modifier.fillMaxWidth().drawBehind {
            val stroke = 1.dp.toPx()
            for (level in 0 until guideCount) {
                val x = (12 + level * 22).dp.toPx()
                val top = if (level == bulletDepth) 17.5.dp.toPx() else 0f
                if (size.height > top) {
                    drawLine(guideColor, Offset(x, top), Offset(x, size.height), strokeWidth = stroke)
                }
            }
        }
    }

    val rowBody: @Composable () -> Unit = {
        OutlinerRowSwipeContainer(
            blockId = row.uuid,
            enabled = !row.editing,
            markerInsetDp = markerInset,
            onToggleSelection = { currentContext.emit("toggle-selection", "uuid" to row.uuid) },
        ) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp),
                verticalAlignment = Alignment.Top,
            ) {
                if (row.depth > 0) {
                    Spacer(Modifier.width((row.depth * 22).dp))
                }
                val zoomTarget = row.embedSourceUuid ?: row.uuid
                Box(
                    modifier = Modifier
                        .size(24.dp)
                        .semantics {
                            testTag = "button.outliner.zoom.${row.uuid}.${row.title}"
                            testTagsAsResourceId = true
                            if (row.openLabel.isNotEmpty()) contentDescription = row.openLabel
                        }
                        .clickable { currentContext.emit("open-node", "uuid" to zoomTarget) },
                    contentAlignment = Alignment.Center,
                ) {
                    when {
                        row.listNumber != null -> Text(
                            text = "${row.listNumber}.",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        row.nodeIconJson != null -> NodeIcon(row.nodeIconJson, size = 18, muted = false)
                        else -> Box(
                            Modifier
                                .size(24.dp)
                                .semantics {
                                    testTag = "outliner.bullet-glyph.${row.uuid}"
                                    testTagsAsResourceId = true
                                }
                                .drawBehind {
                                    if (row.collapsed && row.hasChildren) {
                                        drawCircle(
                                            color = bulletColor.copy(alpha = 0.22f),
                                            radius = 6.dp.toPx(),
                                        )
                                    }
                                    drawCircle(color = bulletColor, radius = 2.75.dp.toPx())
                                },
                        )
                    }
                }
                Spacer(Modifier.width(2.dp))
                if (row.hasCustomContent) {
                    Box(Modifier.weight(1f)) {
                        context.Children()
                    }
                } else if (row.status == null && row.priority == null && row.tags.isEmpty()) {
                    OutlinerRowRichBody(
                        modifier = Modifier.weight(1f),
                        context = context,
                        row = row,
                        resolveAssetPath = resolveAssetPath,
                        youtubeStarts = youtubeStarts,
                        onOpenImage = onOpenImage,
                        loadImage = loadImage,
                    )
                } else {
                    Box(Modifier.weight(1f)) {
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
                            row.status?.let { status ->
                                val statusIcon = logseqIconResolver.icon(status.icon)
                                val statusColor = luiThemeColor(status.foreground, foreground = true)
                                    ?: MaterialTheme.colorScheme.onSurfaceVariant
                                val nextIndex = if (row.statuses.isEmpty()) 0 else {
                                    val idx = row.statuses.indexOfFirst { it.uuid == status.uuid }
                                    if (idx < 0) 0 else (idx + 1) % row.statuses.size
                                }
                                Box(
                                    Modifier
                                        .padding(top = 2.dp, end = 4.dp)
                                        .size(20.dp)
                                        .semantics {
                                            testTag = "button.block-task-status"
                                            testTagsAsResourceId = true
                                        }
                                        .clickable {
                                            currentContext.emit(
                                                "set-status",
                                                "uuid" to row.uuid,
                                                "count" to nextIndex,
                                            )
                                        },
                                    contentAlignment = Alignment.Center,
                                ) {
                                    if (statusIcon != null) {
                                        Icon(statusIcon, contentDescription = status.title, tint = statusColor, modifier = Modifier.size(18.dp))
                                    }
                                }
                            }
                            row.priority?.let { priority ->
                                val priorityIcon = logseqIconResolver.icon(priority.icon)
                                if (priorityIcon != null) {
                                    Icon(
                                        priorityIcon,
                                        contentDescription = priority.title,
                                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                        modifier = Modifier.padding(top = 3.dp, end = 4.dp).size(16.dp),
                                    )
                                }
                            }
                            Column(Modifier.weight(1f)) {
                                OutlinerRowRichBody(
                                    modifier = Modifier.fillMaxWidth(),
                                    context = context,
                                    row = row,
                                    resolveAssetPath = resolveAssetPath,
                                    youtubeStarts = youtubeStarts,
                                    onOpenImage = onOpenImage,
                                    loadImage = loadImage,
                                )
                                if (row.tags.isNotEmpty()) {
                                    FlowRow(
                                        modifier = Modifier.padding(top = 2.dp),
                                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                                        verticalArrangement = Arrangement.spacedBy(2.dp),
                                    ) {
                                        row.tags.forEach { tag ->
                                            Text(
                                                text = "#${tag.title}",
                                                fontSize = 13.sp,
                                                color = luiThemeColor("link", foreground = true)
                                                    ?: MaterialTheme.colorScheme.primary,
                                                modifier = Modifier.clickable {
                                                    currentContext.emit("open-node", "uuid" to tag.uuid)
                                                },
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if (row.hasChildren) {
                    val chevron = logseqIconResolver.icon(if (row.collapsed) "chevron-right" else "chevron-down")
                    Box(
                        modifier = Modifier
                            .size(24.dp)
                            .semantics {
                                testTag = "button.outliner.collapse.${row.uuid}"
                                testTagsAsResourceId = true
                                if (row.collapseLabel.isNotEmpty()) contentDescription = row.collapseLabel
                            }
                            .clickable { currentContext.emit("collapse", "uuid" to row.uuid) },
                        contentAlignment = Alignment.Center,
                    ) {
                        if (chevron != null) {
                            Icon(
                                chevron,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(16.dp),
                            )
                        }
                    }
                }
            }
        }
    }
    if (guideCount <= 0) {
        rowBody()
    } else {
        Box(guideModifier) {
            rowBody()
        }
    }
}

@Suppress("DEPRECATION")
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun OutlinerRowRichBody(
    modifier: Modifier = Modifier,
    context: LuiExtensionContext,
    row: OutlinerRowPayload,
    resolveAssetPath: (String) -> String,
    youtubeStarts: MutableMap<String, Int>,
    onOpenImage: ((String, String) -> Unit)?,
    loadImage: (suspend (String, String) -> String)?,
) {
    val uuid = row.uuid
    val linkOnly = remember(row.plainText, row.markupJson) {
        row.plainText == null && isLinkOnlyMarkup(row.markupJson)
    }
    val currentContext by rememberUpdatedState(context)
    val haptics by rememberUpdatedState(LocalHapticFeedback.current)
    var menuOpen by remember(uuid) { mutableStateOf(false) }
    val actions = remember(menuOpen, row) { if (!menuOpen) null else buildMenuActionsJson(row) }
    val tapEvent = if (row.selectionMode) "toggle-selection" else "edit"
    val pressBlock: () -> Unit = { currentContext.emit(tapEvent, "uuid" to uuid) }
    val gesturePolicy by rememberUpdatedState(
        OutlinerGesturePolicy(
            takesTap = !row.isAsset && (!linkOnly || row.selectionMode),
            tapEvent = tapEvent,
            allowsDrag = row.allowsDrag,
            hasMenu = true,
        ),
    )
    val rowBounds = remember { object { var coords: LayoutCoordinates? = null } }
    val density = LocalDensity.current.density
    var hoverPlacement by remember { mutableStateOf("after") }
    var dragHover by remember { mutableStateOf(false) }
    val targetHoverColor = when {
        dragHover -> MaterialTheme.colorScheme.primaryContainer
        menuOpen && !row.selectionMember ->
            (luiThemeColor("link", foreground = true) ?: MaterialTheme.colorScheme.primary).copy(alpha = 0.24f)
        else -> Color.Transparent
    }
    val hoverColor = if (targetHoverColor == Color.Transparent) {
        Color.Transparent
    } else {
        animateColorAsState(targetHoverColor, label = "dropHighlight").value
    }
    val dropTarget = remember(uuid, density) {
        object : DragAndDropTarget {
            private fun placement(event: DragAndDropEvent): String? {
                val drag = event.toAndroidDragEvent()
                val origin = drag.localState as? OutlinerDragOrigin ?: return null
                if (origin.uuid == uuid) return null
                val coords = rowBounds.coords?.takeIf { it.isAttached } ?: return null
                val pos = coords.positionInRoot()
                return outlinerDropPlacement(
                    (drag.y - pos.y) / density,
                    coords.size.height / density,
                    (drag.x - pos.x) / density,
                    (drag.x - origin.x) / density,
                )
            }
            override fun onDrop(event: DragAndDropEvent): Boolean {
                dragHover = false
                val placement = placement(event) ?: return false
                currentContext.emit("drop", "uuid" to uuid, "placement" to placement)
                return true
            }
            override fun onEntered(event: DragAndDropEvent) = onMoved(event)
            override fun onMoved(event: DragAndDropEvent) {
                val placement = placement(event)
                dragHover = placement != null
                if (placement != null) hoverPlacement = placement
            }
            override fun onExited(event: DragAndDropEvent) { dragHover = false }
            override fun onEnded(event: DragAndDropEvent) { dragHover = false }
        }
    }
    val decoration = if (row.completed) TextDecoration.LineThrough else TextDecoration.None
    val bodyModifier = modifier
        .fillMaxWidth()
        .then(if (hoverColor == Color.Transparent) Modifier else Modifier.background(hoverColor, RoundedCornerShape(8.dp)))
        .onPlaced { rowBounds.coords = it }
        .dragAndDropSource(block = {
            while (true) {
                val down = awaitPointerEventScope { awaitFirstDown(requireUnconsumed = false) }
                val policy = gesturePolicy
                var longPressed = false
                val up = withTimeoutOrNull(viewConfiguration.longPressTimeoutMillis) {
                    awaitPointerEventScope { awaitOutlinerTap(down) }
                }
                if (up != null) {
                    if (policy.takesTap) currentContext.emit(policy.tapEvent, "uuid" to uuid)
                    continue
                }
                val stillDown = awaitPointerEventScope {
                    val event = currentEvent
                    event.changes.singleOrNull { it.id == down.id }?.let {
                        it.pressed && !it.isConsumed &&
                            (it.position - down.position).getDistance() <= viewConfiguration.touchSlop
                    } == true
                }
                if (!stillDown) continue
                longPressed = true
                haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                val originX = rowBounds.coords?.takeIf { it.isAttached }?.positionInRoot()?.x ?: 0f
                val origin = OutlinerDragOrigin(uuid, originX + down.position.x)
                while (longPressed) {
                    val pointer = awaitPointerEventScope {
                        awaitPointerEvent(PointerEventPass.Main).changes.firstOrNull { it.id == down.id }
                    } ?: break
                    if (pointer.changedToUpIgnoreConsumed() || !pointer.pressed) {
                        menuOpen = true
                        break
                    }
                    if (policy.allowsDrag && (pointer.position - down.position).getDistance() >= viewConfiguration.touchSlop) {
                        currentContext.emit("drag-start", "uuid" to uuid)
                        startTransfer(DragAndDropTransferData(ClipData.newPlainText("Logseq block", uuid), localState = origin))
                        break
                    }
                }
            }
        })
        .then(
            if (!row.allowsDrag) Modifier else Modifier.dragAndDropTarget(
                shouldStartDragAndDrop = {
                    (it.toAndroidDragEvent().localState as? OutlinerDragOrigin)?.uuid?.let { s -> s != uuid } == true
                },
                target = dropTarget,
            ),
        )
        .testTag("outliner-block-content-$uuid")

    Box(bodyModifier) {
        if (row.isAsset) {
            ProjectedAsset(
                uuid = uuid,
                loadImage = loadImage,
                title = row.title,
                assetType = row.assetType,
                localPath = resolveAssetPath(row.localPath),
                preview = false,
                onPreview = if (row.selectionMode) ({ _ -> pressBlock() }) else onOpenImage?.let { open ->
                    { path -> open(uuid, path) }
                },
                onBlockMenu = { menuOpen = true },
                blockMenuLabel = row.raw.optJSONObject("menuLabels")?.optString("More actions", "More actions") ?: "More actions",
            )
        } else if (row.plainText != null) {
            Text(
                text = row.plainText,
                style = if (decoration == TextDecoration.None) outlinerBodyStyle
                else outlinerBodyStyle.copy(textDecoration = decoration),
            )
        } else {
            CompositionLocalProvider(
                LocalShowCodeLanguage provides true,
                LocalOutlinerBlockActions provides true,
                LocalOutlinerSelection provides row.selectionMode,
                LocalOutlinerInteraction provides null,
            ) {
                ProjectedMarkup(
                    youtubeStarts = youtubeStarts,
                    encoded = row.markupJson,
                    fallback = row.title,
                    completedDecoration = decoration,
                    onOpenNode = { currentContext.emit("open-node", "uuid" to it) },
                    onTapFallback = pressBlock,
                )
            }
        }
        if (menuOpen && actions != null) {
            AndroidBlockActionMenu(
                actions = actions,
                canEdit = linkOnly,
                canCut = !LocalPropertyValue.current,
                expanded = menuOpen,
                onDismiss = { menuOpen = false },
                onAction = { action ->
                    if (action == "edit") currentContext.emit("edit", "uuid" to uuid)
                    else currentContext.emit("menu-action", "payload" to action)
                },
                onStatus = { index -> currentContext.emit("set-status", "uuid" to uuid, "count" to index) },
            )
        }
        if (dragHover) {
            val indicator = MaterialTheme.colorScheme.primary
            Canvas(Modifier.matchParentSize().testTag("outliner.drop.$hoverPlacement")) {
                val y = if (hoverPlacement == "before") 1.dp.toPx() else size.height - 1.dp.toPx()
                val start = if (hoverPlacement == "inside") 20.dp.toPx() else 0f
                drawLine(indicator, Offset(start, y), Offset(size.width, y), strokeWidth = 2.dp.toPx())
                drawCircle(indicator, radius = 3.dp.toPx(), center = Offset(start + 3.dp.toPx(), y))
            }
        }
    }
}
