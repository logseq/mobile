open Test_util

module Value = Transit_core.Json
module Codec = Transit_native.Transit.Json

let success = Ok ()

let expect_ok result =
  match result with
  | Ok value -> value
  | Error message -> failwith message

let crypto : E2ee.e2ee_crypto =
  {
    decrypt_private_key = (fun _ _ _ _ _ -> Ok "private-key");
    decrypt_graph_key = (fun _ _ -> Ok "remote-graph-key");
    encrypt_graph_key = (fun _ _ -> Error "unused");
    random_bytes = (fun _ -> Error "unused");
    encrypt_aes_gcm = (fun _ _ -> Ok ("iv", "ciphertext"));
    decrypt_aes_gcm =
      (fun _ _ _ -> Ok (Codec.to_string (Value.String "decrypted title")));
  }

let config : Api.api_config =
  {
    base_url = "https://api.example";
    graph_id = "encrypted-graph";
    graph_name = Some "Private";
    token = "access-token";
  }

let private_package =
  Codec.to_string
    (Value.Array
       [
         Value.String "20251210";
         Value.Binary "salt";
         Value.Binary "private-iv";
         Value.Binary "encrypted-private";
       ])

let graph_package = Codec.to_string (Value.Binary "encrypted-graph-key")

let response status body =
  Ok { Api.status; body }

let json_body entries =
  Yojson.Basic.to_string
    (`Assoc (List.map (fun (key, value) -> (key, `String value)) entries))

let fetch (request : Api.api_request) =
  response 200
    (json_body
       (if String.ends_with ~suffix:"/user-keys" request.url then
          [
            ("public-key", "public");
            ("encrypted-private-key", private_package);
          ]
        else [ ("encrypted-aes-key", graph_package) ]))

let unlock_fetches_and_securely_persists_both_keys () =
  let requests = ref [] in
  let saved = ref [] in
  let passwords = ref [] in
  let ring =
    E2ee_keyring.create crypto
      (fun _ -> Ok None)
      (fun graph key -> saved := !saved @ [ (graph, key) ]; success)
      (fun () -> Ok None)
      (fun password -> passwords := !passwords @ [ password ]; success)
      (fun (request : Api.api_request) ->
         requests := !requests @ [ request.url ];
         fetch request)
  in
  check_eq "remote-graph-key"
    (expect_ok (E2ee_keyring.unlock ring config "e2etest"));
  check_eq [ ("encrypted-graph", "remote-graph-key") ] !saved;
  check_eq [ "e2etest" ] !passwords;
  check_eq 2 (List.length !requests)

let cached_account_password_opens_an_uncached_graph_without_rewriting_password
    () =
  let loads = ref 0 in
  let saves = ref 0 in
  let ring =
    E2ee_keyring.create crypto
      (fun _ -> Ok None)
      (fun _ _ -> success)
      (fun () -> incr loads; Ok (Some "e2etest"))
      (fun _ -> incr saves; success)
      fetch
  in
  check_eq "remote-graph-key" (expect_ok (E2ee_keyring.load_cached ring config));
  check_eq 1 !loads;
  check_eq 0 !saves

let multiple_graphs_reuse_the_decrypted_account_private_key () =
  let decryptions = ref 0 in
  let engine =
    { crypto with
      E2ee.decrypt_private_key =
        (fun _ _ _ _ _ -> incr decryptions; Ok "private-key");
    }
  in
  let ring =
    E2ee_keyring.create engine
      (fun _ -> Ok None)
      (fun _ _ -> success)
      (fun () -> Ok (Some "e2etest"))
      (fun _ -> success)
      fetch
  in
  ignore (expect_ok (E2ee_keyring.load_cached ring config));
  ignore
    (expect_ok
       (E2ee_keyring.load_cached ring
          { config with graph_id = "second-encrypted-graph" }));
  check_eq 1 !decryptions

let securely_cached_graph_key_opens_offline () =
  let requests = ref 0 in
  let ring =
    E2ee_keyring.create crypto
      (fun graph ->
         Ok (if graph = "encrypted-graph" then Some "cached-key" else None))
      (fun _ _ -> success)
      (fun () -> Ok None)
      (fun _ -> success)
      (fun _ -> incr requests; Error "offline")
  in
  check_eq "cached-key" (expect_ok (E2ee_keyring.load_cached ring config));
  check_eq 0 !requests

