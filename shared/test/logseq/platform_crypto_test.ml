open Test_util

module Json = Yojson.Basic
module Util = Yojson.Basic.Util
module Platform = Platform_crypto
module Keyring = E2ee_keyring

let call_raw = Native_crypto.call_raw

let response = ref "{\"ok\":true,\"value\":\"00ff\"}"

let request = ref (Json.from_string "{}")

let transport_failure = ref false
let collect_during_call = ref false

let () =
  Callback.register "platform_crypto_test_call" (fun input ->
    if !transport_failure then failwith "native crypto unavailable";
    request := Json.from_string input;
    if !collect_during_call then Gc.full_major ();
    !response)

let reset_transport () =
  transport_failure := false;
  collect_during_call := false;
  response := "{\"ok\":true,\"value\":\"00ff\"}"

let field name = Util.member name !request

let operation name = check_eq (`String name) (field "operation")

let config : Api.api_config =
  {
    Api.base_url = "https://api.example";
    graph_id = "graph";
    graph_name = None;
    token = "token";
  }

let native_keyring_loads_offline_and_keeps_graph_keys_isolated () =
  reset_transport ();
  let requests = ref 0 in
  let ring =
    Platform.create_keyring call_raw (fun _ ->
      incr requests;
      Error "offline")
  in
  let key = String.make 1 (Char.chr 0) ^ String.make 1 (Char.chr 255) in
  check_eq (Ok key) (Keyring.load_cached ring config);
  operation "loadGraphKey";
  check_eq (`String "graph") (field "graphID");
  check_eq (Ok key) (Keyring.graph_key ring "graph");
  check_eq (Error "encrypted graph is locked")
    (Keyring.graph_key ring "other");
  response := "{\"ok\":false,\"error\":\"locked\"}";
  check_eq (Ok key) (Keyring.load_cached ring config);
  check_eq (Error "locked")
    (Keyring.load_cached ring { config with Api.graph_id = "other" });
  check_eq 0 !requests

let native_keyring_preserves_cache_misses_and_transport_errors () =
  reset_transport ();
  let requests = ref 0 in
  let ring =
    Platform.create_keyring call_raw (fun _ ->
      incr requests;
      Error "offline")
  in
  response := "{\"ok\":true,\"value\":null}";
  check_eq (Error "E2EE password is not cached")
    (Keyring.load_cached ring config);
  operation "loadE2EEPassword";
  transport_failure := true;
  Fun.protect
    ~finally:reset_transport
    (fun () ->
      check_eq (Error "Failure(\"native crypto unavailable\")")
        (Keyring.load_cached ring config);
      check_eq 0 !requests)

let binary_hex_roundtrip () =
  let all_bytes = String.init 256 Char.chr in
  check_eq "00ff107f80"
    (Platform.hex (String.init 5 (fun i -> Char.chr (List.nth [ 0; 255; 16; 127; 128 ] i))));
  check_eq (Ok all_bytes) (Platform.unhex (Platform.hex all_bytes));
  check_eq (Ok "") (Platform.unhex "");
  check_eq
    (Ok (String.init 2 (fun i -> Char.chr (List.nth [ 171; 205 ] i))))
    (Platform.unhex "ABcd");
  List.iter
    (fun input ->
      check_eq (Error "platform crypto returned invalid hex")
        (Platform.unhex input))
    [ "0"; "gg"; "ffffx"; "zz" ]

