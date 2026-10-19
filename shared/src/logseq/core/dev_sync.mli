(** Pinned dev sync algorithms. Regenerate the implementation with
    scripts/vendor-dev-sync.py; mobile integration belongs in Journal_sync. *)
module Wire : sig
  type t =
    | Nil | Bool of bool | String of string | Int of int | Int64 of int64
    | Float of float | Binary of string | Keyword of string | Symbol of string
    | Big_decimal of string | Big_int of string | Date_ms of int64
    | Uuid of string | Uri of string | Array of t list | List of t list
    | Map of (t * t) list | Set of t list | Tagged of string * t
  type mode = Normal | Verbose
end

module Transit_codec : sig
  val of_string : string -> Wire.t
  val to_string : ?mode:Wire.mode -> Wire.t -> string
end

module Ds_wire : sig
  val value_of_transit : Wire.t -> Datascript.value
  val transit_of_value : Datascript.value -> Wire.t
end

module Db_normalize : sig type memo end

module Sync_const : sig val is_encrypt_attr : string -> bool end

module Sync_apply : sig
  val normalize_tx_data :
    ?memo:Db_normalize.memo -> Datascript.db -> Datascript.db ->
    Datascript.datom list -> Wire.t list
  val reverse_tx_data :
    ?memo:Db_normalize.memo -> Datascript.db -> Datascript.db ->
    Datascript.datom list -> Wire.t list
  val normalize_tx_data_for_rebase : Wire.t -> Wire.t list
end

module Sync_client_op : sig
  type pending_tx_row = { tx_id : string; tx : Wire.t; outliner_op : string option }
end

module Sync_replay : sig
  val display_db_from_server : Datascript.db -> Datascript.db
  val tx_self_created : Wire.t list -> (string, Wire.t) Hashtbl.t
  val pending_tx_unresolvable :
    Datascript.db -> created:(string, Wire.t) Hashtbl.t -> Wire.t list -> bool
  val resolve_temp_id :
    ?replay_created:(string, Wire.t) Hashtbl.t -> Datascript.db -> Wire.t -> Wire.t
  val replay_pending_entry : string -> Datascript.conn -> Sync_client_op.pending_tx_row -> unit
end

module Db_transact : sig
  val transact : Datascript.conn -> Wire.t list -> Datascript.tx_meta -> Datascript.tx_report option
end

module Db_sync_tx_sanitize : sig
  val drop_conflicted_encrypted_retracts : Datascript.value list -> Datascript.value list
end
