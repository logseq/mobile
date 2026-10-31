val operating_system : int -> Lui_protocol.operating_system

val host_kind : int -> Lui_protocol.host_kind

val app :
  unit -> (Model.logseq_model, Model.logseq_action) Lui_app.reducer_app

val flush_event : Lui_protocol.event -> string

val flush_action : Model.logseq_action -> string

val apply_response : string -> string

val apply_host_update : string -> string -> string

val encode_string_vector : string list -> string

val encode_option_string : string option -> string

val encode_session_asset : Model.composer_asset -> string

val encode_session_routes : Model.navigation_route list -> string

val encode_ui_session : Model.ui_session -> string

val encode_task_status : Model.task_status -> string

val encode_asset_presentation : string -> string -> string -> string

val encode_settings : Model.settings_projection -> string

val encode_runtime_log_record : Model.runtime_log_record -> string

val encode_runtime_log_records : Model.runtime_log_record list -> string

val encode_effect : Model.logseq_effect -> string

val encode_effect_dispatch : Model.logseq_effect -> string -> string

val set_search_index_source : (unit -> string option) -> unit

val take_effect : unit -> string

val resolve_effect : int -> bool -> string -> string

val backend : Lui_protocol.platform_profile -> Lui_protocol.backend

val start_application :
  (Model.logseq_model, Model.logseq_action) Lui_app.reducer_app -> string

val initialize : int -> int -> int -> string

val resync : unit -> string

val linked : unit -> bool

val appear : int -> string

val press : int -> string

val long_press : int -> string

val text_changed : int -> string -> string

val submit : int -> string

val toggle_changed : int -> bool -> string

val change : int -> string

val value_changed : int -> float -> string

val dismiss : int -> string

val double_press : int -> string

val picked : int -> string -> string

val visible_range : int -> int -> int -> string

val scroll_completed : int -> int -> string -> string

val extension_event : int -> string -> string -> string -> int -> string

val dispose : unit -> string

val root_node : unit -> int
