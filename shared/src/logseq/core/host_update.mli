(** Decoding of host-initiated UI updates sent as JSON from Swift/Kotlin. *)

type host_composer_asset =
  { uuid : string
  ; title : string
  ; local_path : string
  ; payload : string
  }

type host_ui_session =
  { graph_id : string option
  ; destination : string
  ; assets : host_composer_asset list
  ; composer_tags : (string * string) list
  ; composer_expanded : bool
  ; search_open : bool
  ; query : string
  ; app_path : string list
  ; search_path : string list
  ; selected_page_id : string option
  ; settings_open : bool
  ; recent_graph_ids : string list
  }

type host_settings =
  { appearance : string
  ; language : string
  ; system_language : string option
  ; spell_check : bool
  ; auto_correction : bool
  ; sidebar_tabs : string list
  ; base_url : string
  ; version : string
  ; revision : string
  }

type host_runtime_log_record =
  { id : string
  ; level : string
  ; source : string
  ; timestamp : string
  ; message : string
  }

type host_authentication =
  { state : string
  ; error_message : string option
  }

type host_update =
  | Settings of host_settings
  | Runtime_log of host_runtime_log_record list * host_runtime_log_record option
  | Local_graph_ids of string list
  | Save_ui_session
  | Restore_ui_session of host_ui_session
  | Composer_draft of string
  | Composer_asset of host_composer_asset
  | Graph_loading of bool
  | Authentication of host_authentication
  | Open_quick_action of string
  | Confirm_outliner_delete
  | Open_capture
  | Open_node of string
  | Asset_preview_resolved of string * string

val decode : string -> string -> (host_update, string) result
