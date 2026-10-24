open Test_util
module J = Yojson.Basic
module Ds = Datascript
module Q = Query_block_test
module R = Result_view_test
let member = Q.member
let result response = check_eq ~msg:(J.to_string response) (member "ok" response) (`Bool true); member "result" response

let comments_have_distinct_presentation () =
  let db = match Graph_bootstrap.database "discussion" false (fun x -> Ok x) with Ok db -> db | Error e -> fail e in
  let uuid n = Printf.sprintf "10000000-0000-4000-8000-%012d" n in
  let add n attr value = Ds.Add (Ds.Lookup_ref ("block/uuid", Ds.Uuid (uuid n)), attr, value) in
  let db = Ds.db_with [
    Ds.Add (Ds.Entity_id 9001, "block/uuid", Ds.Uuid (uuid 1));
    Ds.Add (Ds.Entity_id 9002, "block/uuid", Ds.Uuid (uuid 2));
    add 1 "block/title" (Ds.String "Discussion");
    add 1 "block/tags" (Ds.Ref_to (Ds.Ident "logseq.class/Comments"));
    add 2 "block/title" (Ds.String "A comment");
    add 2 "block/parent" (Ds.Ref_to (Ds.Lookup_ref ("block/uuid", Ds.Uuid (uuid 1))));
  ] db in
  let decorate uuid = Node_presentation.decorate db uuid (`Assoc []) in
  check_eq (member "discussionKind" (decorate (uuid 1))) (`String "thread");
  check_eq (member "discussionKind" (decorate (uuid 2))) (`String "comment")

let cases = [case "discussion presentation" comments_have_distinct_presentation]