let wrong_password_never_persists_key_or_password () =
  let saves = ref 0 in
  let passwords = ref 0 in
  let engine =
    { crypto with
      E2ee.decrypt_private_key = (fun _ _ _ _ _ -> Error "wrong password");
    }
  in
  let ring =
    E2ee_keyring.create engine
      (fun _ -> Ok None)
      (fun _ _ -> incr saves; success)
      (fun () -> Ok None)
      (fun _ -> incr passwords; success)
      fetch
  in
  check
    (match E2ee_keyring.unlock ring config "wrong" with
     | Error _ -> true
     | Ok _ -> false);
  check_eq 0 !saves;
  check_eq 0 !passwords

let title_codec_uses_the_loaded_key_and_logseq_transit_envelope () =
  let ring =
    E2ee_keyring.create crypto
      (fun _ -> Ok (Some "cached-key"))
      (fun _ _ -> success)
      (fun () -> Ok None)
      (fun _ -> success)
      (fun _ -> Error "unused")
  in
  ignore (expect_ok (E2ee_keyring.load_cached ring config));
  let encrypted =
    expect_ok
      (E2ee_keyring.encrypt_title ring "encrypted-graph" "plain title")
  in
  check_eq
    (Value.Array [ Value.Binary "iv"; Value.Binary "ciphertext" ])
    (Codec.of_string encrypted);
  check_eq "decrypted title"
    (expect_ok (E2ee_keyring.decrypt_title ring "encrypted-graph" encrypted))

let assets_encrypt_raw_bytes_with_the_loaded_key () =
  let plaintext = ref None in
  let engine =
    { crypto with
      E2ee.encrypt_aes_gcm =
        (fun key value ->
           check_eq "cached-key" key;
           plaintext := Some value;
           Ok ("asset-iv", "asset-ciphertext"));
    }
  in
  let ring =
    E2ee_keyring.create engine
      (fun _ -> Ok (Some "cached-key"))
      (fun _ _ -> success)
      (fun () -> Ok None)
      (fun _ -> success)
      (fun _ -> Error "unused")
  in
  ignore (expect_ok (E2ee_keyring.load_cached ring config));
  let encrypted =
    expect_ok
      (E2ee_keyring.encrypt_asset ring "encrypted-graph" "raw-image-bytes")
  in
  check_eq "raw-image-bytes"
    (match !plaintext with
     | Some value -> value
     | None -> failwith "missing plaintext");
  check_eq
    (Value.Array
       [ Value.Binary "asset-iv"; Value.Binary "asset-ciphertext" ])
    (Codec.of_string encrypted)

let provision_crypto =
  { crypto with
    E2ee.random_bytes = (fun count -> Ok (String.make count 'a'));
    encrypt_graph_key = (fun public plaintext -> Ok (public ^ plaintext));
  }

let public_package = Codec.to_string (Value.Binary "public")

let public_response () =
  response 200
    (json_body
       [
         ("public-key", public_package);
         ("encrypted-private-key", "unused");
       ])

let provision_uploads_and_caches_the_new_graph_key () =
  let uploaded_body = ref None in
  let saved = ref None in
  let ring =
    E2ee_keyring.create provision_crypto
      (fun _ -> Ok None)
      (fun _ key -> saved := Some key; success)
      (fun () -> Ok None)
      (fun _ -> success)
      (fun (request : Api.api_request) ->
         if request.method_ = "POST" then uploaded_body := request.body;
         if String.ends_with ~suffix:"/user-keys" request.url then
           public_response ()
         else response 200 "{}")
  in
  let key =
    expect_ok
      (E2ee_keyring.provision ring
         { config with
           graph_id = "new-graph";
           graph_name = None;
           token = "token";
         })
  in
  let body =
    match !uploaded_body with
    | Some body -> body
    | None -> failwith "missing upload body"
  in
  check_eq (String.make 32 'a') key;
  check_eq (Some key) !saved;
  check_eq (Value.Binary ("public" ^ key))
    (Codec.of_string (Api.graph_key_from_body body))

