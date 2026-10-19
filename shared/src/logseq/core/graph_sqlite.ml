module Db = Sqlite3

let fail connection operation =
  failwith
    ("SQLite error while " ^ operation ^ ": " ^ Db.errmsg connection)

let check connection operation code =
  match code with
  | Db.Rc.OK | Db.Rc.DONE -> ()
  | _ -> fail connection operation

let open_db path =
  try Db.db_open path
  with Db.Error message ->
    failwith ("SQLite error while opening graph database: " ^ message)

let with_db path f =
  let connection = open_db path in
  Fun.protect
    ~finally:(fun () -> ignore (Db.db_close connection))
    (fun () -> f connection)

let execute connection sql =
  check connection "executing graph SQL" (Db.exec connection sql)

let prepare connection sql =
  try Db.prepare connection sql
  with Db.Error message ->
    failwith ("SQLite error while preparing graph SQL: " ^ message)

let with_statement connection sql f =
  let statement = prepare connection sql in
  Fun.protect
    ~finally:(fun () -> ignore (Db.finalize statement))
    (fun () -> f statement)

let bind_values connection statement values =
  check connection "binding graph SQL" (Db.bind_values statement values)

let transaction connection f =
  execute connection "BEGIN IMMEDIATE";
  try
    let result = f () in
    execute connection "COMMIT";
    result
  with error ->
    ignore (Db.exec connection "ROLLBACK");
    raise error

let command connection sql values =
  with_statement connection sql (fun statement ->
    bind_values connection statement values;
    check connection "executing graph statement" (Db.step statement))

let batch connection sql rows =
  transaction connection (fun () ->
    with_statement connection sql (fun statement ->
      List.iter
        (fun values ->
          bind_values connection statement values;
          check connection "writing graph row" (Db.step statement);
          check connection "resetting graph statement" (Db.reset statement);
          check connection "clearing graph bindings"
            (Db.clear_bindings statement))
        rows))

let query connection sql values decode =
  with_statement connection sql (fun statement ->
    bind_values connection statement values;
    let rec loop rows =
      match Db.step statement with
      | Db.Rc.ROW -> loop (decode statement :: rows)
      | Db.Rc.DONE -> List.rev rows
      | _ -> fail connection "reading graph rows"
    in
    loop [])

let ensure_app_schema connection =
  List.iter
    (execute connection)
    [
      "CREATE TABLE IF NOT EXISTS logseq_pending_ops (sequence INTEGER \
       PRIMARY KEY AUTOINCREMENT, operation_id TEXT NOT NULL UNIQUE, base_t \
       INTEGER NOT NULL, state TEXT NOT NULL, intent TEXT NOT NULL)";
      "CREATE TABLE IF NOT EXISTS logseq_pending_op_dependencies \
       (operation_id TEXT NOT NULL, depends_on_operation_id TEXT NOT NULL, \
       PRIMARY KEY (operation_id, depends_on_operation_id), FOREIGN KEY \
       (operation_id) REFERENCES logseq_pending_ops(operation_id) ON \
       DELETE CASCADE, FOREIGN KEY (depends_on_operation_id) REFERENCES \
       logseq_pending_ops(operation_id) ON DELETE CASCADE)";
      "CREATE TABLE IF NOT EXISTS logseq_sync_state (key TEXT PRIMARY \
       KEY, value TEXT NOT NULL)";
      "CREATE TABLE IF NOT EXISTS logseq_pending_txs (operation_id TEXT \
       PRIMARY KEY, tx TEXT NOT NULL, reversed_tx TEXT NOT NULL)";
    ]

let with_app_db path f =
  with_db path (fun connection ->
    ensure_app_schema connection;
    f connection)

let prepare_staging path =
  with_db path (fun connection ->
    execute connection
      "CREATE TABLE kvs (addr INTEGER PRIMARY KEY, content TEXT, addresses \
       JSON)";
    ensure_app_schema connection)

