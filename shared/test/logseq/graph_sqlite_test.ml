open Test_util

module Db = Sqlite3
module Sql = Graph_sqlite

let with_path f =
  let path = Filename.temp_file "logseq-graph-sqlite" ".sqlite" in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists path then Sys.remove path)
    (fun () -> f path)

let execute path sql =
  let connection = Db.db_open path in
  Fun.protect
    ~finally:(fun () -> ignore (Db.db_close connection))
    (fun () ->
      match Db.exec connection sql with
      | Db.Rc.OK -> ()
      | _ -> failwith ("execute failed: " ^ sql))

let row addr content addresses : Snapshot.snapshot_row =
  { Snapshot.addr; content; addresses }

let query_text path statement =
  Sql.with_db path
    (fun connection ->
      Sql.query connection statement [] (fun s -> Db.column_text s 0))

let failure f =
  try
    f ();
    false
  with
  | Failure _ -> true
  | _ -> false

let graph_rows_preserve_order_null_and_upserts () =
  with_path (fun path ->
    Sql.prepare_staging path;
    Sql.append_staging path [ row 9 "nine" None; row 2 "two" (Some "[]") ];
    check_eq [ 2; 9 ] (Sql.list_stored_addresses path);
    Sql.append_staging path [ row 9 "updated" (Some "") ];
    check_eq (Some ("updated", Some "")) (Sql.read_stored_row path 9);
    Sql.delete_stored_addresses path [ 9; 100 ];
    check_eq None (Sql.read_stored_row path 9);
    check_eq [ 2 ] (Sql.list_stored_addresses path);
    execute path "INSERT INTO kvs VALUES (3, NULL, NULL)";
    check_eq (Some ("", None)) (Sql.read_stored_row path 3))

let graph_row_batches_roll_back_on_insert_and_delete_failures () =
  with_path (fun path ->
    Sql.prepare_staging path;
    execute path
      "CREATE TRIGGER reject_bad BEFORE INSERT ON kvs WHEN NEW.addr = 2 \
       BEGIN SELECT RAISE(ABORT, 'rejected'); END";
    check
      (failure (fun () ->
         Sql.append_staging path [ row 1 "one" None; row 2 "two" None ]));
    check_eq None (Sql.read_stored_row path 1);
    execute path "DROP TRIGGER reject_bad";
    Sql.append_staging path [ row 1 "one" None; row 2 "two" None ];
    execute path
      "CREATE TRIGGER reject_delete BEFORE DELETE ON kvs WHEN OLD.addr = 2 \
       BEGIN SELECT RAISE(ABORT, 'rejected'); END";
    check (failure (fun () -> Sql.delete_stored_addresses path [ 1; 2 ]));
    check_eq [ 1; 2 ] (Sql.list_stored_addresses path))

let pending_operation_upserts_retain_sequence () =
  with_path (fun path ->
    Sql.store_pending path "first" 7 "queued" "first intent";
    Sql.store_pending path "second" 8 "queued" "second intent";
    Sql.store_pending path "first" 9 "submitted" "updated intent";
    check_eq
      [
        ("first", 9, "submitted", "updated intent");
        ("second", 8, "queued", "second intent");
      ]
      (Sql.list_pending path);
    Sql.set_pending_state path "first" "applied";
    Sql.remove_pending path "second";
    check_eq [ ("first", 9, "applied", "updated intent") ]
      (Sql.list_pending path))

let search_batches_update_fts_and_roll_back () =
  with_path (fun path ->
    Sql.search_open path;
    Sql.search_upsert path
      [ ("a", "alpha first", "page"); ("b", "beta second", "page") ];
    Sql.search_upsert path [ ("a", "gamma updated", "page") ];
    check_eq []
      (Sql.search_query path
         "SELECT id, page, title FROM blocks_fts WHERE title MATCH ?"
         [ "alpha" ]);
    check_eq [ ("a", "page", "gamma updated") ]
      (Sql.search_query path
         "SELECT id, page, title FROM blocks_fts WHERE title MATCH ?"
         [ "gamma" ]);
    execute path
      "CREATE TRIGGER reject_bad BEFORE INSERT ON blocks WHEN NEW.id = 'bad' \
       BEGIN SELECT RAISE(ABORT, 'rejected'); END";
    check
      (failure (fun () ->
         Sql.search_upsert path
           [ ("good", "new entry", "page"); ("bad", "bad entry", "page") ]));
    check_eq []
      (Sql.search_query path
         "SELECT id, page, title FROM blocks WHERE id = ?" [ "good" ]);
    Sql.search_delete path [ "a" ];
    check_eq []
      (Sql.search_query path
         "SELECT id, page, title FROM blocks_fts WHERE title MATCH ?"
         [ "gamma" ]))

