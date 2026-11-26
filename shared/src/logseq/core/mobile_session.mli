(** Mobile session host: wires the graph/database/keyring hosts into an RPC
    session and registers the `logseq_mobile_call` callback. *)

type mobile_session =
  { database : Mobile_database.mobile_database
  ; keyring : E2ee_keyring.e2ee_keyring
  ; session : Session_types.session ref
  }

val graph_catalog_address : string
val snapshot_request : string
val discard_value : ('a, string) result -> (unit, string) result
val host_options :
  Mobile_database.mobile_database ->
  E2ee_keyring.e2ee_keyring ->
  Sqlite.session option ->
  Session_types.host_options
val create : (string -> string) -> mobile_session
val call : mobile_session -> string -> string
val start : (string -> string) -> mobile_session
