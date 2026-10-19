module Ds = Datascript
module Transit = Transit_core.Json
module Graph = Graph_read
module Model = Cache_model
module Int_set = Set.Make (Int)
module String_map = Map.Make (String)

type graph_projection =
  { decrypt_title : string -> (string, string) result
  ; recent_pages : Int_set.t ref
  ; blocks_by_uuid : Model.block String_map.t ref
  }

let recent_pages db = Int_set.of_list (Graph.recent_journal_page_ids 7 db)

let read_blocks decrypt_title db =
  List.fold_left
    (fun acc (block : Model.block) -> String_map.add block.uuid block acc)
    String_map.empty
    (Graph.blocks decrypt_title 7 db)

let rebuild projection db =
  projection.recent_pages := recent_pages db;
  projection.blocks_by_uuid := String_map.empty;
  projection.blocks_by_uuid :=
    read_blocks projection.decrypt_title db

let create decrypt_title db =
  {
    decrypt_title;
    recent_pages = ref (recent_pages db);
    blocks_by_uuid = ref (read_blocks decrypt_title db);
  }

let blocks projection =
  List.sort Graph.compare_journal_blocks
    (String_map.fold (fun _ block acc -> block :: acc)
       !(projection.blocks_by_uuid) [])

type entity_identity = Uuid_identity of string | Ident_identity of string

let identity (value : Transit.value) =
  match value with
  | Transit.Array
      [ Transit.Keyword "block/uuid"; Transit.Uuid uuid ] ->
    Some (Uuid_identity uuid)
  | Transit.Array
      [ Transit.Keyword "db/ident"; Transit.Keyword ident ] ->
    Some (Ident_identity ident)
  | _ -> None

let refresh_block projection db uuid =
  let block =
    match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
    | Some eid ->
      (match
         Datascript_value.optional_ref_eid db "block/page"
           (Graph.value db eid "block/page")
       with
       | Some page_eid
         when Int_set.mem page_eid !(projection.recent_pages) ->
         Graph.block projection.decrypt_title db eid
       | _ -> None)
    | None -> None
  in
  projection.blocks_by_uuid :=
    (match block with
     | Some block -> String_map.add uuid block !(projection.blocks_by_uuid)
     | None -> String_map.remove uuid !(projection.blocks_by_uuid))

let changed_identities identities =
  List.fold_left
    (fun (uuids, idents) value ->
      match identity value with
      | Some (Uuid_identity uuid) -> (uuid :: uuids, idents)
      | Some (Ident_identity ident) -> (uuids, ident :: idents)
      | None -> (uuids, idents))
    ([], [])
    identities

let related_entity_changed changed_uuids (block : Model.block) =
  List.exists
    (fun (summary : Model.entity_summary) ->
      List.mem summary.Model.uuid changed_uuids)
    (block.tags @ block.references)

let status_changed changed_uuids changed_idents (block : Model.block) =
  match block.status with
  | Some status ->
    List.mem status.Model.uuid changed_uuids
    || (match status.Model.ident with
        | Some ident -> List.mem ident changed_idents
        | None -> false)
  | None -> false

let update projection db identities =
  if not (Int_set.equal !(projection.recent_pages) (recent_pages db)) then
    rebuild projection db
  else
    let changed_uuids, changed_idents = changed_identities identities in
    let affected =
      String_map.fold
        (fun _ (block : Model.block) affected ->
          if
            List.mem block.page_id changed_uuids
            || related_entity_changed changed_uuids block
            || status_changed changed_uuids changed_idents block
          then block.uuid :: affected
          else affected)
        !(projection.blocks_by_uuid) changed_uuids
    in
    List.iter (fun uuid -> refresh_block projection db uuid) affected
