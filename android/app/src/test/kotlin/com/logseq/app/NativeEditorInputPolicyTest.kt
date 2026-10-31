package com.logseq.app

import com.logseq.app.ui.extensions.applyEmptyPairDeletion
import com.logseq.app.ui.extensions.PendingEditorInput
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NativeEditorInputPolicyTest {
    @Test fun preservesNativeEditsWhenCanonicalPasteArrives() {
        data class Case(val initial: String, val origin: Int, val edits: List<Pair<String, Int>>,
            val canonical: String, val caret: Int, val expected: Pair<String, Int>)
        val cases = listOf(
            Case("paste", 5, listOf("past" to 4), "paste", 5, "past" to 4),
            Case("Bold note", 9, listOf("Bold not" to 8, "Bold notq" to 9),
                "**Bold note**", 13, "**Bold notq**" to 11),
            Case("abc", 3, listOf("abc" to 1, "aXc" to 2), "abc", 3, "aXc" to 2),
            Case("Bold note", 9, listOf("Bold notetail" to 13),
                "**Bold note**", 13, "**Bold note**tail" to 17),
            Case("old\nbeta", 8, listOf("old\nbet" to 7), "beta", 4, "bet" to 3),
            Case("suffix", 0, listOf("中文suffix" to 2), "suffix", 0, "中文suffix" to 2),
        )
        for (case in cases) {
            val pending = PendingEditorInput(case.initial, case.origin)
            case.edits.forEach { pending.capture(it.first, it.second) }
            assertEquals(case.toString(), case.expected, pending.rebase(case.canonical, case.caret))
        }
    }

    @Test fun executesOnlyDeclaredRulesUsingUtf16Offsets() {
        val policy = """{"emptyPairs":[{"text":"()","deleteOffset":0}]}"""
        assertEquals("😀 tail" to 2, applyEmptyPairDeletion(policy, "😀() tail", 2, 1, ""))
        assertNull(applyEmptyPairDeletion("{}", "[[]]", 1, 1, ""))
        assertNull(applyEmptyPairDeletion(policy, "()", 0, 2, ""))
        assertNull(applyEmptyPairDeletion(policy, "()", 0, 1, "x"))
    }
}