let copy_app_tables source destination =
  with_db source ensure_app_schema;
  with_app_db destination (fun connection ->
    command connection "ATTACH DATABASE ? AS app_source" [ Db.Data.TEXT source ];
    Fun.protect
      ~finally:(fun () -> execute connection "DETACH DATABASE app_source")
      (fun () ->
        transaction connection (fun () ->
          List.iter
            (execute connection)
            [
              "INSERT INTO main.logseq_pending_ops (sequence, \
               operation_id, base_t, state, intent) SELECT sequence, \
               operation_id, base_t, state, intent FROM \
               app_source.logseq_pending_ops ORDER BY sequence";
              "INSERT INTO main.logseq_pending_op_dependencies \
               (operation_id, depends_on_operation_id) SELECT operation_id, \
               depends_on_operation_id FROM \
               app_source.logseq_pending_op_dependencies";
              "INSERT INTO main.logseq_sync_state (key, value) SELECT \
               key, value FROM app_source.logseq_sync_state";
              "INSERT INTO main.logseq_pending_txs (operation_id, tx, reversed_tx) \
               SELECT operation_id, tx, reversed_tx FROM app_source.logseq_pending_txs";
            ])))

let nullable_text value =
  match value with Some text -> Db.Data.TEXT text | None -> Db.Data.NULL

let append_staging path rows =
  with_db path (fun connection ->
    batch connection
      "INSERT INTO kvs (addr, content, addresses) VALUES (?, ?, ?) ON \
       CONFLICT(addr) DO UPDATE SET content = excluded.content, addresses = \
       excluded.addresses"
      (List.map
         (fun (row : Snapshot.snapshot_row) ->
           [
             Db.Data.INT (Int64.of_int row.addr);
             Db.Data.TEXT row.content;
             nullable_text row.addresses;
           ])
         rows))

let decode_row statement =
  ( Db.column_text statement 0
  , match Db.column statement 1 with
    | Db.Data.NULL -> None
    | _ -> Some (Db.column_text statement 1) )

let read_stored_row path address =
  with_db path (fun connection ->
    match
      query connection
        "SELECT content, addresses FROM kvs WHERE addr = ?"
        [ Db.Data.INT (Int64.of_int address) ]
        decode_row
    with
    | row :: _ -> Some row
    | [] -> None)

let list_stored_addresses path =
  with_db path (fun connection ->
    query connection "SELECT addr FROM kvs ORDER BY addr" []
      (fun statement -> Db.column_int statement 0))

let delete_stored_addresses path addresses =
  with_db path (fun connection ->
    batch connection "DELETE FROM kvs WHERE addr = ?"
      (List.map (fun address -> [ Db.Data.INT (Int64.of_int address) ]) addresses))

type graph_reader =
  { connection : Db.db
  ; statement : Db.stmt
  }

let close_reader reader =
  ignore (Db.finalize reader.statement);
  ignore (Db.db_close reader.connection)

let open_reader path =
  let connection = open_db path in
  try
    let reader =
      {
        connection;
        statement =
          prepare connection
            "SELECT content, addresses FROM kvs WHERE addr = ?";
      }
    in
    Gc.finalise close_reader reader;
    reader
  with error ->
    ignore (Db.db_close connection);
    raise error

let reader_row reader address =
  let connection = reader.connection in
  let statement = reader.statement in
  Fun.protect
    ~finally:(fun () -> ignore (Db.reset statement))
    (fun () ->
      check connection "binding graph address" (Db.bind_int statement 1 address);
      match Db.step statement with
      | Db.Rc.ROW -> Some (decode_row statement)
      | Db.Rc.DONE -> None
      | _ -> fail connection "reading graph node")

let write_pending connection operation_id base_t state intent =
    command connection
      "INSERT INTO logseq_pending_ops (operation_id, base_t, state, \
       intent) VALUES (?, ?, ?, ?) ON CONFLICT(operation_id) DO UPDATE SET \
       base_t = excluded.base_t, state = excluded.state, intent = \
       excluded.intent"
      [
        Db.Data.TEXT operation_id;
        Db.Data.INT (Int64.of_int base_t);
        Db.Data.TEXT state;
        Db.Data.TEXT intent;
      ]

let store_pending path operation_id base_t state intent =
  with_app_db path (fun connection -> write_pending connection operation_id base_t state intent)

let list_pending path =
  with_app_db path (fun connection ->
    query connection
      "SELECT operation_id, base_t, state, intent FROM \
       logseq_pending_ops ORDER BY sequence"
      []
      (fun statement ->
        ( Db.column_text statement 0
        , Db.column_int statement 1
        , Db.column_text statement 2
        , Db.column_text statement 3 )))

