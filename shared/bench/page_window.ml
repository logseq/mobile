(* Native read-only benchmark over an exported graph or isolated fixture.
   Cold samples recreate DataScript's node cache, keeping the OS cache warm. *)
module Ds = Datascript
module Read = Graph_read

let samples = Hashtbl.create 8
let storage_samples = Hashtbl.create 8

let measure reads name operation =
  let before_reads = !reads in
  let started = Unix.gettimeofday () in
  let result = operation () in
  let elapsed = (Unix.gettimeofday () -. started) *. 1_000. in
  Hashtbl.replace samples name
    (elapsed :: Option.value ~default:[] (Hashtbl.find_opt samples name));
  Hashtbl.replace storage_samples name
    ((!reads - before_reads) :: Option.value ~default:[] (Hashtbl.find_opt storage_samples name));
  result

let restore reads path =
  let storage = Graph_store.storage path in
  let counted = { storage with Ds.storage_restore = (fun address ->
    incr reads; storage.storage_restore address) } in
  match Ds.restore counted with Some db -> db | None -> failwith "Missing DataScript root"

let () =
  if Array.length Sys.argv < 3 then
    failwith "usage: page_window <exported-graph.sqlite> <page-uuid> [iterations] [collapsed-uuid ...]";
  let path = Sys.argv.(1) and uuid = Sys.argv.(2) in
  let iterations = if Array.length Sys.argv > 3 then int_of_string Sys.argv.(3) else 30 in
  if iterations < 1 then invalid_arg "iterations must be positive";
  let collapsed = Array.to_list (Array.sub Sys.argv (min 4 (Array.length Sys.argv))
    (max 0 (Array.length Sys.argv - 4))) in
  let initial_rows = ref 0 and hydrated_titles = ref 0 and complete_rows = ref 0 in
  for _ = 1 to iterations do
    let reads = ref 0 in
    let db = measure reads "restore_root" (fun () -> restore reads path) in
    let reader = measure reads "create_reader" (fun () -> Read.page_reader ~collapsed db uuid) in
    let titles = ref 0 in
    let decrypt title = incr titles; Ok title in
    let first = measure reads "first_32_window" (fun () -> Read.read_page_window decrypt reader) in
    initial_rows := List.length first.rows;
    hydrated_titles := !titles;
    ignore (measure reads "repeat_first_32_window" (fun () -> Read.read_page_window (fun v -> Ok v) reader));
    (match first.next_offset with
     | Some offset ->
       ignore (measure reads "next_32_window" (fun () -> Read.read_page_window ~offset (fun v -> Ok v) reader))
     | None -> ());
    let baseline_reads = ref 0 in
    let baseline_db = restore baseline_reads path in
    let blocks = measure baseline_reads "existing_full_page_read" (fun () ->
      Read.blocks_for_page (fun v -> Ok v) baseline_db uuid) in
    complete_rows := List.length blocks
  done;
  let stages = Hashtbl.fold (fun name values result ->
    let values = List.sort Float.compare values in
    let count = List.length values in
    let percentile fraction = List.nth values
      (min (count - 1) (int_of_float (ceil (fraction *. float_of_int count)) - 1)) in
    let reads = Hashtbl.find storage_samples name in
    (name, `Assoc ["median_ms", `Float (percentile 0.5);
      "p95_ms", `Float (percentile 0.95);
      "mean_storage_reads", `Float (float_of_int (List.fold_left (+) 0 reads) /. float_of_int count)]) :: result)
    samples [] |> List.sort compare in
  print_endline (Yojson.Basic.pretty_to_string (`Assoc [
    "runtime", `String "native OCaml / existing Dune dev profile";
    "cold_cache", `String "DataScript node cache reset; OS cache retained; root restoration measured separately";
    "iterations", `Int iterations; "page_uuid", `String uuid;
    "collapsed", `List (List.map (fun uuid -> `String uuid) collapsed);
    "initial_rows", `Int !initial_rows; "initial_decrypted_titles", `Int !hydrated_titles;
    "complete_page_blocks", `Int !complete_rows; "stages", `Assoc stages]))
