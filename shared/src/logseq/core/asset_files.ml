let read_file path : (string, string) result =
  try
    let channel = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () -> Ok (really_input_string channel (in_channel_length channel)))
  with error -> Error ("read asset for encryption: " ^ Printexc.to_string error)

let write_file path contents : (unit, string) result =
  try
    let channel = open_out_bin path in
    Fun.protect
      ~finally:(fun () -> close_out_noerr channel)
      (fun () -> output_string channel contents);
    Ok ()
  with error -> Error ("write encrypted asset: " ^ Printexc.to_string error)

let rec ensure_directory path =
  if not (Sys.file_exists path) then begin
    ensure_directory (Filename.dirname path);
    Unix.mkdir path 0o700
  end

let copy_file source destination =
  ensure_directory (Filename.dirname destination);
  let input = open_in_bin source in
  Fun.protect ~finally:(fun () -> close_in_noerr input) (fun () ->
    let temporary = Filename.temp_file ~temp_dir:(Filename.dirname destination) "asset-" ".tmp" in
    Fun.protect ~finally:(fun () -> if Sys.file_exists temporary then Sys.remove temporary) (fun () ->
      let output = open_out_bin temporary in
      Fun.protect ~finally:(fun () -> close_out_noerr output) (fun () ->
        let buffer = Bytes.create 65536 in
        let rec copy () =
          match Stdlib.input input buffer 0 (Bytes.length buffer) with
          | 0 -> ()
          | count -> Stdlib.output output buffer 0 count; copy ()
        in copy ());
      Sys.rename temporary destination))

let resolve_path checkpoint_path source_path =
  if Filename.is_relative source_path then
    match checkpoint_path with
    | Some checkpoint -> Filename.concat (Filename.dirname checkpoint) source_path
    | None -> source_path
  else source_path

let resolve_legacy_path checkpoint_path graph_id source_path =
  let resolved = resolve_path checkpoint_path source_path in
  match checkpoint_path with
  | None -> resolved
  | Some checkpoint ->
    let directory = Filename.dirname checkpoint in
    let assets = Filename.concat directory "Assets" in
    let name = Filename.basename source_path in
    let destination = Filename.concat assets name in
    let root = Filename.dirname directory |> Filename.dirname in
    let legacy_assets = Filename.concat root "Assets" in
    let candidates = if Filename.is_relative source_path then
        [resolved; Filename.concat legacy_assets (Filename.concat (Api.url_encode graph_id) name);
         Filename.concat legacy_assets name]
      else [source_path; destination; Filename.concat legacy_assets name] in
    if Sys.file_exists destination then destination
    else match List.find_opt (fun path -> Sys.file_exists path && not (Sys.is_directory path)) candidates with
      | Some source ->
        copy_file source destination; destination
      | None -> resolved

let import_file checkpoint_path graph_id uuid source_path =
  match checkpoint_path with
  | None -> Error "Open a graph before importing an asset"
  | Some checkpoint ->
    let source = if Sys.file_exists source_path then source_path
      else resolve_legacy_path checkpoint_path graph_id source_path in
    if not (Sys.file_exists source) || Sys.is_directory source then Error "The imported asset file is missing"
    else
      let directory = Filename.concat (Filename.dirname checkpoint) "Assets" in
      let name = if Filename.dirname source = directory then Filename.basename source
        else Api.url_encode uuid ^ "-" ^ Filename.basename source in
      let destination = Filename.concat directory name in
      try
        if source <> destination then copy_file source destination;
        Ok (Filename.concat "Assets" name)
      with error -> Error ("Import asset: " ^ Printexc.to_string error)

let encrypt_file encrypt graph_id source_path : (string * int, string) result =
  match read_file source_path with
  | Error _ as error -> error
  | Ok bytes ->
    (match encrypt graph_id bytes with
     | Error _ as error -> error
     | Ok encrypted ->
       let path =
         Filename.temp_file ~temp_dir:(Filename.dirname source_path)
           "logseq-e2ee-" ".transit"
       in
       (match write_file path encrypted with
        | Ok () -> Ok (path, String.length encrypted)
        | Error message ->
          (try Sys.remove path with _ -> ());
          Error message))

let cache_download path contents =
  try
    ensure_directory (Filename.dirname path);
    let temporary = Filename.temp_file ~temp_dir:(Filename.dirname path) "download-" ".tmp" in
    Fun.protect ~finally:(fun () -> if Sys.file_exists temporary then Sys.remove temporary)
      (fun () -> match write_file temporary contents with
        | Error _ as error -> error
        | Ok () -> Sys.rename temporary path; Ok ())
  with error -> Error ("Cache asset: " ^ Printexc.to_string error)
