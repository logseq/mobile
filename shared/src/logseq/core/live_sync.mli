(** Live-sync end-to-end runner: exercises graph create, snapshot
    download/import, outliner tx submission, asset upload/download, and
    capture against a real server, in both plain and E2EE modes. *)

val contents_page_uuid : string
val fail : string -> string -> 'a
val require_ok : string -> ('a, string) result -> 'a
val env : string -> string
val json_object : string -> Yojson.Basic.t
val json_string : string -> Yojson.Basic.t -> string option
val json_int : string -> Yojson.Basic.t -> int option
val expect_response :
  string -> int list -> (Api.api_response, string) result -> Api.api_response
val expect : string -> int list -> Api.api_request -> Api.api_response
val config : string -> string -> string -> Api.api_config
val write_temp : string -> string -> string
val remove_file : string -> unit
val remove_tree : string -> unit
val with_temp_dir : string -> (string -> 'a) -> 'a
val absolute_url : string -> string -> string
val download_snapshot :
  Api.api_config -> Sync_session.snapshot_metadata * string
val import_downloaded :
  string ->
  (string -> (string, string) result) option ->
  string ->
  Sync_session.snapshot_metadata ->
  string ->
  string
val has_title :
  Datascript.db -> (string -> (string, string) result) -> string -> bool
val submit_tx :
  ?decrypt:(string -> (string, string) result) ->
  Api.api_config ->
  Graph_runtime.graph_runtime ->
  Pending_ops.pending_operation ->
  int ->
  unit
val stage_insert :
  Graph_runtime.graph_runtime ->
  string ->
  string ->
  Pending_ops.pending_operation
val stage_asset :
  Graph_runtime.graph_runtime ->
  string ->
  string ->
  string ->
  int ->
  string ->
  string * Pending_ops.pending_operation
val ensure_user_keys : Api.api_config -> unit
val upload : string -> Api.api_file_upload -> unit
val create_and_upload :
  Api.api_config ->
  string ->
  bool ->
  (string -> (string, string) result) ->
  Api.api_config
val upload_asset_file :
  Api.api_config -> string -> string -> string -> string -> string -> unit
val download_asset :
  Api.api_config -> string -> string -> Api.api_response
val asset_mismatch : string -> string -> string
val verify_titles :
  Api.api_config ->
  (string -> (string, string) result) option ->
  string ->
  string ->
  string ->
  string ->
  unit
val run_mode : string -> string -> bool -> unit
val run : unit -> unit
