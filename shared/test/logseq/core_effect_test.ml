open Test_util

module J = Yojson.Basic
module U = Yojson.Basic.Util

let execute session kind fields =
  Rpc_session.call session (J.to_string (`Assoc [
    "apiVersion", `Int 1; "method", `String "dispatch";
    "params", `Assoc ["action", `String "executeEffect";
      "payload", `String (J.to_string (`Assoc (("kind", `String kind) :: fields)))]]))
  |> J.from_string

let success response = check_eq (U.member "ok" response) (`Bool true)
let blocks session = Cache_model.all_blocks (Rpc_session.state session).model
let session () = Rpc_session.create_session Rpc_session.default_options

let capture_and_task_persist_real_blocks () =
  let session = session () in
  success (execute session "send-capture" ["text", `String "A shared capture"]);
  let capture = List.find (fun (b : Cache_model.block) -> b.title = "A shared capture") (blocks session) in
  check_eq capture.title "A shared capture";
  check (capture.uuid <> "");
  check (capture.created_at > 0);
  success (execute session "send-task" ["text", `String "Follow up";
    "metadata", `String {|{"uuid":"todo","ident":"logseq.property/status.todo","title":"Todo"}|}]);
  let task = List.find (fun (b : Cache_model.block) -> b.title = "Follow up") (blocks session) in
  check_eq (Option.map (fun (s : Cache_model.status) -> s.ident) task.status)
    (Some (Some "logseq.property/status.todo"));
  check (task.uuid <> capture.uuid)

let search_and_outliner_use_the_live_session () =
  let session = session () in
  success (execute session "send-capture" ["text", `String "Find this capture"]);
  let capture = List.find (fun (b : Cache_model.block) -> b.title = "Find this capture") (blocks session) in
  let found = execute session "search-nodes" ["text", `String "Find"] in
  success found;
  check_eq (Rpc_session.state session).search_query "Find";
  success (execute session "tap-outliner-block" ["text", `String capture.uuid]);
  let state = (Rpc_session.state session).outliner_state in
  check_eq (Option.map (fun (edit : Outliner_state.editor_draft) -> edit.uuid) state.editing)
    (Some capture.uuid)

let invalid_effects_do_not_mutate_the_graph () =
  let session = session () in
  List.iter (fun (kind, fields) ->
    let response = execute session kind fields in
    check_eq (U.member "ok" response) (`Bool false);
    check_eq (blocks session) []) [
    "unknown-effect", [];
    "send-task", ["text", `String "Missing status"];
    "send-task", ["text", `String "Bad status"; "metadata", `String "not JSON"];
    "change-outliner-text", ["text", `String "Missing block and caret"];
    "drop-outliner-blocks", ["text", `String "Missing placement"];
    "send-capture", ["text", `Int 4]]

let asset_transcript_is_created_by_the_core () =
  let session = session () in
  let payload = {|{"uuid":"asset-id","title":"recording.m4a","assetType":"m4a","assetSize":12,"assetChecksum":"abc","localPath":"Assets/recording.m4a","transcript":"Spoken note","transcriptUUID":"transcript-id"}|} in
  success (execute session "send-asset" ["text", `String payload]);
  let all = blocks session in
  let child = List.find_opt (fun (b : Cache_model.block) -> b.uuid = "transcript-id") all in
  check (child <> None);
  let child = Option.get child in
  check_eq child.title "Spoken note";
  check_eq child.parent_id (Some "asset-id");
  success (execute session "send-asset" ["text", `String payload]);
  check_eq (List.length (blocks session)) (List.length all)

let malformed_transcript_is_rejected_before_asset_creation () =
  let session = session () in
  let response = execute session "send-asset" ["text", `String
    {|{"uuid":"asset-id","title":"recording.m4a","assetType":"m4a","assetSize":12,"assetChecksum":"abc","localPath":"Assets/recording.m4a","transcript":"Spoken note"}|}] in
  check_eq (U.member "ok" response) (`Bool false);
  check_eq (blocks session) []

let cases = [
  case "capture and task effects persist real blocks" capture_and_task_persist_real_blocks;
  case "search and outliner effects use the live session" search_and_outliner_use_the_live_session;
  case "invalid effects do not mutate the graph" invalid_effects_do_not_mutate_the_graph;
  case "asset transcript is created by the core" asset_transcript_is_created_by_the_core;
  case "malformed transcript is rejected before asset creation" malformed_transcript_is_rejected_before_asset_creation;
]
