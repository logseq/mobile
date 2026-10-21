external configure : int -> unit = "test_jni_mode"
external exception_pending : unit -> bool = "test_jni_exception_pending"
external send : string -> string -> string -> string -> string = "logseq_https_send"
external upload : string -> string -> string -> string -> string -> string = "logseq_https_upload_file"
external crypto : string -> string = "logseq_crypto_call"

let () =
  let mode = int_of_string Sys.argv.(1) in
  configure mode;
  let response = match Sys.argv.(2) with
    | "send" -> send "POST" "https://native.test/" "{}" "token"
    | "upload" -> upload "PUT" "https://native.test/" "/tmp/test.png" "image/png" "token"
    | _ -> crypto "{\"operation\":\"randomBytes\",\"count\":1}" in
  if exception_pending () then failwith "JNI exception leaked across the core boundary";
  if mode = 0 then begin
    if response <> "200\n{}" && response <> "{\"ok\":true}" then failwith response
  end else if String.starts_with ~prefix:"ERROR\n" response then ()
  else if String.starts_with ~prefix:"{\"ok\":false," response then ()
  else failwith "Native bridge must return an error"