let failed_unlock_preserves_locked_state_and_persistence_order () =
  List.iter
    (fun failure ->
       let writes = ref [] in
       let ring =
         E2ee_keyring.create crypto
           (fun _ -> Ok None)
           (fun _ _ ->
              writes := !writes @ [ "key" ];
              if failure = "save-key" then Error "key storage failed"
              else success)
           (fun () -> Ok None)
           (fun _ ->
              writes := !writes @ [ "password" ];
              if failure = "save-password" then
                Error "password storage failed"
              else success)
           (fun request ->
              match failure with
              | "network" -> Error "offline"
              | "http" -> response 403 "denied"
              | "json" -> response 200 "{"
              | _ -> fetch request)
       in
       (match E2ee_keyring.unlock ring config "password" with
        | Error message -> check (message <> "")
        | Ok _ -> check false);
       check_eq (Error "encrypted graph is locked")
         (E2ee_keyring.graph_key ring config.graph_id);
       check_eq (Error "E2EE password is not cached")
         (E2ee_keyring.load_cached ring config);
       check_eq
         (match failure with
          | "save-password" -> [ "password" ]
          | "save-key" -> [ "password"; "key" ]
          | _ -> [])
         !writes)
    [ "network"; "http"; "json"; "save-password"; "save-key" ]

let memory_cache_avoids_storage_reads_and_locked_operations_fail () =
  let loads = ref 0 in
  let ring =
    E2ee_keyring.create crypto
      (fun graph ->
         incr loads;
         if graph = config.graph_id then Ok (Some "cached-key")
         else Error "storage unavailable")
      (fun _ _ -> failwith "unexpected save")
      (fun () -> failwith "unexpected password load")
      (fun _ -> failwith "unexpected password save")
      (fun _ -> failwith "unexpected network request")
  in
  List.iter
    (fun result -> check_eq (Error "encrypted graph is locked") result)
    [
      E2ee_keyring.encrypt_title ring "locked" "text";
      E2ee_keyring.encrypt_asset ring "locked" "bytes";
      E2ee_keyring.decrypt_title ring "locked" "ciphertext";
    ];
  check_eq "cached-key" (expect_ok (E2ee_keyring.load_cached ring config));
  check_eq "cached-key" (expect_ok (E2ee_keyring.load_cached ring config));
  check_eq 1 !loads;
  check_eq (Error "storage unavailable")
    (E2ee_keyring.load_cached ring { config with graph_id = "other" })

let rejected_provision_upload_never_saves_or_unlocks () =
  let ring =
    E2ee_keyring.create
      { provision_crypto with
        E2ee.encrypt_graph_key = (fun _ _ -> Ok "wrapped");
      }
      (fun _ -> Ok None)
      (fun _ _ -> failwith "rejected upload must not be saved")
      (fun () -> Ok None)
      (fun _ -> failwith "provision must not save a password")
      (fun (request : Api.api_request) ->
         if request.method_ = "POST" then response 503 "unavailable"
         else public_response ())
  in
  check_eq (Error "upload graph E2EE key returned HTTP 503")
    (E2ee_keyring.provision ring config);
  check_eq (Error "encrypted graph is locked")
    (E2ee_keyring.graph_key ring config.graph_id)

let cases =
  [
    case "unlock fetches and securely persists both keys"
      unlock_fetches_and_securely_persists_both_keys;
    case
      "cached account password opens an uncached graph without rewriting password"
      cached_account_password_opens_an_uncached_graph_without_rewriting_password;
    case "multiple graphs reuse the decrypted account private key"
      multiple_graphs_reuse_the_decrypted_account_private_key;
    case "securely cached graph key opens offline"
      securely_cached_graph_key_opens_offline;
    case "wrong password never persists key or password"
      wrong_password_never_persists_key_or_password;
    case "title codec uses the loaded key and logseq transit envelope"
      title_codec_uses_the_loaded_key_and_logseq_transit_envelope;
    case "assets encrypt raw bytes with the loaded key"
      assets_encrypt_raw_bytes_with_the_loaded_key;
    case "provision uploads and caches the new graph key"
      provision_uploads_and_caches_the_new_graph_key;
    case "failed unlock preserves locked state and persistence order"
      failed_unlock_preserves_locked_state_and_persistence_order;
    case "memory cache avoids storage reads and locked operations fail"
      memory_cache_avoids_storage_reads_and_locked_operations_fail;
    case "rejected provision upload never saves or unlocks"
      rejected_provision_upload_never_saves_or_unlocks;
  ]
