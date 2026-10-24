open Test_util
module J = Yojson.Basic
module Ds = Datascript
module Q = Query_block_test
module R = Result_view_test
let member = Q.member
let result response = check_eq ~msg:(J.to_string response) (member "ok" response) (`Bool true); member "result" response

let graph_catalog_network_is_prepared_without_sending () =
  let sent = ref false in
  let session = Rpc_session.create_session { Rpc_session.default_options with
    send = (fun _ -> sent := true; Error "The UI must not wait for the network") } in
  ignore (result (Rpc_test.dispatch_json session "configure"
    {|{"baseUrl":"https://example.com","token":"test-token","graphId":""}|}));
  let prepared = result (Rpc_test.dispatch_json session "prepareGraphCatalog" "{}") in
  check (not !sent);
  check_eq (member "url" (member "request" prepared)) (`String "https://example.com/graphs");
  let completed = result (Rpc_test.dispatch_json session "completeGraphCatalog" (J.to_string (`Assoc [
    "baseUrl", `String "https://example.com"; "token", `String "test-token";
    "status", `Int 200; "body", `String {|{"graphs":[{"graph-id":"remote","graph-name":"Remote","graph-ready-for-use?":true}]}|} ]))) in
  check (not !sent);
  check_eq (List.length (Q.items "graphs" completed)) 1;
  ignore (result (Rpc_test.dispatch_json session "configure"
    {|{"baseUrl":"https://other.test","token":"new-token","graphId":""}|}));
  let stale = Rpc_test.dispatch_json session "completeGraphCatalog" (J.to_string (`Assoc [
    "baseUrl", `String "https://example.com"; "token", `String "test-token";
    "status", `Int 200; "body", `String "[]"])) in
  check_eq ~msg:"A late response cannot replace a different account's graph catalog" (member "ok" stale) (`Bool false)

let cases = [case "catalog responsiveness" graph_catalog_network_is_prepared_without_sending]
