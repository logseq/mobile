package com.logseq.app

import com.logseq.app.ui.extensions.applyEmptyPairDeletion
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NativeEditorInputPolicyTest {
    @Test fun executesOnlyDeclaredRulesUsingUtf16Offsets() {
        val policy = """{"emptyPairs":[{"text":"()","deleteOffset":0}]}"""
        assertEquals("😀 tail" to 2, applyEmptyPairDeletion(policy, "😀() tail", 2, 1, ""))
        assertNull(applyEmptyPairDeletion("{}", "[[]]", 1, 1, ""))
        assertNull(applyEmptyPairDeletion(policy, "()", 0, 2, ""))
        assertNull(applyEmptyPairDeletion(policy, "()", 0, 1, "x"))
    }
}
