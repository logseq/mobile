module Util = Yojson.Safe.Util

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
  | Runtime_log of host_runtime_log_record list
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

let string_field name value = Util.to_string (Util.member name value)
let bool_field name value = Util.to_bool (Util.member name value)
let string_vector value = List.map Util.to_string (Util.to_list value)

let settings value =
  Settings
    {
      appearance = string_field "appearance" value;
      language = string_field "language" value;
      spell_check = bool_field "spellCheck" value;
      auto_correction = bool_field "autoCorrection" value;
      sidebar_tabs = string_vector (Util.member "sidebarTabs" value);
      base_url = string_field "baseURL" value;
      version = string_field "version" value;
      revision = string_field "revision" value;
    }

let runtime_log_record value =
  {
    id = string_field "id" value;
    level = string_field "level" value;
    source = string_field "source" value;
    timestamp = string_field "timestamp" value;
    message = string_field "message" value;
  }

let composer_asset value payload =
  {
    uuid = string_field "uuid" value;
    title = string_field "title" value;
    local_path = string_field "localPath" value;
    payload;
  }

let ui_session value =
  {
    graph_id = Util.to_string_option (Util.member "graphId" value);
    destination = string_field "destination" value;
    assets =
      List.map
        (fun asset -> composer_asset asset (string_field "payload" asset))
        (Util.to_list (Util.member "assets" value));
    composer_expanded = bool_field "composerExpanded" value;
    search_open = bool_field "searchOpen" value;
    query = string_field "query" value;
    app_path = string_vector (Util.member "appPath" value);
    search_path = string_vector (Util.member "searchPath" value);
    selected_page_id =
      Util.to_string_option (Util.member "selectedPageId" value);
    settings_open = bool_field "settingsOpen" value;
    recent_graph_ids = (match Util.member "recentGraphIds" value with `Null -> [] | ids -> string_vector ids);
  }

let decode kind payload =
  try
    let value = Yojson.Safe.from_string payload in
    match kind with
    | "settings" -> Ok (settings value)
    | "runtime-log" ->
      Ok (Runtime_log (List.map runtime_log_record (Util.to_list value)))
    | "local-graph-ids" -> Ok (Local_graph_ids (string_vector value))
    | "composer-asset" -> Ok (Composer_asset (composer_asset value payload))
    | "save-ui-session" -> Ok Save_ui_session
    | "restore-ui-session" -> Ok (Restore_ui_session (ui_session value))
    | "composer-draft" -> Ok (Composer_draft (Util.to_string value))
    | "graph-loading" -> Ok (Graph_loading (Util.to_bool value))
    | "authentication" ->
      Ok
        (Authentication
           {
             state = string_field "state" value;
             error_message =
               Util.to_string_option (Util.member "errorMessage" value);
           })
    | "open-quick-action" -> Ok (Open_quick_action (Util.to_string value))
    | "confirm-outliner-delete" -> Ok Confirm_outliner_delete
    | "open-capture" -> Ok Open_capture
    | "open-node" -> Ok (Open_node (Util.to_string value))
    | "asset-preview-resolved" ->
      Ok
        (Asset_preview_resolved
           (string_field "title" value, string_field "path" value))
    | _ -> Error ("Unsupported host update: " ^ kind)
  with
  | Yojson.Json_error message -> Error ("Invalid host update JSON: " ^ message)
  | Util.Type_error (message, _) ->
    Error ("Invalid " ^ kind ^ " host update: " ^ message)
