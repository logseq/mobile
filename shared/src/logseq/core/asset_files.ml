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

let resolve_path checkpoint_path source_path =
  if Filename.is_relative source_path then
    match checkpoint_path with
    | Some checkpoint ->
      Filename.concat
        (Filename.dirname checkpoint |> Filename.dirname |> Filename.dirname)
        source_path
    | None -> source_path
  else source_path

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
  let rec ensure_directory path =
    if not (Sys.file_exists path) then begin
      ensure_directory (Filename.dirname path);
      Unix.mkdir path 0o700
    end
  in
  try
    ensure_directory (Filename.dirname path);
    let temporary = Filename.temp_file ~temp_dir:(Filename.dirname path) "download-" ".tmp" in
    Fun.protect ~finally:(fun () -> if Sys.file_exists temporary then Sys.remove temporary)
      (fun () -> match write_file temporary contents with
        | Error _ as error -> error
        | Ok () -> Sys.rename temporary path; Ok ())
  with error -> Error ("Cache asset: " ^ Printexc.to_string error)
