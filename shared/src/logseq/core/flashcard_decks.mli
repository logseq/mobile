type state = {
  graph_id : string option;
  selected : string option;
  choices : Cache_model.entity_summary list;
  target_kind : string;
  target_query : string;
  targets : Cache_model.entity_summary list;
  created : string option;
  error : string option;
}
val empty : state
val for_graph : string option -> state -> state
val to_yojson : state -> Yojson.Basic.t
val choices : Datascript.db -> Cache_model.entity_summary list
val due_cards : Datascript.db -> int -> string -> (Flashcards.due_card list, string) result
val target_allowed : Datascript.db -> string -> int -> bool
val search_targets : Datascript.db -> kind:string -> query:string ->
  search:(string -> Search_index.indexed_search_hit list) -> Cache_model.entity_summary list
val create : Datascript.db -> now:int -> kind:string -> target:string -> title:string ->
  fresh_uuid:(unit -> string) -> (string * Pending_ops.pending_intent, string) result
