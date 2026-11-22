package com.logseq.logseq

import android.app.Activity
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.PopupWindow
import android.widget.ScrollView
import android.widget.TextView
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.asAndroidPath
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.graphics.vector.VectorPath
import com.logseq.logseq.runtime.WidgetTaskStatusChange
import com.logseq.logseq.runtime.masterIcons
import org.json.JSONObject
import kotlin.math.roundToInt

class WidgetStatusMenuActivity : Activity() {
    private var popup: PopupWindow? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val data = intent?.data ?: return finish()
        val graphId = data.getQueryParameter("graph") ?: return finish()
        val taskId = data.getQueryParameter("task") ?: return finish()
        val current = data.getQueryParameter("current") ?: return finish()
        val content = AndroidWidgetContent.read(this) ?: return finish()
        if (content.optString("graphId") != graphId) return finish()
        val tasks = content.optJSONArray("tasks") ?: return finish()
        val task = (0 until tasks.length()).mapNotNull(tasks::optJSONObject).firstOrNull {
            it.optString("uuid") == taskId && it.optString("statusUuid") == current
        } ?: return finish()
        val choices = task.optJSONArray("statusChoices") ?: return finish()
        if (choices.length() == 0) return finish()

        val root = FrameLayout(this)
        setContentView(root)
        val rows = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        for (index in 0 until choices.length()) {
            val choice = choices.optJSONObject(index) ?: continue
            val uuid = choice.optString("uuid")
            val row = menuRow(choice, selected = uuid == current)
            row.setOnClickListener {
                if (uuid != current) {
                    TaskListWidgetProvider.selectStatus(this, WidgetTaskStatusChange(graphId, taskId, current, uuid))
                }
                popup?.dismiss()
            }
            rows.addView(row, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(44)))
        }
        val scroll = ScrollView(this).apply {
            addView(rows)
            isFillViewport = true
            setPadding(0, dp(4), 0, dp(4))
            background = GradientDrawable().apply {
                cornerRadius = dp(14).toFloat()
                setColor(getColor(R.color.widget_surface))
            }
            clipToOutline = true
        }
        root.post { if (!isFinishing) showMenu(root, scroll, rows.childCount) }
    }

    private fun showMenu(root: View, scroll: View, count: Int) {
        val display = Rect()
        root.getWindowVisibleDisplayFrame(display)
        val requestedWidth = dp(196)
        val width = minOf(requestedWidth, display.width())
        val anchor = intent.sourceBounds
        val availableBelow = (display.bottom - (anchor?.bottom ?: display.top) - dp(4)).coerceAtLeast(0)
        val availableAbove = ((anchor?.top ?: display.top) - display.top - dp(4)).coerceAtLeast(0)
        val wantedHeight = minOf(dp(count * 44 + 8), display.height())
        val below = availableBelow >= wantedHeight || availableBelow >= availableAbove
        val height = minOf(wantedHeight, if (below) availableBelow else availableAbove).coerceAtLeast(1)
        val left = if (root.layoutDirection == View.LAYOUT_DIRECTION_RTL) {
            (anchor?.right ?: display.right - dp(12)) - width
        } else {
            anchor?.left ?: display.left + dp(12)
        }.coerceIn(display.left, display.right - width)
        val top = if (anchor == null) {
            display.top + (display.height() - height) / 2
        } else if (below) {
            anchor.bottom + dp(4)
        } else {
            anchor.top - height - dp(4)
        }.coerceIn(display.top, display.bottom - height)
        popup = PopupWindow(scroll, width, height, true).apply {
            elevation = dp(8).toFloat()
            setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
            isOutsideTouchable = true
            setOnDismissListener { finish() }
            showAtLocation(root, Gravity.TOP or Gravity.LEFT, left, top)
        }
    }

    private fun menuRow(choice: JSONObject, selected: Boolean): LinearLayout {
        val title = choice.optString("title")
        return LinearLayout(this).apply {
            gravity = Gravity.CENTER_VERTICAL
            setPaddingRelative(dp(12), 0, dp(12), 0)
            isFocusable = true
            isSelected = selected
            contentDescription = if (selected) getString(R.string.widget_current_status, title) else title
            val selectable = TypedValue()
            theme.resolveAttribute(android.R.attr.selectableItemBackground, selectable, true)
            setBackgroundResource(selectable.resourceId)
            addView(ImageView(context).apply {
                setImageBitmap(widgetStatusIcon(context, choice.optJSONObject("appearance")))
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }, LinearLayout.LayoutParams(dp(20), dp(20)))
            addView(TextView(context).apply {
                text = title
                textSize = 14f
                setTextColor(getColor(R.color.widget_on_surface))
                maxLines = 1
                ellipsize = android.text.TextUtils.TruncateAt.END
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
                marginStart = dp(12)
            })
            if (selected) addView(TextView(context).apply {
                text = "✓"
                setTextColor(getColor(R.color.widget_on_surface))
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            })
        }
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).roundToInt()

    companion object {
        internal fun open(context: Context, widgetId: Int, graph: String, task: String, current: String): PendingIntent {
            val intent = Intent(context, WidgetStatusMenuActivity::class.java).apply {
                data = Uri.Builder().scheme("logseq").authority("widget-status-menu")
                    .appendQueryParameter("widget", widgetId.toString())
                    .appendQueryParameter("graph", graph)
                    .appendQueryParameter("task", task)
                    .appendQueryParameter("current", current)
                    .build()
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            // The launcher supplies the clicked icon's screen bounds as the fill-in intent.
            val flags = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
            return PendingIntent.getActivity(context, 0, intent, flags)
        }
    }
}

internal fun widgetStatusIcon(context: Context, appearance: JSONObject?): Bitmap {
    val icon = appearance?.optString("icon")?.removePrefix("app:")
    val vector = masterIcons[icon] ?: masterIcons.getValue("task-todo")
    val dark = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
    val hex = appearance?.optString(if (dark) "dark" else "light").orEmpty()
    val color = runCatching {
        Color.parseColor(if (hex.length == 9) "#" + hex.takeLast(2) + hex.substring(1, 7) else hex)
    }.getOrDefault(context.getColor(R.color.widget_secondary))
    val size = (22 * context.resources.displayMetrics.density).roundToInt().coerceAtLeast(1)
    val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    canvas.scale(size / vector.viewportWidth, size / vector.viewportHeight)
    val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color }
    for (node in vector.root) {
        val shape = node as? VectorPath ?: continue
        val path = PathParser().addPathNodes(shape.pathData).toPath().asAndroidPath()
        path.fillType = if (shape.pathFillType == PathFillType.EvenOdd) Path.FillType.EVEN_ODD else Path.FillType.WINDING
        if (shape.fill != null) {
            paint.style = Paint.Style.FILL
            canvas.drawPath(path, paint)
        }
        if (shape.stroke != null) {
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = shape.strokeLineWidth
            paint.strokeCap = if (shape.strokeLineCap == StrokeCap.Round) Paint.Cap.ROUND else Paint.Cap.BUTT
            paint.strokeJoin = if (shape.strokeLineJoin == StrokeJoin.Round) Paint.Join.ROUND else Paint.Join.MITER
            canvas.drawPath(path, paint)
        }
    }
    return bitmap
}
