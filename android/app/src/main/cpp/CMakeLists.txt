cmake_minimum_required(VERSION 3.22.1)

project(logseq_jni C)

# Thin JNI shim between com.logseq.logseq.NativeCore and the
# liblogseq_core.so C ABI (shared/native/logseq_core_ffi.h).
# The OCaml core is delivered as a prebuilt shared library per ABI; this
# shim forwards every call and converts between jbyteArray (raw UTF-8
# bytes, decoded by Kotlin as Charsets.UTF_8) and the core's const char*
# strings so non-ASCII text survives the round trip — NewStringUTF's
# modified UTF-8 would corrupt 4-byte sequences such as emoji.
add_library(logseq_jni SHARED logseq_jni.c)

# NDK r27 requires explicit ELF alignment for devices with 16 KB pages.
target_link_options(logseq_jni PRIVATE
    "-Wl,-z,max-page-size=16384"
    "-Wl,-z,common-page-size=16384"
)

find_library(log-lib log)

target_link_libraries(logseq_jni ${log-lib})
