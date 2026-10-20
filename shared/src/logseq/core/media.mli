(** Canonical media requests and timestamp targets for native renderers. *)
val safe_url : string -> string option
val youtube_id : string -> string option
val embed_url : ?seconds:int -> string -> string option
val resolve_markup : ?preceding:string -> Yojson.Basic.t -> Yojson.Basic.t * string option
val first_timestamp_target : Yojson.Basic.t -> string option
