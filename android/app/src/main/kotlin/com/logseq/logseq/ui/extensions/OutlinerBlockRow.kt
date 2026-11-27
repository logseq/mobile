package com.logseq.logseq.ui.extensions

import android.content.ClipData
import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.draganddrop.dragAndDropSource
import androidx.compose.foundation.draganddrop.dragAndDropTarget
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
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
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onPlaced
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.onLongClick
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.logseq.logseq.runtime.logseqIconResolver
import com.logseq.logseq.runtime.masterIcons
import dev.lui.LuiExtensionContext
import dev.lui.LuiExtensionEventSchema
import dev.lui.LuiExtensionProperty
import dev.lui.LuiExtensionRegistry
import dev.lui.LuiExtensionValueKind
import dev.lui.luiThemeColor
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

private data class OutlinerRowStatus(
    val uuid: String,
    val title: String,
    val icon: String,
    val foreground: String,
    val optionId: String,
)
private data class OutlinerRowPriority(val uuid: String, val title: String, val icon: String)
private data class OutlinerRowTag(val uuid: String, val title: String)

private data class OutlinerRowPayload(
    val raw: JSONObject,
    val uuid: String,
    val title: String,
    val embedSourceUuid: String?,
    val pdfPage: Int?,
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
    val selected: Boolean,
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
            optionId = it.optString("optionId"),
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
        embedSourceUuid = if (raw.isNull("embedSourceUuid")) null else raw.optString("embedSourceUuid").ifEmpty { null },
        pdfPage = raw.optJSONObject("pdfAnnotation")?.optInt("page"),
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
        selected = raw.optBoolean("selected"),
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
            optionId = item.optString("optionId"),
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
        .put("isComment", raw.optBoolean("isComment"))
        .put("discussionsAvailable", raw.optBoolean("discussionsAvailable"))
        .put("labels", raw.optJSONObject("menuLabels") ?: JSONObject())
        .put("statuses", statusesJson)
        .put("reactionChoices", raw.optJSONArray("reactionChoices") ?: JSONArray())
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
    var menuOpen by remember(row.uuid) { mutableStateOf(false) }
    var menuHeld by remember(row.uuid) { mutableStateOf(false) }
    val highlight = when {
        row.selected -> MaterialTheme.colorScheme.secondaryContainer
        menuOpen || menuHeld -> MaterialTheme.colorScheme.surfaceContainerHighest
        else -> Color.Transparent
    }
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
                modifier = Modifier.fillMaxWidth()
                    .then(
                        if (highlight == Color.Transparent) Modifier
                        else Modifier.background(highlight, RoundedCornerShape(8.dp)),
                    )
                    .padding(vertical = 2.dp),
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
                        .combinedClickable(
                            role = Role.Button,
                            onClick = {
                                if (row.selectionMode) currentContext.emit("toggle-selection", "uuid" to row.uuid)
                                else currentContext.emit("open-node", "uuid" to zoomTarget)
                            },
                            onLongClick = if (row.hasCustomContent) null else ({ menuOpen = true }),
                        ),
                    contentAlignment = Alignment.Center,
                ) {
                    when {
                        row.listNumber != null -> Text(
                            text = "${row.listNumber}.",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        row.nodeIconJson != null -> NodeIcon(row.nodeIconJson, size = 18, muted = false)
                        else -> Icon(
                            imageVector = masterIcons.getValue(
                                if (row.collapsed && row.hasChildren) "outliner-bullet-closed" else "outliner-bullet",
                            ),
                            contentDescription = null,
                            tint = bulletColor,
                            modifier = Modifier
                                .size(24.dp)
                                .semantics {
                                    testTag = "outliner.bullet-glyph.${row.uuid}"
                                    testTagsAsResourceId = true
                                },
                        )
                    }
                }
                Spacer(Modifier.width(2.dp))
                row.status?.let { status ->
                    OutlinerRowPicker(
                        id = "button.block-task-status",
                        title = status.title,
                        icon = status.icon,
                        tint = luiThemeColor(status.foreground, foreground = true),
                        glyphTag = "outliner.task-status-icon.${row.uuid}",
                        iconAlignment = Alignment.CenterStart,
                    ) { dismiss ->
                        row.statuses.forEachIndexed { index, choice ->
                            OutlinerMenuChoice(
                                title = choice.title,
                                icon = choice.icon,
                                selected = choice.optionId == status.optionId,
                                index = index,
                                itemCount = row.statuses.size,
                                tint = luiThemeColor(choice.foreground, foreground = true),
                                modifier = outlinerControlTag(choice.optionId),
                            ) {
                                dismiss()
                                currentContext.emit("set-status", "uuid" to row.uuid, "count" to index)
                            }
                        }
                    }
                }
                row.priority?.let { priority ->
                    OutlinerRowPicker("button.block-task-priority", priority.title, priority.icon) { dismiss ->
                        val choices = row.raw.optJSONArray("priorities")
                        val count = choices?.length() ?: 0
                        for (index in 0 until count) {
                            val choice = choices?.optJSONObject(index) ?: continue
                            val uuid = choice.optString("uuid")
                            OutlinerMenuChoice(
                                title = choice.optString("title"),
                                icon = choice.optString("icon"),
                                selected = uuid == priority.uuid,
                                index = index,
                                itemCount = count + 1,
                                modifier = outlinerControlTag("button.block-task-priority-option.$uuid"),
                            ) {
                                dismiss()
                                currentContext.emit("set-priority", "priority" to uuid)
                            }
                        }
                        BlockActionItem(
                            title = row.raw.optString("clearPriorityTitle", "Clear priority"),
                            icon = "",
                            index = count,
                            itemCount = count + 1,
                            modifier = outlinerControlTag("button.block-task-priority-clear"),
                        ) {
                            dismiss()
                            currentContext.emit("set-priority", "priority" to "")
                        }
                    }
                }
                row.pdfPage?.let { page ->
                    Text(
                        text = "📌 P$page",
                        style = MaterialTheme.typography.labelMedium,
                        color = luiThemeColor("link", foreground = true) ?: MaterialTheme.colorScheme.primary,
                        modifier = outlinerControlTag("pdf.annotation-page.${row.uuid}")
                            .clickable { currentContext.emit("menu-action", "payload" to "open-annotation") }
                            .padding(horizontal = 4.dp, vertical = 6.dp),
                    )
                }
                if (!row.hasCustomContent && row.tags.isEmpty()) {
                    OutlinerRowRichBody(
                        modifier = Modifier.weight(1f),
                        context = context,
                        row = row,
                        resolveAssetPath = resolveAssetPath,
                        youtubeStarts = youtubeStarts,
                        onOpenImage = onOpenImage,
                        loadImage = loadImage,
                        menuOpen = menuOpen,
                        onMenuOpen = { menuOpen = it },
                        onMenuHold = { menuHeld = it },
                    )
                } else {
                    Column(Modifier.weight(1f)) {
                        if (row.hasCustomContent) {
                            context.Children()
                        } else {
                            OutlinerRowRichBody(
                                modifier = Modifier.fillMaxWidth(),
                                context = context,
                                row = row,
                                resolveAssetPath = resolveAssetPath,
                                youtubeStarts = youtubeStarts,
                                onOpenImage = onOpenImage,
                                loadImage = loadImage,
                                menuOpen = menuOpen,
                                onMenuOpen = { menuOpen = it },
                                onMenuHold = { menuHeld = it },
                            )
                        }
                        if (row.tags.isNotEmpty()) {
                            FlowRow(
                                modifier = Modifier.padding(top = 2.dp),
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                                verticalArrangement = Arrangement.spacedBy(2.dp),
                            ) {
                                row.tags.forEach { tag ->
                                    OutlinerRowTagChip(row, tag, currentContext)
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

private fun outlinerControlTag(id: String) = Modifier.semantics {
    testTag = id
    testTagsAsResourceId = true
}

@Composable
private fun OutlinerRowPicker(
    id: String,
    title: String,
    icon: String,
    tint: Color? = null,
    glyphTag: String? = null,
    iconAlignment: Alignment = Alignment.Center,
    content: @Composable ColumnScope.(dismiss: () -> Unit) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        Box(Modifier.size(24.dp), contentAlignment = iconAlignment) {
            logseqIconResolver.icon(icon)?.let {
                Icon(
                    it, contentDescription = null,
                    tint = tint ?: MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = (glyphTag?.let(::outlinerControlTag) ?: Modifier).size(18.dp),
                )
            }
            Box(outlinerControlTag(id)
                .semantics { contentDescription = title }
                .clickable(role = Role.Button) { expanded = true }
                .matchParentSize())
        }
        OutlinerMenuPopup(expanded = expanded, onDismiss = { expanded = false }) {
            OutlinerMenuGroup { content { expanded = false } }
        }
    }
}

@Composable
private fun OutlinerRowTagChip(row: OutlinerRowPayload, tag: OutlinerRowTag, context: LuiExtensionContext) {
    val canRemove = row.raw.optBoolean("canRemoveTags")
    val removeTitle = row.raw.optString("removeTagTitle", "Remove tag")
    var expanded by remember(tag.uuid) { mutableStateOf(false) }
    Box {
        Text(
            text = "#${tag.title}",
            fontSize = 13.sp,
            color = luiThemeColor("link", foreground = true) ?: MaterialTheme.colorScheme.primary,
            modifier = outlinerControlTag("button.block-tag.${tag.uuid}").combinedClickable(
                onClick = { context.emit("open-node", "uuid" to tag.uuid) },
                onLongClick = if (canRemove) ({ expanded = true }) else null,
                onLongClickLabel = if (canRemove) removeTitle else null,
            ),
        )
        if (canRemove) OutlinerMenuPopup(expanded = expanded, onDismiss = { expanded = false }) {
            OutlinerMenuGroup {
                BlockActionItem(
                    title = removeTitle,
                    icon = "toolbar-delete",
                    index = 0,
                    itemCount = 1,
                    destructive = true,
                    modifier = outlinerControlTag("button.block-tag.remove.${row.uuid}.${tag.uuid}"),
                ) {
                    expanded = false
                    context.emit("remove-tag", "uuid" to tag.uuid)
                }
            }
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
    menuOpen: Boolean,
    onMenuOpen: (Boolean) -> Unit,
    onMenuHold: (Boolean) -> Unit,
) {
    val uuid = row.uuid
    val linkOnly = remember(row.plainText, row.markupJson) {
        row.plainText == null && isLinkOnlyMarkup(row.markupJson)
    }
    val currentContext by rememberUpdatedState(context)
    val haptics by rememberUpdatedState(LocalHapticFeedback.current)
    val setMenuOpen by rememberUpdatedState(onMenuOpen)
    val setMenuHeld by rememberUpdatedState(onMenuHold)
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
    val targetHoverColor = if (dragHover) MaterialTheme.colorScheme.primaryContainer else Color.Transparent
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
            awaitEachGesture {
                val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                val mainDown = awaitPointerEvent(PointerEventPass.Main).changes.singleOrNull { it.id == down.id }
                    ?: return@awaitEachGesture
                val childOwnsTap = mainDown.isConsumed
                val policy = gesturePolicy
                val finished = withTimeoutOrNull(viewConfiguration.longPressTimeoutMillis) {
                    val up = awaitOutlinerTap(down)
                    if (up != null && policy.takesTap && !childOwnsTap) {
                        up.consume()
                        currentContext.emit(policy.tapEvent, "uuid" to uuid)
                    }
                    true
                }
                if (finished == true) return@awaitEachGesture

                // A link can own the tap while the parent still recognizes a hold.
                val held = currentEvent.changes.singleOrNull { it.id == down.id && it.pressed }
                    ?: return@awaitEachGesture
                haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                setMenuHeld(true)
                val originX = rowBounds.coords?.takeIf { it.isAttached }?.positionInRoot()?.x ?: 0f
                val origin = OutlinerDragOrigin(uuid, originX + down.position.x)
                try {
                    while (true) {
                        val pointer = awaitPointerEvent(PointerEventPass.Initial).changes
                            .singleOrNull { it.id == down.id } ?: break
                        if (pointer.isConsumed) break
                        pointer.consume()
                        if (!pointer.pressed) {
                            setMenuOpen(true)
                            break
                        }
                        if (policy.allowsDrag && (pointer.position - held.position).getDistance() >= viewConfiguration.touchSlop) {
                            currentContext.emit("drag-start", "uuid" to uuid)
                            startTransfer(DragAndDropTransferData(ClipData.newPlainText("Logseq block", uuid), localState = origin))
                            break
                        }
                    }
                } finally {
                    setMenuHeld(false)
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
        .semantics {
            val label = row.raw.optJSONObject("menuLabels")?.optString("More actions", "More actions") ?: "More actions"
            onLongClick(label = label) {
                onMenuOpen(true)
                true
            }
        }

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
                onBlockMenu = { onMenuOpen(true) },
                blockMenuLabel = row.raw.optJSONObject("menuLabels")?.optString("More actions", "More actions") ?: "More actions",
                onOpenFile = {
                    if (row.selectionMode) pressBlock()
                    else currentContext.emit("menu-action", "payload" to "open-asset")
                },
            )
        } else if (row.plainText != null) {
            Text(
                text = row.plainText,
                style = if (decoration == TextDecoration.None) outlinerBodyStyle
                else outlinerBodyStyle.copy(textDecoration = decoration),
                modifier = Modifier.semantics {
                    onClick(label = row.raw.optString("editLabel").ifEmpty { null }) {
                        pressBlock()
                        true
                    }
                },
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
                onDismiss = { onMenuOpen(false) },
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
