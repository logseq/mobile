(* Mobile adapters for the native query subset. *)

(* SECTION: GRAPH *)
module Ldb = struct
  open Datascript
  let ent_of_id db id = entity db (Entity_id id)
  let value (e : entity) attr = Graph_read.value e.db e.id attr
  let string_value e attr = Graph_read.string_value (value e attr)
  let ident_of e = match value e "db/ident" with Some (Keyword k) -> Some k | _ -> None
  let page_name_sanity_lc s = Unicode.trim (Unicode.lowercase s)
  let is_uuid_string s =
    String.length s = 36 && s.[8] = '-' && s.[13] = '-' && s.[18] = '-' && s.[23] = '-'
  let journal_title_of_day day fmt = Date_time_util.int_to_journal_title day fmt
  let get_page db = function
    | String s when not (is_uuid_string s) ->
      Option.bind (Seq.find_map (fun (d : datom) -> Some d)
        (datoms db Avet ~a:"block/name" ~v:(String (page_name_sanity_lc s)) ()))
        (fun d -> ent_of_id db d.e)
    | String s | Uuid s -> entity db (Lookup_ref ("block/uuid", Uuid s))
    | Int64 n -> ent_of_id db (Int64.to_int n)
    | _ -> None
end

module Entity_refs = struct
  let ref_ids (e : Datascript.entity) attr = Graph_read.ref_eids e.db e.id attr
  let ref_ent e attr = match ref_ids e attr with
    | id :: _ -> Ldb.ent_of_id e.Datascript.db id | [] -> None
  let has_tag (e : Datascript.entity) ident = Graph_read.entity_is_instance_of e.db e.id ident
end

module Db_class = struct
  let get_structured_children db id =
    Graph_read.class_descendants db id |> List.filter (fun child -> child <> id)
end

(* SECTION: TRANSFORM *)
module Malli = struct
  let integer_float f = Float.is_finite f && Float.floor f = f
end

module Dispatcher = struct
  exception Exn_info of string * (Wire.t * Wire.t) list
end
