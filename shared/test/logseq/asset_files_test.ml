let with_directory f =
  let path = Filename.temp_file "lg-asset-files-test" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect
    ~finally:(fun () ->
       Array.iter
         (fun name -> Sys.remove (Filename.concat path name))
         (Sys.readdir path);
       Unix.rmdir path)
    (fun () -> f path)

let expect_ok result =
  match result with
  | Ok value -> value
  | Error message -> failwith message

let relative_assets_resolve_against_the_graph_directory () =
  Test_util.check_eq
    (Asset_files.resolve_path
       (Some "/documents/graphs/id/sync.checkpoint")
       "assets/image.png")
    "/documents/graphs/id/assets/image.png";
  Test_util.check_eq
    (Asset_files.resolve_path None "assets/image.png")
    "assets/image.png";
  Test_util.check_eq
    (Asset_files.resolve_path
       (Some "/documents/graphs/id/sync.checkpoint") "/tmp/image.png")
    "/tmp/image.png"

let asset_file_roundtrip_preserves_bytes () =
  with_directory (fun dir ->
    let path = Filename.concat dir "source"
    and contents = "plain\x00asset\n" in
    ignore (expect_ok (Asset_files.write_file path contents));
    Test_util.check_eq (Asset_files.read_file path) (Ok contents);
    ignore (expect_ok (Asset_files.write_file path ""));
    Test_util.check_eq (Asset_files.read_file path) (Ok ""))

let file_errors_retain_operation_context () =
  with_directory (fun dir ->
    (match Asset_files.read_file (Filename.concat dir "missing") with
     | Error message ->
       Test_util.check ~msg:"read error context"
         (String.starts_with ~prefix:"read asset for encryption: "
            message)
     | _ -> Test_util.check false);
    match Asset_files.write_file dir "data" with
    | Error message ->
      Test_util.check ~msg:"write error context"
        (String.starts_with ~prefix:"write encrypted asset: " message)
    | _ -> Test_util.check false)

let encrypted_assets_use_a_separate_file_next_to_the_source () =
  with_directory (fun dir ->
    let source = Filename.concat dir "source"
    and contents = "asset\x00bytes" in
    let encrypt graph_id bytes = Ok (graph_id ^ ":" ^ bytes) in
    ignore (expect_ok (Asset_files.write_file source contents));
    let path, size =
      expect_ok (Asset_files.encrypt_file encrypt "graph" source)
    in
    Test_util.check ~msg:"separate output file" (path <> source);
    Test_util.check_eq (Filename.dirname path) dir;
    Test_util.check ~msg:"output name prefix"
      (String.starts_with ~prefix:"logseq-e2ee-"
         (Filename.basename path));
    Test_util.check ~msg:"transit suffix"
      (String.ends_with ~suffix:".transit" path);
    Test_util.check_eq size (String.length ("graph:" ^ contents));
    Test_util.check_eq (Asset_files.read_file path)
      (Ok ("graph:" ^ contents));
    Test_util.check_eq (Asset_files.read_file source) (Ok contents))

let encryption_errors_do_not_create_output_files () =
  with_directory (fun dir ->
    let source = Filename.concat dir "source" in
    ignore (expect_ok (Asset_files.write_file source "plain"));
    Test_util.check_eq
      (Asset_files.encrypt_file
         (fun _ _ -> Error "locked")
         "graph" source)
      (Error "locked");
    Test_util.check_eq (Array.to_list (Sys.readdir dir)) [ "source" ];
    Test_util.check_eq (Asset_files.read_file source) (Ok "plain"))

let missing_source_does_not_invoke_encryption () =
  with_directory (fun dir ->
    let called = ref false in
    let result =
      Asset_files.encrypt_file
        (fun _ bytes ->
           called := true;
           Ok bytes)
        "graph"
        (Filename.concat dir "missing")
    in
    Test_util.check (Result.is_error result);
    Test_util.check (not !called);
    Test_util.check (Array.length (Sys.readdir dir) = 0))

let cases =
  [ Test_util.case "relative assets resolve against the graph directory"
      relative_assets_resolve_against_the_graph_directory;
    Test_util.case "asset file roundtrip preserves bytes"
      asset_file_roundtrip_preserves_bytes;
    Test_util.case "file errors retain operation context"
      file_errors_retain_operation_context;
    Test_util.case "encrypted assets use a separate file next to the source"
      encrypted_assets_use_a_separate_file_next_to_the_source;
    Test_util.case "encryption errors do not create output files"
      encryption_errors_do_not_create_output_files;
    Test_util.case "missing source does not invoke encryption"
      missing_source_does_not_invoke_encryption ]
