open Test_util
module J = Yojson.Basic
module Ds = Datascript
module Q = Query_block_test
module R = Result_view_test
let member = Q.member
let result response = check_eq ~msg:(J.to_string response) (member "ok" response) (`Bool true); member "result" response

let code_language_can_be_changed_and_cleared () = R.with_runtime (fun session runtime conn ->
  Editor_command_test.rebase runtime conn [Q.put Q.alpha "logseq.property.node/display-type" (Ds.Keyword "code")];
  List.iter (fun language ->
    ignore (result (Rpc_test.dispatch_json session "nodeProperty" (J.to_string (`Assoc [
      "action", `String "setCodeLanguage"; "blockUuid", `String Q.alpha; "value", `String language]))));
    let id = Option.get (Ds.entid (Graph_runtime.db runtime) "block/uuid" (Ds.Uuid Q.alpha)) in
    check_eq (Graph_read.value (Graph_runtime.db runtime) id "logseq.property.code/lang")
      (if language = "" then None else Some (Ds.String language))
  ) ["python"; "ocaml"; ""];
  check_eq (member "ok" (Rpc_test.dispatch_json session "nodeProperty" (J.to_string (`Assoc [
    "action", `String "setCodeLanguage"; "blockUuid", `String Q.beta; "value", `String "python"])))) (`Bool false))

let cases = [case "code language" code_language_can_be_changed_and_cleared]
