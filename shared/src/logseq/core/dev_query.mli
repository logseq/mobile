(** Query algorithms extracted from the pinned upstream dev worker. *)
module Wire : sig
  include module type of Dev_sync.Wire with type t = Dev_sync.Wire.t
end
module Time : sig
  type epoch_ms
  type tz
  type local_date
  val epoch_ms : int64 -> epoch_ms
  val epoch_ms_of_float : float -> epoch_ms
  val epoch_ms_to_float : epoch_ms -> float
  val local_tz : unit -> tz
  val local_date_of_journal_day : tz -> int -> local_date option
end
module Unicode : sig
  val trim : string -> string
  val lowercase : string -> string
end
module Date_time_util : sig
  val valid_journal_title : ?formatters:string list -> string -> bool
  type period = Days | Weeks | Months | Years | Hours | Minutes
  val time_ms : unit -> int64
  val minus : period -> int -> int64 -> int64
end
module Ds_wire : sig
  val edn_of_query_form : Datascript.query_form -> string
  val value_of_transit : Wire.t -> Datascript.value
  val transit_of_value : Datascript.value -> Wire.t
end
module Edn_util : sig
  val read_string : string -> Datascript.value
  val pr_str : Datascript.value -> string
end
module Db_query_dsl : sig
  type exec_opts = {
    opt_cards : bool;
    opt_block_attrs : string option;
    opt_current_page_title : string option;
    opt_today_day : Time.local_date option;
  }
  val execute_query : Datascript.db -> string -> exec_opts -> Datascript.query_result list list option
  val execute_custom_query : Datascript.db -> string -> exec_opts -> Datascript.query_result list list option
end
module Edn_eval : sig
  val apply_edn : entity_attr:(int -> string -> Datascript.value) -> string -> Wire.t list -> Wire.t
end
val execute_custom_query_typed : Datascript.db -> Datascript.query_form list -> Wire.t list ->
  Datascript.query_form list -> (Wire.t * Wire.t) list -> Datascript.query_result list list
