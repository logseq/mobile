open Test_util
open Rpc_test

let leaving_editor_trims_block_edges () =
  let exits = [
    {|{"type":"toolbar","action":"hideKeyboard"}|};
    {|{"type":"cancelEditing"}|};
    {|{"type":"tapBlock","uuid":"other"}|};
    {|{"type":"longPressBlock","uuid":"other"}|};
    {|{"type":"toggleCollapsed","uuid":"editing"}|};
    {|{"type":"zoomIn","uuid":"editing"}|};
    {|{"type":"zoomOut"}|};
    {|{"type":"returnPressed"}|}
  ] in
  List.iter (fun event ->
    List.iter (fun (initial, draft, expected) ->
      Result_view_test.with_runtime (fun session runtime _ ->
        let uuid = Query_block_test.alpha in
        let rename = {Pending_ops.operation_id = Graph_runtime.fresh_uuid (); base_t = 42;
          state = Pending_ops.Queued; intent = Pending_ops.Save_title {uuid;
            expected_title = Option.value ~default:"" (Option.bind
              (Editor_command_test.value runtime uuid "block/title")
              (function Datascript.String value -> Some value | _ -> None)); title = initial}} in
        check_ok (Graph_runtime.stage runtime rename);
        ignore (outliner_block_event session "tapBlock" uuid);
        ignore (outliner_event session (Json.to_string (`Assoc ["type", `String "textChanged";
          "title", `String draft; "caretUTF16Offset", `Int (String.length draft)])));
        let payload = Json.from_string event |> function
          | `Assoc fields -> `Assoc (List.map (function
              | "uuid", `String "editing" -> "uuid", `String uuid
              | "uuid", `String "other" -> "uuid", `String Query_block_test.beta
              | field -> field) fields)
          | _ -> assert false in
        let response = dispatch_json session "outlinerEvent" (Json.to_string payload) in
        check_eq ~msg:("Exit succeeds: " ^ event) (member "ok" response) (`Bool true);
        check_eq ~msg:("Leaving editing trims only the block edges: " ^ event)
          (Editor_command_test.value runtime uuid "block/title") (Some (Datascript.String expected))))
      ["Original", " \tHello\n  child\nworld \n", "Hello\n  child\nworld";
       "Original", " \t\n ", "";
       " Original ", " Original ", "Original";
       "Original", "Original", "Original"]) exits

let autosave_preserves_spaces_until_editor_is_left () =
  Result_view_test.with_runtime (fun session runtime _ ->
    let uuid = Query_block_test.alpha in
    ignore (outliner_block_event session "tapBlock" uuid);
    ignore (outliner_event session {|{"type":"textChanged","title":"  Hello  ","caretUTF16Offset":9}|});
    ignore (outliner_event session {|{"type":"saveEditing"}|});
    check_eq ~msg:"Autosave must preserve spaces while typing"
      (Editor_command_test.value runtime uuid "block/title") (Some (Datascript.String "  Hello  "));
    check_eq (Outliner.editing_title (Types.state session).outliner_state) (Some "  Hello  ");
    ignore (outliner_event session {|{"type":"cancelEditing"}|});
    check_eq ~msg:"An already autosaved draft is still trimmed on exit"
      (Editor_command_test.value runtime uuid "block/title") (Some (Datascript.String "Hello")))

let failed_trim_save_retains_the_live_draft () =
  let live = synced_block "editing" "Original" in
  let session = configure_plain_session (Session.create_session {Session.default_options with
    load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
    sync_cursor = Some (fun () -> Some 92); graph_blocks = Some (fun () -> Some [live]);
    prepare_operation = Some prepare_operation;
    stage_operation = Some (fun _ -> Error "Local save failed")}) in
  ignore (outliner_block_event session "tapBlock" "editing");
  ignore (outliner_event session {|{"type":"textChanged","title":"  Keep draft  ","caretUTF16Offset":14}|});
  let response = dispatch_json session "outlinerEvent" {|{"type":"cancelEditing"}|} in
  check_eq (member "ok" response) (`Bool false);
  check_eq ~msg:"A failed trim save keeps the original draft available for retry"
    (Outliner.editing_title (Types.state session).outliner_state) (Some "  Keep draft  ")

let cases = [
  case "leaving editor trims block edges" leaving_editor_trims_block_edges;
  case "autosave preserves spaces until editor is left" autosave_preserves_spaces_until_editor_is_left;
  case "failed trim save retains the live draft" failed_trim_save_retains_the_live_draft;
]
