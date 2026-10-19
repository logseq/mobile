(* Run on a consistent SQLite export, never a live graph database.
   Example: dune exec shared/bench/page_open.exe -- graph.sqlite PAGE_UUID 10
   Cold stages restore DataScript's node cache; the OS page cache stays warm.
   The known-ID hydration stage excludes index traversal and ordering work. *)
module Ds = Datascript
module Read = Graph_read
module Outliner = Outliner_state

let now () = Unix.gettimeofday ()
let samples = Hashtbl.create 16

let measure name reads f =
  let before_reads = !reads in
  let started = now () in
  let result = f () in
  let elapsed = (now () -. started) *. 1_000. in
  let existing = Option.value ~default:[] (Hashtbl.find_opt samples name) in
  Hashtbl.replace samples name ((elapsed, !reads - before_reads) :: existing);
  result

let take count values =
  let rec loop count result = function
    | _ when count = 0 -> List.rev result
    | [] -> List.rev result
    | value :: rest -> loop (count - 1) (value :: result) rest
  in
  loop count [] values

let restore path reads =
  let storage = Graph_store.storage path in
  let counted = { storage with Ds.storage_restore = (fun address ->
    incr reads; storage.storage_restore address) } in
  match Ds.restore counted with
  | Some db -> db
  | None -> failwith "Missing DataScript root"

let plain value = Ok value

let () =
  if Array.length Sys.argv < 3 then
    failwith "usage: page_open <graph.sqlite> <page-uuid> [iterations]";
  let path = Sys.argv.(1) in
  let uuid = Sys.argv.(2) in
  let iterations = if Array.length Sys.argv > 3 then int_of_string Sys.argv.(3) else 10 in
  let row_count = ref 0 and child_count = ref 0 and first30_bytes = ref 0 in
  for _ = 1 to iterations do
    let reads = ref 0 in
    let db = measure "restore_root" reads (fun () -> restore path reads) in
    let all = measure "read_page_cold" reads (fun () -> Read.blocks_for_page plain db uuid) in
    ignore (measure "read_page_warm" reads (fun () -> Read.blocks_for_page plain db uuid));
    let runtime = Graph_runtime.create_base path 0 (Ds.conn_from_db db) Graph_runtime.default_options in
    ignore (Graph_runtime.blocks_for_page runtime uuid);
    ignore (measure "runtime_page_cache_hit" reads (fun () -> Graph_runtime.blocks_for_page runtime uuid));
    let context = measure "build_context" reads (fun () -> Outliner.context all [] []) in
    let rows = measure "flatten_all" reads (fun () -> Outliner.visible_rows context Outliner.empty) in
    row_count := List.length rows;
    child_count := List.fold_left (fun n row -> if row.Outliner.depth > 0 then n + 1 else n) 0 rows;
    let first30 = take 30 rows in
    let payload = measure "encode_first30" reads (fun () ->
      Yojson.Basic.to_string (`List (List.map (Rpc.outliner_row_json None Rpc.block_json) first30))) in
    first30_bytes := String.length payload;
    ignore (measure "encode_all" reads (fun () ->
      Yojson.Basic.to_string (Rpc.outliner_rows_json Rpc.block_json context Outliner.empty)));
    ignore (measure "read_sidebar" reads (fun () -> Read.sidebar_pages plain db));
    ignore (measure "read_tags" reads (fun () -> Read.tag_pages plain db));
    let reference_reads = ref 0 in
    let reference_db = restore path reference_reads in
    ignore (measure "linked_references_cold" reference_reads (fun () -> Read.references_for_node plain reference_db uuid));
    ignore (measure "linked_references_warm" reference_reads (fun () -> Read.references_for_node plain reference_db uuid));
    let window_reads = ref 0 in
    let window_db = restore path window_reads in
    ignore (measure "first30_window_cold" window_reads (fun () ->
      Read.read_page_window ~limit:30 plain (Read.page_reader window_db uuid)));
    let summary = match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
      | Some eid -> Read.page_summary plain db eid
      | None -> None in
    let page = match summary with Some page -> Rpc.summary_json page | None -> failwith "Page not found" in
    let envelope selected rows =
      Yojson.Basic.to_string (`Assoc ["ok", `Bool true; "result", `Assoc [
        "graphName", `String "Benchmark"; "selectedGraphId", `String "benchmark";
        "favorites", `List [page]; "recentPages", `List [];
        "selectedPage", (if selected then page else `Null);
        "outlinerRows", rows]]) in
    let snapshot = envelope true (Rpc.outliner_rows_json Rpc.block_json context Outliner.empty) in
    ignore (Native_bridge.initialize 2 2 3);
    ignore (Native_bridge.apply_response (envelope false (`List [])));
    for visit = 1 to 3 do
      ignore (Native_bridge.flush_action Model.OpenSidebar);
      let id = (App.model (Native_bridge.app ())).Model.next_effect_id in
      let prefix = if visit = 1 then "ui_first_open_" else "ui_reselect_" in
      ignore (measure (prefix ^ "preview") reads (fun () ->
        Native_bridge.flush_action (Model.SelectSidebarPage uuid)));
      ignore (Native_bridge.take_effect ());
      ignore (measure (prefix ^ "apply_snapshot") reads (fun () -> Native_bridge.apply_response snapshot));
      ignore (measure (prefix ^ "resolve_effect") reads (fun () -> Native_bridge.resolve_effect id true snapshot))
    done;
    ignore (Native_bridge.dispose ());
    let cold_reads = ref 0 in
    let cold_db = restore path cold_reads in
    let eids = List.filter_map (fun row ->
      Ds.entid cold_db "block/uuid" (Ds.Uuid row.Outliner.block.Cache_model.uuid)) first30 in
    ignore (measure "hydrate_first30_known_ids" cold_reads (fun () ->
      List.filter_map (Read.block ~with_breadcrumbs:false plain cold_db) eids));
    let current_reads = ref 0 in
    let current_db = restore path current_reads in
    ignore (measure "current_first30_read_flatten_encode" current_reads (fun () ->
      let blocks = Read.blocks_for_page plain current_db uuid in
      let context = Outliner.context blocks [] [] in
      let rows = take 30 (Outliner.visible_rows context Outliner.empty) in
      Yojson.Basic.to_string (`List (List.map (Rpc.outliner_row_json None Rpc.block_json) rows))))
  done;
  let stages = Hashtbl.fold (fun name values result ->
    let times = List.sort compare (List.map fst values) in
    let n = List.length times in
    (name, `Assoc [
      "median_ms", `Float (List.nth times (n / 2));
      "min_ms", `Float (List.hd times);
      "max_ms", `Float (List.nth times (n - 1));
      "mean_storage_reads", `Float (float_of_int (List.fold_left (fun n (_, reads) -> n + reads) 0 values) /. float_of_int n)
    ]) :: result) samples [] |> List.sort compare in
  print_endline (Yojson.Basic.pretty_to_string (`Assoc [
    "page_uuid", `String uuid; "iterations", `Int iterations;
    "runtime", `String "native OCaml / Dune dev profile";
    "cold_cache", `String "DataScript node cache; OS page cache retained";
    "visible_rows", `Int !row_count; "child_rows", `Int !child_count;
    "first30_json_bytes", `Int !first30_bytes;
    "stages", `Assoc stages
  ]))
