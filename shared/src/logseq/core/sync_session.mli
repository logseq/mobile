(** Sync session state: snapshot import, change-set application, and
    checkpoint persistence. *)

type sync_session_state =
  { graph_id : string
  ; schema_version : string
  ; applied_server_t : int ref
  }

type snapshot_metadata =
  { url : string
  ; content_encoding : string option
  ; baseline_t : int
  ; schema_version : string option
  ; row_count : int option
  }

val create_state : string -> string -> int -> sync_session_state
val applied_server_t : sync_session_state -> int
val submission_accepted : sync_session_state -> int -> unit
val string_field : string -> Yojson.Basic.t -> (string, string) result
val non_negative_int_field :
  string -> Yojson.Basic.t -> (int, string) result
val decode_snapshot_metadata : string -> (snapshot_metadata, string) result
val cleanup_staging : string -> unit
val plaintext_datom :
  (string -> (string, string) result) ->
  Datascript.datom ->
  (Datascript.datom, string) result
val plaintext_snapshot_db :
  (string -> (string, string) result) ->
  Datascript.db ->
  (Datascript.db, string) result
val materialize_plaintext_snapshot :
  string ->
  (string -> (string, string) result) ->
  Datascript.db ->
  (unit, string) result
val stream_snapshot :
  string ->
  string ->
  Snapshot.snapshot_parser ->
  Snapshot.snapshot_import ->
  (unit, string) result
val import_snapshot :
  (string -> (string, string) result) option ->
  string ->
  string ->
  string ->
  snapshot_metadata ->
  string ->
  (Snapshot.snapshot_completed_import, string) result
val import_snapshot_file :
  (string -> (string, string) result) option ->
  string ->
  string ->
  string ->
  snapshot_metadata ->
  string ->
  (Snapshot.snapshot_completed_import, string) result
