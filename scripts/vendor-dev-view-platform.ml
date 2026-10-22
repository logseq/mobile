(* Graph adapters for the pinned native view algorithms. *)
module Ldb = struct
  open Datascript
  let ent_of_id db id = entity db (Entity_id id)
  let ent_of_ref db reference = entity db reference
  let values (e : entity) attr = match Entity.entity_attr_raw e attr with
    | Some (One_value value) -> [value]
    | Some (Many_values values) -> values
    | _ -> []
  let value e attr = List.nth_opt (values e attr) 0
  let string_value e attr = match value e attr with Some (String s) -> Some s | _ -> None
  let ident_of e = match value e "db/ident" with Some (Keyword s) -> Some s | _ -> None
  let truthy = function None | Some Nil | Some (Bool false) -> false | _ -> true
  let is_class (e : entity) = Graph_read.entity_is_instance_of e.db e.id "logseq.class/Tag"
  let many_attr db attr = match List.assoc_opt attr db.schema with
    | Some spec -> spec.cardinality = Many
    | None -> Option.bind (entity db (Ident attr)) (fun e -> value e "db/cardinality")
        = Some (Keyword "db.cardinality/many")
end
module Db_class = struct
  let ident_eid db ident = Datascript.entid db "db/ident" (Datascript.Keyword ident)
  let get_structured_children db id =
    Graph_read.class_descendants db id |> List.filter (fun child -> child <> id)
end
module Db_property = struct
  let property_value_content entity = match Ldb.value entity "block/title" with
    | Some _ as title -> title
    | None -> Ldb.value entity "logseq.property/value"
end
