(** HTTP request builders and JSON decoders for the Logseq sync API. *)

type api_config =
  { base_url : string
  ; graph_id : string
  ; graph_name : string option
  ; token : string
  }

type api_request =
  { method_ : string
  ; url : string
  ; body : string option
  ; token : string
  }

type api_response =
  { status : int
  ; body : string
  }

type api_file_upload =
  { request : api_request
  ; file_path : string
  ; content_type : string
  ; headers : (string * string) list
  }

type api_graph =
  { id : string
  ; name : string
  ; schema_version : string option
  ; role : string option
  ; e2ee : bool
  ; ready : bool
  }

type api_user_keys =
  { public_key : string
  ; encrypted_private_key : string
  }

val response : int -> string -> api_response
val epoch_ms : unit -> int
val trim_slash : string -> string
val api_root : api_config -> string
val url_encode : string -> string
val request : api_config -> string -> string -> string option -> api_request
val graph_path : api_config -> string -> string
val json_body : (string * Yojson.Basic.t) list -> string option
val graphs_request : api_config -> api_request
val create_graph_request : api_config -> string -> string -> bool -> api_request
val initial_snapshot_upload_request :
  api_config -> string -> string -> api_file_upload
val user_keys_request : api_config -> api_request
val graph_key_request : api_config -> api_request
val upsert_graph_key_request : api_config -> string -> api_request
val encrypted_journal_page_request :
  api_config -> string -> string -> string -> int -> api_request
val page_fields : string option -> (string * Yojson.Basic.t) list
val block_json : string -> string -> Yojson.Basic.t
val capture_request :
  string option -> api_config -> string -> string -> api_request
val child_block_request : api_config -> string -> string -> string -> api_request
val task_request :
  string option -> api_config -> string -> string -> string -> api_request
val asset_upload_request :
  string option ->
  api_config ->
  string ->
  string ->
  int ->
  string ->
  string ->
  string ->
  api_file_upload
val move_block_request : api_config -> string -> string -> api_request
val encrypted_asset_upload_request :
  api_config ->
  string ->
  string ->
  string ->
  string ->
  int ->
  int ->
  string ->
  string ->
  api_file_upload
val member : string -> Yojson.Basic.t -> Yojson.Basic.t
val option_string_member : string -> Yojson.Basic.t -> string option
val string_member : string -> Yojson.Basic.t -> string
val int_member : string -> Yojson.Basic.t -> int
val list_member : string -> Yojson.Basic.t -> Yojson.Basic.t list
val created_block_uuid_from_body : string -> string
val normalize_asset_type : string -> string
val asset_file_name : string -> string -> string
val content_type_for_asset_type : string -> string
val raw_asset_upload_request :
  api_config -> string -> string -> string -> string -> string -> api_file_upload
val update_block_request : api_config -> string -> string -> api_request
val tx_batch_request : api_config -> int -> string -> string -> string -> api_request
val update_block_status_request : api_config -> string -> string -> api_request
val bool_member : bool -> string -> Yojson.Basic.t -> bool
val nonempty_string_member : string -> Yojson.Basic.t -> string option
val graph_of_json : Yojson.Basic.t -> api_graph option
val graphs_from_graphs_body : string -> api_graph list
val graph_from_graphs_body : string -> (string * string option) option
val user_keys_from_body : string -> api_user_keys
val graph_key_from_body : string -> string

val upsert_user_keys_request : api_config -> string -> string -> api_request
