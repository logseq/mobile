open Test_util

module Session = Sync_session
module Checkpoint = Sync_checkpoint
module Snapshot = Snapshot
module Store = Graph_store
module Codec = Storage_codec
module Bootstrap = Graph_bootstrap
module Transit = Transit_native.Transit.Json
module Value = Transit_core.Json
module Ds = Datascript

let expect_ok ?(msg = "expected Ok") result =
  match result with Ok value -> value | Error message -> fail (msg ^ ": " ^ message)

let fixture_wire title =
  let root =
    Value.Map
      [
        (Value.Keyword "schema",
         Value.Map
           [
             ( Value.Keyword "block/title",
               Value.Map
                 [
                   ( Value.Keyword "db/valueType",
                     Value.Keyword "db.type/string" );
                 ] );
           ]);
        (Value.Keyword "max-eid", Value.Int 1);
        (Value.Keyword "max-tx", Value.Int 536870913);
        (Value.Keyword "eavt", Value.Int 2);
        (Value.Keyword "aevt", Value.Int 3);
        (Value.Keyword "avet", Value.Int 4);
        (Value.Keyword "max-addr", Value.Int 4);
        (Value.Keyword "branching-factor", Value.Int 512);
        (Value.Keyword "ref-type", Value.Keyword "soft");
      ]
  in
  let leaf =
    Value.Map
      [
        ( Value.Keyword "keys",
          Value.Array
            [
              Value.Array
                [
                  Value.Int 1;
                  Value.Keyword "block/title";
                  Value.String title;
                  Value.Int 536870913;
                ];
            ] );
      ]
  in
  let rows =
    List.map
      (fun (addr, value) : Snapshot.snapshot_row ->
        {
          Snapshot.addr;
          content = Transit.to_string ~mode:Transit.Verbose value;
          addresses = None;
        })
      [
        (0, root);
        (1, Value.Array []);
        (2, leaf);
        (3, leaf);
        (4, leaf);
      ]
  in
  Bootstrap.frame_rows rows

let write_file path content =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr channel) (fun () ->
    output_string channel content)

let with_files f =
  let active = Filename.temp_file "logseq-session" ".sqlite" in
  let saved = Filename.temp_file "logseq-session" ".checkpoint" in
  let download = Filename.temp_file "logseq-session" ".snapshot" in
  Sys.remove active;
  Sys.remove saved;
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun path -> if Sys.file_exists path then Sys.remove path)
        [
          active;
          Store.staging_path active;
          saved;
          saved ^ ".tmp";
          download;
        ])
    (fun () -> f active saved download)

let metadata_rejects_invalid_fields () =
  List.iter
    (fun raw -> check_error (Session.decode_snapshot_metadata raw))
    [
      "[]";
      "{\"ok\":false}";
      "{\"url\":\"snapshot\"}";
      "{\"ok\":true,\"url\":\"\",\"t\":0,\"schema-version\":\"1\",\"row-count\":0}";
      "{\"ok\":true,\"url\":\"snapshot\",\"t\":-1,\"schema-version\":\"1\",\"row-count\":0}";
      "{\"ok\":true,\"url\":\"snapshot\",\"t\":0,\"schema-version\":\"1\",\"row-count\":-1}";
      "{\"ok\":true,\"url\":\"snapshot\",\"t\":0,\"schema-version\":\"1\",\"row-count\":0,\"content-encoding\":false}";
      "{\"ok\":true,\"url\":\"snapshot\",\"t\":0,\"schema-version\":\"1\",\"row-count\":0,\"content-encoding\":\"\"}";
    ]

let metadata_encoding_is_optional () =
  List.iter
    (fun suffix ->
      let body =
        "{\"ok\":true,\"url\":\"snapshot\",\"t\":0,\"schema-version\":\"1\",\"row-count\":0"
        ^ suffix ^ "}"
      in
      let metadata =
        expect_ok (Session.decode_snapshot_metadata body)
      in
      check_eq metadata.Session.content_encoding None)
    [ ""; ",\"content-encoding\":null" ]

let saved_cursor path =
  match expect_ok (Checkpoint.load_checkpoint path) with
  | Some checkpoint -> Some checkpoint.Checkpoint.applied_server_t
  | None -> None

