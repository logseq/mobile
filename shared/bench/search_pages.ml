(* Run against an isolated graph copy. Cold means a fresh DataScript node
   cache; SQLite and the OS may retain cached pages. The index path is temporary. *)
module Ds = Datascript

let measure reads f =
  let before = !reads and started = Unix.gettimeofday () in
  let result = f () in
  result, (Unix.gettimeofday () -. started) *. 1000., !reads - before

let () =
  if Array.length Sys.argv < 3 then failwith "usage: search_pages <graph.sqlite> <query> [iterations]";
  let path = Sys.argv.(1) and query = Sys.argv.(2) in
  let iterations = if Array.length Sys.argv > 3 then int_of_string Sys.argv.(3) else 5 in
  let index = Filename.temp_file "logseq-search-bench" ".sqlite" in
  Fun.protect ~finally:(fun () -> List.iter (fun suffix ->
    let file = index ^ suffix in if Sys.file_exists file then Sys.remove file) [""; "-wal"; "-shm"])
    (fun () ->
      let restore reads =
        let storage = Graph_store.storage path in
        let storage = { storage with Ds.storage_restore = (fun address ->
          incr reads; storage.storage_restore address) } in
        let conn = match Ds.restore_conn storage with Some conn -> conn | None -> failwith "Missing graph root" in
        Graph_runtime.create path 0 conn { Graph_runtime.default_options with search_index_path = Some index } in
      let reads = ref 0 in
      let initial = restore reads in
      let _, rebuild_ms, rebuild_reads = measure reads (fun () -> Graph_runtime.search initial query) in
      let samples = List.init iterations (fun _ ->
        let reads = ref 0 in
        let runtime, restore_ms, restore_reads = measure reads (fun () -> restore reads) in
        if not (Graph_runtime.state runtime).search_index_is_fresh then failwith "Persisted index was not reused";
        let (hits, more), first_ms, first_reads = measure reads (fun () ->
          Graph_runtime.search_page runtime ~offset:0 ~limit:20 query) in
        let (_, _), next_ms, next_reads = measure reads (fun () ->
          Graph_runtime.search_page runtime ~offset:20 ~limit:20 query) in
        `Assoc ["restore_ms", `Float restore_ms; "restore_reads", `Int restore_reads;
          "first_page_ms", `Float first_ms; "first_page_reads", `Int first_reads;
          "next_page_ms", `Float next_ms; "next_page_reads", `Int next_reads;
          "hits", `Int (List.length hits); "has_more", `Bool more]) in
      print_endline (Yojson.Basic.pretty_to_string (`Assoc [
        "runtime", `String "native OCaml / Dune dev profile";
        "cold_cache", `String "fresh DataScript node cache; OS cache retained";
        "initial_index_build_ms", `Float rebuild_ms; "initial_index_build_reads", `Int rebuild_reads;
        "samples", `List samples])))
