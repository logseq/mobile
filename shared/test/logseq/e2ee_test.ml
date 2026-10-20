open Test_util

module Value = Transit_core.Json
module Codec = Transit_native.Transit.Json

let expect_ok result =
  match result with
  | Ok value -> value
  | Error message -> failwith message

let private_key_package version =
  Codec.to_string
    (Value.Array
       (List.concat
          [
            (match version with
             | Some version -> [ Value.String version ]
             | None -> []);
            [
              Value.Binary "salt";
              Value.Binary "private-iv";
              Value.Binary "encrypted-private-key";
            ];
          ]))

let encrypted_graph_key = Codec.to_string (Value.Binary "encrypted-graph-key")

let status_value = Value.Keyword "logseq.property/status.todo"

let crypto calls : E2ee.e2ee_crypto =
  {
    generate_rsa_key_pair = (fun () -> Error "unused");
    encrypt_private_key = (fun _ _ -> Error "unused");
    decrypt_private_key =
      (fun password iterations salt iv ciphertext ->
         calls := !calls @ [
           "private:" ^ password ^ ":" ^ string_of_int iterations ^ ":"
           ^ salt ^ ":" ^ iv ^ ":" ^ ciphertext ];
         Ok "private-key");
    decrypt_graph_key =
      (fun private_key ciphertext ->
         calls := !calls @ [ "graph:" ^ private_key ^ ":" ^ ciphertext ];
         Ok "graph-key");
    encrypt_graph_key =
      (fun public_key plaintext ->
         calls := !calls @ [ "wrap:" ^ public_key ^ ":" ^ plaintext ];
         Ok "encrypted-graph-key");
    random_bytes = (fun size -> Ok (String.make size 'k'));
    encrypt_aes_gcm =
      (fun key plaintext ->
         calls := !calls @ [ "seal:" ^ key ^ ":" ^ plaintext ];
         Ok ("value-iv", "encrypted-value"));
    decrypt_aes_gcm =
      (fun key iv ciphertext ->
         calls := !calls @ [ "open:" ^ key ^ ":" ^ iv ^ ":" ^ ciphertext ];
         Ok (Codec.to_string status_value));
  }

let current_and_legacy_private_key_iterations () =
  List.iter
    (fun (version, iterations) ->
       let calls = ref [] in
       let key =
         expect_ok
           (E2ee.unlock_graph_key (crypto calls) "e2etest"
              (private_key_package version) encrypted_graph_key)
       in
       check_eq "graph-key" key;
       check_eq
         [
           "private:e2etest:" ^ string_of_int iterations
           ^ ":salt:private-iv:encrypted-private-key";
           "graph:private-key:encrypted-graph-key";
         ]
         !calls)
    [ (Some "20251210", 600000); (None, 100000) ];
  check_eq 100000
    (expect_ok (E2ee.private_key_package (private_key_package (Some "20251209"))))
      .iterations

let protected_values_round_trip_with_their_transit_types () =
  let calls = ref [] in
  let crypto = crypto calls in
  let encrypted =
    expect_ok (E2ee.encrypt_value crypto "graph-key" status_value)
  in
  check_eq
    (Value.Array [ Value.Binary "value-iv"; Value.Binary "encrypted-value" ])
    (Codec.of_string encrypted);
  check_eq status_value
    (expect_ok (E2ee.decrypt_value crypto "graph-key" encrypted))

let graph_key_preparation_uses_transit_binary_envelopes () =
  let calls = ref [] in
  let key, encrypted =
    expect_ok
      (E2ee.prepare_graph_key (crypto calls)
         (Codec.to_string (Value.Binary "public-key")))
  in
  let expected = String.make 32 'k' in
  check_eq expected key;
  check_eq (Value.Binary "encrypted-graph-key") (Codec.of_string encrypted);
  check (List.exists (( = ) ("wrap:public-key:" ^ expected)) !calls)

let invalid_envelopes_fail_closed () =
  let calls = ref [] in
  let crypto = crypto calls in
  List.iter
    (fun values ->
       check_eq
         (Error "encrypted value has an invalid Transit AES-GCM envelope")
         (E2ee.decrypt_value crypto "graph-key"
            (Codec.to_string (Value.Array values))))
    [
      [ Value.String "iv"; Value.String "ciphertext" ];
      [ Value.Binary "iv"; Value.Binary "cipher"; Value.Int 1 ];
      [ Value.String "iv"; Value.Binary "cipher" ];
    ];
  check_eq [] !calls

let plaintext_and_nested_strings_do_not_invoke_crypto () =
  let calls = ref [] in
  let crypto = crypto calls in
  let nested =
    Codec.to_string (Value.String (Codec.to_string (Value.String "nested")))
  in
  check_eq (Ok "Card") (E2ee.decrypt_string crypto "graph-key" "Card");
  check_eq (Ok "Card")
    (E2ee.decrypt_string crypto "graph-key"
       (Codec.to_string (Value.String "Card")));
  check_eq (Ok "nested") (E2ee.decrypt_string crypto "g" nested);
  check_eq (Error "decrypted protected value is not a string")
    (E2ee.decrypt_string crypto "g" (Codec.to_string (Value.Int 1)));
  check_eq [] !calls

let crypto_errors_short_circuit_subsequent_operations () =
  let calls = ref [] in
  let base = crypto calls in
  let failed_private =
    { base with
      E2ee.decrypt_private_key =
        (fun _ _ _ _ _ -> Error "private failure");
    }
  in
  let failed_random =
    { base with E2ee.random_bytes = (fun _ -> Error "random failure") }
  in
  let bad_aes =
    { base with
      E2ee.decrypt_aes_gcm =
        (fun _ _ _ -> Error "authentication failure");
    }
  in
  check_eq (Error "private failure")
    (E2ee.unlock_graph_key failed_private "p" (private_key_package None)
       encrypted_graph_key);
  check_eq [] !calls;
  check_eq (Error "random failure")
    (E2ee.prepare_graph_key failed_random
       (Codec.to_string (Value.Binary "public")));
  check_eq [] !calls;
  check_eq (Error "encrypted graph key is not Transit binary")
    (E2ee.prepare_graph_key base (Codec.to_string (Value.String "not binary")));
  check_eq [] !calls;
  check_eq (Error "authentication failure")
    (E2ee.decrypt_value bad_aes "g"
       (Codec.to_string
          (Value.Array [ Value.Binary "iv"; Value.Binary "cipher" ])));
  check_eq [] !calls

let cases =
  [
    case "current and legacy private key iterations"
      current_and_legacy_private_key_iterations;
    case "protected values round trip with their transit types"
      protected_values_round_trip_with_their_transit_types;
    case "graph key preparation uses transit binary envelopes"
      graph_key_preparation_uses_transit_binary_envelopes;
    case "invalid envelopes fail closed" invalid_envelopes_fail_closed;
    case "plaintext and nested strings do not invoke crypto"
      plaintext_and_nested_strings_do_not_invoke_crypto;
    case "crypto errors short circuit subsequent operations"
      crypto_errors_short_circuit_subsequent_operations;
  ]