let snapshot_import_failure_is_atomic_and_events_persist_cursor () =
  let body =
    "{\"ok\":true,\"key\":\"stream/graph-1.snapshot\",\"url\":\"https://sync.example/sync/graph-1/snapshot/stream\",\"content-encoding\":\"gzip\",\"t\":48192,\"schema-version\":\"65.33\",\"row-count\":5}"
  in
  let metadata = expect_ok (Session.decode_snapshot_metadata body) in
  check_eq metadata.baseline_t 48192;
  check_eq metadata.row_count (Some 5);
  check_eq metadata.content_encoding (Some "gzip");
  with_files (fun active saved download ->
    write_file download (fixture_wire "Local title");
    let completed =
      expect_ok
        (Session.import_snapshot_file None "graph-1" active saved metadata
           download)
    in
    let original = expect_ok (Store.read_row active 0) in
    check_eq completed.Snapshot.applied_server_t 48192;
    ignore (expect_ok (Store.restore_db active));
    check_eq (saved_cursor saved) (Some 48192);
    write_file download "\x00\x00\x00\nbroken";
    check_error
      (Session.import_snapshot_file None "graph-1" active saved metadata
         download);
    check_eq (expect_ok (Store.read_row active 0)) original;
    check_eq (saved_cursor saved) (Some 48192);
    check_eq (Sys.file_exists (Store.staging_path active)) false;
    ignore (expect_ok (Store.restore_conn active)))

let decrypt value =
  if String.starts_with ~prefix:"cipher:" value then
    Ok (String.sub value 7 (String.length value - 7))
  else Error "expected encrypted snapshot title"

let encrypted_snapshot_persists_only_plaintext () =
  with_files (fun active saved download ->
    write_file download (fixture_wire "cipher:Private title");
    let metadata : Session.snapshot_metadata =
      {
        url = "https://sync.example/snapshot";
        content_encoding = None;
        baseline_t = 9;
        schema_version = Some "65.33";
        row_count = Some 5;
      }
    in
    ignore
      (expect_ok
         (Session.import_snapshot_file (Some decrypt) "encrypted-graph" active
            saved metadata download));
    let db = expect_ok (Store.restore_db active) in
    check_eq
      (List.map
         (fun (d : Ds.datom) -> d.v)
         (Ds.Db.datoms db Ds.Aevt ~a:"block/title" () |> List.of_seq))
      [ Ds.String "Private title" ];
    List.iter
      (fun addr ->
        match expect_ok (Store.read_row active addr) with
        | Some (content, _addresses) ->
          check ~msg:"stored address contains ciphertext"
            (not
               (try
                  ignore (Str.search_forward (Str.regexp_string "cipher:Private title") content 0);
                  true
                with Not_found -> false))
        | None -> fail "stored address has no row")
      (Graph_sqlite.list_stored_addresses active))

let encrypted_legacy_built_in_titles_are_also_decrypted () =
  let one = Codec.default_schema_attr in
  let schema : Ds.schema =
    [
      ("block/uuid", { one with Ds.value_type = Some Ds.UuidType });
      ("block/title", { one with Ds.value_type = Some Ds.StringType });
      ("logseq.property/built-in?", one);
    ]
  in
  let db =
    Ds.db_with
      [
        Ds.Add (Ds.Entity_id 1, "block/title", Ds.String "cipher:Private title");
        Ds.Add
          ( Ds.Entity_id 2,
            "block/uuid",
            Ds.Uuid "00000002-0000-0000-0000-000000000001" );
        Ds.Add (Ds.Entity_id 2, "block/title", Ds.String "cipher:Card");
      ]
      (Ds.empty_db ~schema ())
  in
  let plaintext = expect_ok (Session.plaintext_snapshot_db decrypt db) in
  List.iter
    (fun (eid, title) ->
      check_eq
        (List.map
           (fun (d : Ds.datom) -> d.v)
           (Ds.Db.datoms plaintext Ds.Eavt ~e:eid ~a:"block/title" ()
            |> List.of_seq))
        [ Ds.String title ])
    [ (1, "Private title"); (2, "Card") ]

let cases =
  [
    case "metadata rejects invalid fields" metadata_rejects_invalid_fields;
    case "metadata encoding is optional" metadata_encoding_is_optional;
    case "snapshot import failure is atomic and events persist cursor"
      snapshot_import_failure_is_atomic_and_events_persist_cursor;
    case "encrypted snapshot persists only plaintext"
      encrypted_snapshot_persists_only_plaintext;
    case "encrypted legacy built-in titles are also decrypted"
      encrypted_legacy_built_in_titles_are_also_decrypted;
  ]
