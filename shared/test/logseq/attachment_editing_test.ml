open Test_util
module State = Outliner_state
module Cache = Cache_model
module Ds = Datascript
module U = Yojson.Basic.Util

let attachment_presenters_commit_and_release_the_editor () =
  let context = Outliner_state_test.context_for [Outliner_state_test.block "a" ""] in
  List.iter (fun toolbar ->
    let current = Outliner_state_test.start context "a" "Draft before photo" 18 in
    let next, commands = State.update context current (State.Toolbar toolbar) in
    check ~msg:"The editor must finish before a native attachment presenter opens" (next.editing = None);
    match commands with
    | State.Commit_title value :: _ -> check_eq value.Pending_ops.title "Draft before photo"
    | _ -> fail "The draft must be saved before requesting the camera or file picker"
  ) [State.Camera; State.Attachment; State.Audio]

let image_import_reuses_an_empty_target_without_a_blank_parent () =
  let session = Rpc_session.create_session Rpc_session.default_options in
  let cache = (Rpc_session.state session).Session_types.model in
  Cache.upsert_blocks cache [Cache.local_block "empty" "" "page" (Some "parent") 10] 10;
  let payload = {|{"uuid":"photo","title":"Photo.png","assetType":"png","assetSize":42,"assetChecksum":"abc","localPath":"Assets/photo.png","targetBlockId":"empty","now":20}|} in
  List.iter (fun _ ->
    let response = Rpc_test.dispatch_json session "addAsset" payload in
    check_eq ~msg:(Yojson.Basic.to_string response) (U.member "ok" response) (`Bool true);
    let target = Option.get (Cache.read_block cache "empty") in
    check ~msg:"An empty insertion target becomes the image itself" target.is_asset;
    check_eq target.parent_id (Some "parent");
    check ~msg:"Retrying an import does not duplicate or self-parent the image" (Cache.read_block cache "photo" = None)
  ) [1;2]

let empty_image_target_is_projected_without_losing_its_identity () =
  let module P = Pending_projection_test in
  let db = P.with_tx (P.base_db ()) [
    P.add 20 "block/uuid" (Ds.Uuid "empty");
    P.add 20 "block/title" (Ds.String "");
    P.add 20 "block/page" (Ds.Ref 1);
    P.add 20 "block/parent" (Ds.Ref 1);
    P.add 20 "block/order" (Ds.String "a1");
    P.add 20 "user.property/label" (Ds.String "Keep this property") ] in
  let intent = Pending_ops.Create_asset {
    uuid = "empty"; title = "Photo.png"; page_uuid = "page"; parent_uuid = "page";
    order = "a1"; created_at = 20; asset_type = "png"; asset_size = 42;
    asset_checksum = "checksum"; transcript = None } in
  let projected = P.apply_intent db intent in
  check_eq (Ds.entid projected "block/uuid" (Ds.Uuid "empty")) (Some 20);
  check_eq (P.value projected "empty" "block/parent") (Some (Ds.Ref 1));
  check_eq (P.value projected "empty" "user.property/label") (Some (Ds.String "Keep this property"));
  check (Pending_projection.satisfied projected intent);
  List.iter (fun tx ->
    check ~msg:"Import must preserve pages, deleted blocks and nonempty targets"
      (Result.is_error (Pending_projection.compile (P.with_tx db tx) intent))) [
    [P.add 20 "block/name" (Ds.String "named page")];
    [P.add 20 "block/title" (Ds.String "Existing content")];
    [P.add 20 "logseq.property/deleted-at" (Ds.Int64 30L)];
    [P.add 21 "block/uuid" (Ds.Uuid "child"); P.add 21 "block/parent" (Ds.Ref 20)] ]

let importing_twice_keeps_one_asset_in_the_live_projection () =
  Result_view_test.with_runtime (fun session runtime conn ->
    let uuid = "f1000000-0000-4000-8000-000000000001" in
    let module Q = Query_block_test in
    Editor_command_test.rebase runtime conn [
      Datascript.Add (Datascript.Entity_id 990000, "block/uuid", Datascript.Uuid uuid);
      Q.put uuid "block/title" (Datascript.String "");
      Q.put uuid "block/page" (Datascript.Ref_to (Q.ref_uuid Q.page));
      Q.put uuid "block/parent" (Datascript.Ref_to (Q.ref_uuid Q.page));
      Q.put uuid "block/order" (Datascript.String "a9") ];
    let payload = Yojson.Basic.to_string (`Assoc [
      "uuid", `String "f1000000-0000-4000-8000-000000000002";
      "title", `String "Photo.png"; "assetType", `String "png"; "assetSize", `Int 42;
      "assetChecksum", `String "checksum"; "localPath", `String "Assets/photo.png";
      "targetBlockId", `String uuid; "now", `Int 100 ]) in
    List.iter (fun _ ->
      let response = Rpc_test.dispatch_json session "addAsset" payload in
      check_eq ~msg:(Yojson.Basic.to_string response) (U.member "ok" response) (`Bool true);
      let db = Graph_runtime.db runtime in
      let eid = Option.get (Ds.entid db "block/uuid" (Ds.Uuid uuid)) in
      check_eq (Graph_read.value db eid "logseq.property.asset/type") (Some (Ds.String "png"));
      check_eq (Ds.entid db "block/uuid" (Ds.Uuid "f1000000-0000-4000-8000-000000000002")) None
    ) [1;2])

let cases = [
  case "retrying image import keeps one live asset" importing_twice_keeps_one_asset_in_the_live_projection;
  case "empty image target projection preserves existing identity" empty_image_target_is_projected_without_losing_its_identity;
  case "attachment presenters commit and release the editor" attachment_presenters_commit_and_release_the_editor;
  case "image import reuses an empty target without a blank parent" image_import_reuses_an_empty_target_without_a_blank_parent;
]
