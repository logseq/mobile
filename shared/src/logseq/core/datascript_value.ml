module Ds = Datascript

let built_in_ref_attrs =
  [
    "block/parent"; "block/page"; "block/refs"; "block/tags"; "block/link";
    "block/alias"; "block/closed-value-property";
  ]

let built_in_ref_attr attr = List.mem attr built_in_ref_attrs

let value_type_is_ref db value =
  let check_eid eid =
    Seq.exists
      (fun (datom : Ds.datom) -> datom.v = Ds.Keyword "db.type/ref")
      (Ds.Db.datoms db Ds.Eavt ~e:eid ~a:"db/ident" ())
  in
  match value with
  | Ds.Keyword "db.type/ref" -> true
  | Ds.Ref eid -> check_eid eid
  | Ds.Int64 eid -> check_eid (Int64.to_int eid)
  | _ -> false

let entity_declares_ref db attr =
  match Ds.entid db "db/ident" (Ds.Keyword attr) with
  | Some eid ->
    Seq.exists
      (fun (datom : Ds.datom) -> value_type_is_ref db datom.v)
      (Ds.Db.datoms db Ds.Eavt ~e:eid ~a:"db/valueType" ())
  | None -> false

let is_ref_attr db attr =
  built_in_ref_attr attr
  || Ds.Schema.schema_attr_is_ref db.Ds.schema attr
  || entity_declares_ref db attr

let ref_eid db attr value =
  match value with
  | Ds.Ref eid -> Some eid
  | Ds.Int64 eid -> if is_ref_attr db attr then Some (Int64.to_int eid) else None
  | _ -> None

let optional_ref_eid db attr value =
  match value with Some value -> ref_eid db attr value | None -> None

let datoms_by_ref db index attr eid =
  let index =
    match index with
    | Ds.Aevt when Ds.Schema.schema_attr_is_avet_accessible db.Ds.schema attr ->
      Ds.Avet
    | _ -> index
  in
  let seen_entities = Hashtbl.create 8 in
  let candidates =
    Seq.append
      (Ds.Db.datoms db index ~a:attr ~v:(Ds.Ref eid) ())
      (Ds.Db.datoms db index ~a:attr ~v:(Ds.Int64 (Int64.of_int eid)) ())
  in
  Seq.filter
    (fun (datom : Ds.datom) ->
      ref_eid db attr datom.v = Some eid
      && not (Hashtbl.mem seen_entities datom.e)
      && (Hashtbl.add seen_entities datom.e ();
          true))
    candidates
