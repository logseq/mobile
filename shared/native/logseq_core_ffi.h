#ifndef LOGSEQ_CORE_FFI_H
#define LOGSEQ_CORE_FFI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

const char *logseq_call(const char *request_json);
void logseq_initialize(void);
const char *logseq_lui_initialize(
    int32_t platform_code,
    int32_t host_code,
    int32_t authentication_code);
const char *logseq_lui_appear(int64_t node);
const char *logseq_lui_press(int64_t node);
const char *logseq_lui_long_press(int64_t node);
const char *logseq_lui_text_changed(int64_t node, const char *text);
const char *logseq_lui_submit(int64_t node);
const char *logseq_lui_toggle_changed(int64_t node, int32_t checked);
const char *logseq_lui_change(int64_t node);
const char *logseq_lui_value_changed(int64_t node, double value);
const char *logseq_lui_dismiss(int64_t node);
const char *logseq_lui_double_press(int64_t node);
const char *logseq_lui_extension_event(
    int64_t node, const char *identifier, const char *name, const char *text,
    int64_t value);
const char *logseq_lui_picked(int64_t node, const char *payload);
const char *logseq_lui_visible_range(int64_t node, int64_t first,
                                          int64_t last);
const char *logseq_lui_scroll_completed(int64_t node, int64_t token,
                                             const char *outcome);
int64_t logseq_lui_root_node(void);
const char *logseq_lui_dispose(void);
const char *logseq_lui_take_effect(void);
const char *logseq_lui_resolve_effect(int64_t effect_id, int32_t succeeded,
                                           const char *message);
const char *logseq_lui_apply_snapshot(const char *response_json);
const char *logseq_lui_apply_host_update(const char *kind,
                                              const char *payload_json);


typedef void (*logseq_graph_import_progress_callback)(const char *, const char *, int64_t, int64_t);
void logseq_set_graph_import_progress_callback(logseq_graph_import_progress_callback callback);
void logseq_graph_import_progress(const char *graph_id, const char *phase, int64_t completed, int64_t total);

#ifdef __cplusplus
}
#endif

#endif