let app_table_copy_retains_pending_metadata () =
  with_path (fun source ->
    with_path (fun destination ->
      Sql.prepare_staging source;
      Sql.prepare_staging destination;
      Sql.store_pending source "first" 7 "queued" "intent";
      Sql.store_pending source "second" 8 "queued" "intent two";
      Sql.store_local_properties source ["view", "logseq.property.table/sorting", "[]"];
      execute source
        "INSERT INTO logseq_pending_op_dependencies VALUES ('second', \
         'first'); INSERT INTO logseq_sync_state VALUES ('cursor', '8')";
      Sql.copy_app_tables source destination;
      check_eq ~msg:"Replacing a server snapshot preserves device-local view settings"
        (Sql.local_properties source) (Sql.local_properties destination);
      check_eq (Sql.list_pending source) (Sql.list_pending destination);
      check_eq [ "first" ]
        (query_text destination
           "SELECT depends_on_operation_id FROM \
            logseq_pending_op_dependencies WHERE operation_id = \
            'second'");
      check_eq [ "8" ]
        (query_text destination
           "SELECT value FROM logseq_sync_state WHERE key = 'cursor'")))

let app_table_copy_rolls_back_all_tables () =
  with_path (fun source ->
    with_path (fun destination ->
      Sql.prepare_staging source;
      Sql.prepare_staging destination;
      Sql.store_pending source "first" 7 "queued" "intent";
      execute source
        "INSERT INTO logseq_sync_state VALUES ('cursor', '8')";
      execute destination
        "INSERT INTO logseq_sync_state VALUES ('cursor', 'old')";
      check (failure (fun () -> Sql.copy_app_tables source destination));
      check_eq [] (Sql.list_pending destination);
      check_eq [ "old" ]
        (query_text destination
           "SELECT value FROM logseq_sync_state WHERE key = 'cursor'")))

let reader_resets_after_a_missing_row () =
  with_path (fun path ->
    Sql.prepare_staging path;
    let reader = Sql.open_reader path in
    check_eq None (Sql.reader_row reader 1);
    Sql.append_staging path [ row 1 "committed" None ];
    check_eq (Some ("committed", None)) (Sql.reader_row reader 1);
    Sql.delete_stored_addresses path [ 1 ];
    check_eq None (Sql.reader_row reader 1))

let database_open_and_reader_prepare_errors_remain_failures () =
  with_path (fun path ->
    let missing_parent = path ^ "/missing.sqlite" in
    check (failure (fun () -> Sql.search_open missing_parent));
    check (failure (fun () -> ignore (Sql.open_reader missing_parent)));
    check (failure (fun () -> ignore (Sql.open_reader path))))

let cases =
  [
    case "graph rows preserve order null and upserts"
      graph_rows_preserve_order_null_and_upserts;
    case "graph row batches roll back on insert and delete failures"
      graph_row_batches_roll_back_on_insert_and_delete_failures;
    case "pending operation upserts retain sequence"
      pending_operation_upserts_retain_sequence;
    case "search batches update fts and roll back"
      search_batches_update_fts_and_roll_back;
    case "app table copy retains pending metadata"
      app_table_copy_retains_pending_metadata;
    case "app table copy rolls back all tables"
      app_table_copy_rolls_back_all_tables;
    case "reader resets after a missing row" reader_resets_after_a_missing_row;
    case "database open and reader prepare errors remain failures"
      database_open_and_reader_prepare_errors_remain_failures;
  ]
