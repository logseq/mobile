type retained_outline_row = View_rows.retained_row

val logseq_view :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t

val outliner_editor_schema :
  unit -> Lui_extension.extension_component_schema

val outliner_block_content_schema :
  unit -> Lui_extension.extension_component_schema

val native_navigation_stack_schema :
  unit -> Lui_extension.extension_component_schema

val native_search_presentation_schema :
  unit -> Lui_extension.extension_component_schema

val native_navigation_title_schema :
  unit -> Lui_extension.extension_component_schema

val liquid_glass_schema :
  unit -> Lui_extension.extension_component_schema

val extension_registry : unit -> Lui_extension.extension_registry
