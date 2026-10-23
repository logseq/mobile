(* Adapt a closed SQLite export into an isolated, populated-today launch fixture. *)
module Ds = Datascript

let copy source destination =
  let input_channel = open_in_bin source in
  Fun.protect ~finally:(fun () -> close_in input_channel) (fun () ->
    let output_channel = open_out_bin destination in
    Fun.protect ~finally:(fun () -> close_out output_channel) (fun () ->
      let buffer = Bytes.create 65536 in
      let rec loop () = match input input_channel buffer 0 (Bytes.length buffer) with
        | 0 -> ()
        | count -> output output_channel buffer 0 count; loop () in
      loop ()))

let () =
  if Array.length Sys.argv <> 4 then
    failwith "usage: cold_start_fixture <closed-export.sqlite> <new-documents-directory> <graph-id>";
  let source = Sys.argv.(1) and root = Sys.argv.(2) and graph_id = Sys.argv.(3) in
  if Sys.file_exists root || graph_id = "" || String.contains graph_id '/' then
    failwith "Expected a new fixture directory and a simple graph ID";
  Unix.mkdir root 0o700;
  Unix.mkdir (root ^ "/graphs") 0o700;
  let graph = root ^ "/graphs/Benchmark-" ^ graph_id in
  Unix.mkdir graph 0o700;
  let path = graph ^ "/graph.sqlite" in
  copy source path;
  let conn = match Graph_store.restore_conn path with Ok conn -> conn | Error message -> failwith message in
  let db = Ds.conn_db conn in
  let current = Unix.localtime (Unix.gettimeofday ()) in
  let today = (current.Unix.tm_year + 1900) * 10000 + (current.tm_mon + 1) * 100 + current.tm_mday in
  let populated page =
    Datascript_value.datoms_by_ref db Ds.Aevt "block/page" page
    |> Seq.exists (fun (d : Ds.datom) -> match Graph_read.value db d.e "block/title" with
      | Some (Ds.String title) -> String.trim title <> "" && not (Graph_read.page_is_hidden db d.e)
      | _ -> false) in
  let latest = Graph_read.recent_journal_page_ids max_int db |> List.find_opt populated in
  let latest = match latest with Some page -> page | None -> failwith "The export contains no populated journal" in
  let original_day = Option.get (Graph_read.int_value (Graph_read.value db latest "block/journal-day")) in
  if original_day <> today then begin
    if Seq.exists (fun (d : Ds.datom) -> d.e <> latest)
      (Ds.Db.datoms db Ds.Avet ~a:"block/journal-day" ~v:(Ds.Int64 (Int64.of_int today)) ()) then
      failwith "The export already contains another journal for today; use its actual populated journal";
    let title = Journal.title db today in
    ignore (Ds.transact_conn conn [
      Ds.Add (Ds.Entity_id latest, "block/journal-day", Ds.Int64 (Int64.of_int today));
      Ds.Add (Ds.Entity_id latest, "block/title", Ds.String title);
      Ds.Add (Ds.Entity_id latest, "block/name", Ds.String (String.lowercase_ascii title));
    ]);
    ignore (Ds.store ~storage:(Graph_store.storage path) (Ds.conn_db conn))
  end;
  (match Sync_checkpoint.save_checkpoint_atomic (graph ^ "/sync.checkpoint")
    (Sync_checkpoint.create graph_id "65.34" 0) with Ok () -> () | Error message -> failwith message);
  let catalog = Sqlite.open_session (root ^ "/logseq.sqlite") in
  Sqlite.store_string catalog Mobile_session.graph_catalog_address
    (Yojson.Basic.to_string (`Assoc ["graphs", `List [`Assoc [
      "graph-id", `String graph_id; "graph-name", `String "Benchmark";
      "graph-e2ee?", `Bool false; "graph-ready-for-use?", `Bool true]] ]));
  Sqlite.close catalog;
  Printf.printf "Created isolated fixture: latest populated journal %d -> %d; original export unchanged\n%!"
    original_day today