let set_pending_state path operation_id state =
  with_app_db path (fun connection ->
    command connection
      "UPDATE logseq_pending_ops SET state = ? WHERE operation_id = ?"
      [ Db.Data.TEXT state; Db.Data.TEXT operation_id ])

let remove_pending path operation_id =
  with_app_db path (fun connection ->
    transaction connection (fun () ->
    command connection "DELETE FROM logseq_pending_txs WHERE operation_id = ?"
      [ Db.Data.TEXT operation_id ];
    command connection
      "DELETE FROM logseq_pending_ops WHERE operation_id = ?"
      [ Db.Data.TEXT operation_id ]))

let write_pending_tx connection operation_id tx reversed_tx =
    command connection
      "INSERT INTO logseq_pending_txs (operation_id, tx, reversed_tx) VALUES (?, ?, ?) \
       ON CONFLICT(operation_id) DO UPDATE SET tx = excluded.tx, reversed_tx = excluded.reversed_tx"
      [ Db.Data.TEXT operation_id; Db.Data.TEXT tx; Db.Data.TEXT reversed_tx ]

let store_pending_tx path operation_id tx reversed_tx =
  with_app_db path (fun connection -> write_pending_tx connection operation_id tx reversed_tx)

let store_resolved_pending path operation_id base_t state intent tx reversed_tx =
  with_app_db path (fun connection ->
    transaction connection (fun () ->
      write_pending connection operation_id base_t state intent;
      write_pending_tx connection operation_id tx reversed_tx))

let pending_tx path operation_id =
  with_app_db path (fun connection ->
    match query connection "SELECT tx, reversed_tx FROM logseq_pending_txs WHERE operation_id = ?"
            [ Db.Data.TEXT operation_id ]
            (fun statement -> Db.column_text statement 0, Db.column_text statement 1) with
    | [] -> None
    | value :: _ -> Some value)

let ensure_search_schema connection =
  List.iter
    (execute connection)
    [
      "CREATE TABLE IF NOT EXISTS blocks (id TEXT NOT NULL PRIMARY KEY, \
       title TEXT NOT NULL, page TEXT)";
      "CREATE VIRTUAL TABLE IF NOT EXISTS blocks_fts USING fts5(id, title, \
       page, tokenize=\"trigram\")";
      "CREATE INDEX IF NOT EXISTS blocks_title_nocase_idx ON blocks(title \
       COLLATE NOCASE)";
      "CREATE TRIGGER IF NOT EXISTS blocks_ad AFTER DELETE ON blocks BEGIN \
       DELETE FROM blocks_fts WHERE id = old.id; END";
      "CREATE TRIGGER IF NOT EXISTS blocks_ai AFTER INSERT ON blocks BEGIN \
       INSERT INTO blocks_fts (id, title, page) VALUES (new.id, new.title, \
       new.page); END";
      "CREATE TRIGGER IF NOT EXISTS blocks_au AFTER UPDATE ON blocks BEGIN \
       DELETE FROM blocks_fts WHERE id = old.id; INSERT INTO blocks_fts (id, \
       title, page) VALUES (new.id, new.title, new.page); END";
    ]

let with_search_db path f =
  with_db path (fun connection ->
    ensure_search_schema connection;
    f connection)

let search_open path = with_db path ensure_search_schema

let search_upsert path rows =
  with_search_db path (fun connection ->
    batch connection
      "INSERT INTO blocks (id, title, page) VALUES (?, ?, ?) ON \
       CONFLICT(id) DO UPDATE SET (title, page) = (excluded.title, \
       excluded.page)"
      (List.map
         (fun (id, title, page) ->
           [ Db.Data.TEXT id; Db.Data.TEXT title; Db.Data.TEXT page ])
         rows))

let search_delete path ids =
  with_search_db path (fun connection ->
    batch connection "DELETE FROM blocks WHERE id = ?"
      (List.map (fun id -> [ Db.Data.TEXT id ]) ids))

let search_query path sql binds =
  with_search_db path (fun connection ->
    query connection sql
      (List.map (fun bind -> Db.Data.TEXT bind) binds)
      (fun statement ->
        ( Db.column_text statement 0
        , Db.column_text statement 1
        , Db.column_text statement 2 )))
