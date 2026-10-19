(** Incremental projection of journal blocks keyed by block uuid. *)

module Int_set : Set.S with type elt = int
module String_map : Map.S with type key = string

type graph_projection =
  { decrypt_title : string -> (string, string) result
  ; recent_pages : Int_set.t ref
  ; blocks_by_uuid : Cache_model.block String_map.t ref
  }

type entity_identity =
  | Uuid_identity of string
  | Ident_identity of string

val recent_pages : Datascript.db -> Int_set.t
val read_blocks :
  (string -> (string, string) result) ->
  Datascript.db ->
  Cache_model.block String_map.t
val rebuild : graph_projection -> Datascript.db -> unit
val create :
  (string -> (string, string) result) -> Datascript.db -> graph_projection
val blocks : graph_projection -> Cache_model.block list
val identity : Transit_core.Json.value -> entity_identity option
val refresh_block : graph_projection -> Datascript.db -> string -> unit
val changed_identities :
  Transit_core.Json.value list -> string list * string list
val related_entity_changed : string list -> Cache_model.block -> bool
val status_changed : string list -> string list -> Cache_model.block -> bool
val update :
  graph_projection -> Datascript.db -> Transit_core.Json.value list -> unit