let crypto_operations_cross_native_ffi () =
  reset_transport ();
  let engine = Platform.crypto call_raw in
  let zero = String.make 1 (Char.chr 0) in
  let one = String.make 1 (Char.chr 1) in
  let ff = String.make 1 (Char.chr 255) in
  let value = zero ^ ff in
  check_eq (Ok value)
    (engine.E2ee.decrypt_private_key "secret" 600000 zero one ff);
  operation "decryptPrivateKey";
  check_eq (`String "secret") (field "password");
  check_eq (`Int 600000) (field "iterations");
  check_eq (`String "00") (field "salt");
  check_eq (`String "01") (field "iv");
  check_eq (`String "ff") (field "ciphertext");
  check_eq (Ok value) (engine.decrypt_graph_key zero ff);
  operation "decryptGraphKey";
  check_eq (`String "00") (field "privateKey");
  check_eq (Ok value) (engine.encrypt_graph_key zero ff);
  operation "encryptGraphKey";
  check_eq (`String "00") (field "publicKey");
  check_eq (`String "ff") (field "plaintext");
  check_eq (Ok value) (engine.random_bytes 2);
  operation "randomBytes";
  check_eq (`Int 2) (field "count");
  response := "{\"ok\":true,\"iv\":\"0001\",\"ciphertext\":\"feff\"}";
  check_eq
    (Ok (zero ^ one, String.make 1 (Char.chr 254) ^ ff))
    (engine.encrypt_aes_gcm zero ff);
  operation "encryptAES";
  check_eq (`String "00") (field "key");
  reset_transport ();
  check_eq (Ok value) (engine.decrypt_aes_gcm zero one ff);
  operation "decryptAES";
  check_eq (`String "01") (field "iv")

let native_secret_cache_protocol () =
  reset_transport ();
  let all_bytes = String.init 256 Char.chr in
  let value = String.make 1 (Char.chr 0) ^ String.make 1 (Char.chr 255) in
  let password =
    String.make 1 (Char.chr 0) ^ "secret" ^ String.make 1 (Char.chr 255)
  in
  check_eq (Ok ()) (Platform.save_graph_key call_raw "graph" all_bytes);
  operation "saveGraphKey";
  check_eq (`String "graph") (field "graphID");
  check_eq (`String (Platform.hex all_bytes)) (field "key");
  check_eq (Ok (Some value))
    (Platform.load_graph_key call_raw "graph");
  operation "loadGraphKey";
  check_eq (Ok ()) (Platform.save_e2ee_password call_raw password);
  operation "saveE2EEPassword";
  check_eq (`String "00736563726574ff") (field "password");
  check_eq (Ok (Some value)) (Platform.load_e2ee_password call_raw);
  operation "loadE2EEPassword";
  List.iter
    (fun raw ->
      response := raw;
      check_eq (Ok None) (Platform.load_graph_key call_raw "graph");
      check_eq (Ok None) (Platform.load_e2ee_password call_raw))
    [ "{\"ok\":true}"; "{\"ok\":true,\"value\":null}" ];
  response := "{\"ok\":true,\"value\":42}";
  check_eq (Error "platform crypto returned invalid cached graph key")
    (Platform.load_graph_key call_raw "graph");
  check_eq (Error "platform crypto returned invalid cached E2EE password")
    (Platform.load_e2ee_password call_raw)

let malformed_responses_and_native_failure () =
  reset_transport ();
  let engine = Platform.crypto call_raw in
  List.iter
    (fun (raw, message) ->
      response := raw;
      check_eq (Error message) (engine.E2ee.random_bytes 2))
    [
      ("{\"ok\":false,\"error\":\"locked\"}", "locked");
      ("{\"ok\":false}", "platform crypto failed");
      ("{\"ok\":true}", "platform crypto response is missing value");
      ( "{\"ok\":true,\"value\":\"xx\"}"
      , "platform crypto returned invalid hex" );
      ( "{\"ok\":true,\"value\":null}"
      , "platform crypto response is missing value" );
      ("{\"ok\":false,\"ok\":true}", "platform crypto failed");
      ("[]", "platform crypto returned invalid JSON");
    ];
  response := "not JSON";
  (match engine.random_bytes 2 with
   | Error _ -> ()
   | Ok _ -> failwith "invalid JSON accepted");
  response := "{\"ok\":true,\"iv\":\"zz\",\"ciphertext\":\"00\"}";
  check_eq (Error "platform crypto returned invalid hex")
    (engine.encrypt_aes_gcm "" "");
  response := "{\"ok\":true,\"iv\":\"00\"}";
  check_eq (Error "platform crypto response is missing ciphertext")
    (engine.encrypt_aes_gcm "" "");
  transport_failure := true;
  Fun.protect
    ~finally:reset_transport
    (fun () ->
      check_eq (Error "Failure(\"native crypto unavailable\")")
        (engine.random_bytes 2))

let native_crypto_roots_survive_collection () =
  reset_transport ();
  collect_during_call := true;
  Fun.protect ~finally:reset_transport (fun () ->
    for index = 1 to 32 do
      let input = Json.to_string (`Assoc ["operation", `String "decryptAES";
        "ciphertext", `String (String.make (index * 1024) 'a')]) in
      check_eq !response (call_raw input);
      check_eq (Json.from_string input) !request;
      Gc.minor ()
    done)

let cases =
  [
    case "native crypto roots survive collection" native_crypto_roots_survive_collection;
    case "native keyring loads offline and keeps graph keys isolated"
      native_keyring_loads_offline_and_keeps_graph_keys_isolated;
    case "native keyring preserves cache misses and transport errors"
      native_keyring_preserves_cache_misses_and_transport_errors;
    case "binary hex roundtrip" binary_hex_roundtrip;
    case "crypto operations cross native ffi" crypto_operations_cross_native_ffi;
    case "native secret cache protocol" native_secret_cache_protocol;
    case "malformed responses and native failure"
      malformed_responses_and_native_failure;
  ]
