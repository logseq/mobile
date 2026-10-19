(* Generate isolated nested pages; never writes to an existing graph. *)
module Ds = Datascript

let page_uuid = "6954ee2a-506b-4dd9-bd6d-0dc24db9c055"

let () =
  if Array.length Sys.argv <> 3 then
    failwith "usage: page_fixture <new-directory> <block-count>";
  let root = Sys.argv.(1) in
  let count = int_of_string Sys.argv.(2) in
  if count < 1 || Sys.file_exists root then failwith "Expected a new directory and positive count";
  Unix.mkdir root 0o700;
  Unix.mkdir (root ^ "/graphs") 0o700;
  let directory = root ^ "/graphs/uiregression" in
  Unix.mkdir directory 0o700;
  let path = directory ^ "/graph.sqlite" in
  Graph_sqlite.prepare_staging path;
  let indexed = { Storage_codec.default_schema_attr with Ds.indexed = true } in
  let string = { indexed with Ds.value_type = Some Ds.StringType } in
  let reference = { indexed with Ds.value_type = Some Ds.RefType } in
  let schema = [
    "block/uuid", { indexed with Ds.value_type = Some Ds.UuidType; unique = Some Ds.Identity };
    "db/ident", { indexed with Ds.value_type = Some Ds.KeywordType; unique = Some Ds.Identity };
    "block/name", string; "block/title", string; "block/order", string;
    "block/page", reference; "block/parent", reference;
    "block/refs", { reference with Ds.cardinality = Ds.Many };
    "block/tags", { reference with Ds.cardinality = Ds.Many };
    "block/journal-day", indexed; "block/created-at", indexed; "block/updated-at", indexed;
  ] in
  let conn = Ds.conn_from_db (Ds.empty_db ~schema ()) in
  let add id attribute value = Ds.Add (Ds.Entity_id id, attribute, value) in
  ignore (Ds.transact_conn conn [
    add 200 "block/uuid" (Ds.Uuid page_uuid);
    add 200 "block/name" (Ds.String "logseq public roadmap");
    add 200 "block/title" (Ds.String "Logseq public roadmap");
    add 200 "block/updated-at" (Ds.Int64 1L);
  ]);
  let transactions = List.init count (fun index ->
    let id = 1000 + index in
    let parent = if index mod 4 = 0 then 200 else id - 1 in
    [ add id "block/uuid" (Ds.Uuid (Printf.sprintf "e2e30000-0000-4000-9000-%012d" id));
      add id "block/title" (Ds.String (Printf.sprintf "Long page block %05d with nested children and text for scrolling" index));
      add id "block/page" (Ds.Ref 200); add id "block/parent" (Ds.Ref parent);
      add id "block/order" (Ds.String (Printf.sprintf "b%06d" index)) ])
    |> List.fold_left (fun result operations -> List.rev_append operations result) [] |> List.rev in
  ignore (Ds.transact_conn conn transactions);
  ignore (Ds.store ~storage:(Graph_store.storage path) (Ds.conn_db conn));
  (match Sync_checkpoint.save_checkpoint_atomic (directory ^ "/sync.checkpoint")
    (Sync_checkpoint.create "uiregression" "65.34" 0) with
   | Ok () -> () | Error error -> failwith error);
  let catalog = Sqlite.open_session (root ^ "/logseq.sqlite") in
  Sqlite.store_string catalog Mobile_session.graph_catalog_address
    {|{"graphs":[{"graph-id":"uiregression","graph-name":"Benchmark","graph-e2ee?":false,"graph-ready-for-use?":true,"schema-version":"65.34"}]}|};
  Sqlite.close catalog;
  Printf.printf "%s\n" path
