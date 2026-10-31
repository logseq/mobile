open Test_util
module Ds = Datascript
module J = Yojson.Basic
module U = Yojson.Basic.Util
module Q = Query_block_test
module R = Result_view_test
let asset = "a9000000-0000-4000-8000-000000000001"
let other_asset = "a9000000-0000-4000-8000-000000000002"
let highlight_id = "a9000000-0000-4000-8000-000000000003"
let rect = `Assoc ["x1", `Int 20; "y1", `Int 30; "x2", `Int 180; "y2", `Int 50;
  "width", `Int 600; "height", `Int 800]
let highlight ?(id = highlight_id) ?(page = 1) ?(color = "yellow") ?(text = "Selected 原文") () =
  `Assoc ["id", `String id; "page", `Int page;
    "content", `Assoc ["text", `String text];
    "position", `Assoc ["page", `Int page; "bounding", rect; "rects", `List [rect]];
    "properties", `Assoc ["color", `String color]]
let call session action fields = Rpc_test.dispatch_json session "pdfAnnotation"
  (J.to_string (`Assoc (["action", `String action; "assetUuid", `String asset;
    "graphId", `String "plain-1"] @ fields)))
let result response =
  check_eq ~msg:(J.to_string response) (U.member "ok" response) (`Bool true);
  U.member "pdfWorkspace" (U.member "result" response)
let rec canonical = function
  | `Assoc fields -> `Assoc (List.sort compare (List.map (fun (key, value) -> key, canonical value) fields))
  | `List values -> `List (List.map canonical values)
  | value -> value
let annotations response = List.map canonical (Q.items "highlights" (result response))
let with_pdf f = R.with_runtime (fun session runtime conn ->
  let entity n uuid = [Ds.Add (Ds.Entity_id n, "block/uuid", Ds.Uuid uuid);
    Q.put uuid "block/title" (Ds.String "Research.pdf");
    Q.put uuid "block/parent" (Ds.Ref_to (Q.ref_uuid Q.page));
    Q.put uuid "block/page" (Ds.Ref_to (Q.ref_uuid Q.page));
    Q.put uuid "block/order" (Ds.String "a9");
    Q.put uuid "block/tags" (Ds.Ref_to (Ds.Ident "logseq.class/Asset"));
    Q.put uuid "logseq.property.asset/type" (Ds.String "pdf")] in
  Editor_command_test.rebase runtime conn (entity 960001 asset @ entity 960002 other_asset);
  f session runtime conn)
let save session value = call session "save" ["highlight", value]

let canonical_blocks_and_colors () = with_pdf (fun session runtime _ ->
  check_eq (annotations (call session "load" [])) [];
  List.iteri (fun i color ->
    let id = Printf.sprintf "a9000000-0000-4000-8000-%012d" (i + 10) in
    let saved = highlight ~id ~color () in
    ignore (result (save session saved));
    let db = Graph_runtime.db runtime in
    let eid = Option.get (Ds.entid db "block/uuid" (Ds.Uuid id)) in
    check_eq (Graph_read.value db eid "block/title") (Some (Ds.String "Selected 原文"));
    check_eq (Graph_read.value db eid "logseq.property/ls-type") (Some (Ds.Keyword "annotation"));
    check_eq (Graph_read.value db eid "logseq.property.pdf/hl-page") (Some (Ds.Int64 1L));
    check (Graph_read.entity_is_instance_of db eid "logseq.class/Pdf-annotation");
    let asset_eid = Option.get (Ds.entid db "block/uuid" (Ds.Uuid asset)) in
    check_eq (Graph_read.value db eid "block/parent") (Some (Ds.Ref asset_eid));
    check_eq (Graph_read.value db eid "logseq.property/asset") (Some (Ds.Ref asset_eid));
    let color_eid = Option.get (Ds.entid db "db/ident" (Ds.Keyword ("logseq.property/color." ^ color))) in
    check_eq (Graph_read.value db eid "logseq.property.pdf/hl-color") (Some (Ds.Ref color_eid));
    let actual = List.find (fun value -> U.member "id" value = `String id)
      (annotations (call session "load" [])) in
    check_eq actual (canonical saved)
  ) ["yellow"; "red"; "green"; "blue"; "purple"])

let survives_restart_and_pending_sync () = with_pdf (fun session runtime conn ->
  ignore (result (save session (highlight ())));
  let pending = Graph_runtime.pending_operations runtime in
  check_eq (List.length pending) 1;
  let operation = List.hd pending in
  check (Pending_projection.satisfied (Graph_runtime.db runtime) operation.Pending_ops.intent);
  check_eq (Pending_ops.intent_of_json (Pending_ops.intent_json operation.intent)) operation.intent;
  let _, tx = match Graph_runtime.prepare_sync runtime operation with
    | Ok value -> value | Error message -> fail message in
  check ~msg:"Annotation geometry must be in the normal sync transaction" (String.length tx > 100);
  let restored = Graph_runtime.create runtime.path 42 conn {Graph_runtime.default_options with auto_create_today = false} in
  let restored_session, _ = R.make_session ~configured:true (Graph_runtime.db restored) in
  check_eq (annotations (call restored_session "load" [])) [canonical (highlight ())])

let recolor_and_delete_preserve_notes () = with_pdf (fun session runtime _ ->
  ignore (result (save session (highlight ())));
  let note = "a9000000-0000-4000-8000-000000000004" in
  check_ok (Graph_runtime.stage runtime {Pending_ops.operation_id = "annotation-note"; base_t = 42;
    state = Pending_ops.Queued; intent = Pending_ops.Insert_block {uuid = note;
      title = "My annotation note"; page_uuid = Q.page; parent_uuid = highlight_id;
      order = "a0"; created_at = 100}});
  let recolored = highlight ~color:"purple" () in
  check_eq (annotations (save session recolored)) [canonical recolored];
  check_eq (Editor_command_test.value runtime note "block/title") (Some (Ds.String "My annotation note"));
  check_eq (annotations (call session "delete" ["id", `String highlight_id])) [];
  check_eq (annotations (call session "delete" ["id", `String highlight_id])) [])

let retries_do_not_duplicate_annotations () = with_pdf (fun session runtime _ ->
  List.iter (fun _ -> check_eq (annotations (save session (highlight ()))) [canonical (highlight ())]) [1;2;3];
  check_eq (List.length (Graph_runtime.pending_operations runtime)) 1)

let invalid_input_never_stages_operations () = with_pdf (fun session runtime _ ->
  let bad_rect = `Assoc ["x1", `Int 180; "y1", `Int 30; "x2", `Int 20; "y2", `Int 50;
    "width", `Int 600; "height", `Int 800] in
  let bad_geometry = match highlight () with `Assoc fields -> `Assoc
    (("position", `Assoc ["page", `Int 1; "bounding", bad_rect; "rects", `List [bad_rect]])
      :: List.remove_assoc "position" fields) | _ -> assert false in
  List.iter (fun value ->
    let response = save session value in
    check_eq (U.member "ok" response) (`Bool false);
    check_eq (U.member "code" (U.member "error" response)) (`String "invalid_pdf_annotation");
    check_eq (Graph_runtime.pending_operations runtime) [])
    [highlight ~page:0 (); highlight ~color:"unknown" (); highlight ~text:" " ();
     highlight ~id:Q.alpha (); bad_geometry; highlight ~id:"------------------------------------" ()])

let cross_asset_and_stale_graph_are_rejected () = with_pdf (fun session runtime _ ->
  ignore (result (save session (highlight ())));
  let original = Graph_runtime.pending_operations runtime in
  List.iter (fun fields ->
    let response = Rpc_test.dispatch_json session "pdfAnnotation" (J.to_string (`Assoc fields)) in
    check_eq (U.member "ok" response) (`Bool false);
    check_eq (Graph_runtime.pending_operations runtime) original)
    [["action", `String "delete"; "graphId", `String "plain-1"; "assetUuid", `String other_asset; "id", `String highlight_id];
     ["action", `String "save"; "graphId", `String "other-graph"; "assetUuid", `String asset; "highlight", highlight ()];
     ["action", `String "load"; "graphId", `String "plain-1"; "assetUuid", `String Q.alpha]])

let last_page_is_saved_on_the_asset () = with_pdf (fun session runtime _ ->
  let response = result (call session "visit" ["page", `Int 7]) in
  check_eq (U.member "page" response) (`Int 7);
  check_eq (Editor_command_test.value runtime asset "logseq.property.asset/last-visit-page") (Some (Ds.Int64 7L));
  check_eq (U.member "page" (result (call session "load" []))) (`Int 7))

let selected_text_uses_desktop_line_break_rules () = with_pdf (fun session runtime _ ->
  List.iteri (fun index (source, expected) ->
    let id = Printf.sprintf "a9000000-0000-4000-8000-%012d" (index + 30) in
    let saved = annotations (save session (highlight ~id ~text:source ())) in
    let value = List.find (fun value -> U.member "id" value = `String id) saved in
    check_eq (U.member "text" (U.member "content" value)) (`String expected);
    check_eq (Editor_command_test.value runtime id "block/title") (Some (Ds.String expected))
  ) ["中文\n换行", "中文换行"; "A line\nwrap", "A line wrap";
     "hy-\r\nphenated", "hyphenated"; "第 1\n8 页", "第 18 页"])

let desktop_area_annotations_keep_their_original_data () = with_pdf (fun session runtime _ ->
  ignore (result (save session (highlight ())));
  let original = Option.get (Editor_command_test.value runtime highlight_id "logseq.property.pdf/hl-value") in
  let replace key value fields = (Ds.Keyword key, value) :: List.filter (fun (name, _) -> name <> Ds.Keyword key) fields in
  let area = match original with
    | Ds.Map fields ->
      let position = match List.assoc (Ds.Keyword "position") fields with
        | Ds.Map fields -> Ds.Map (replace "rects" (Ds.Vector []) fields) | _ -> assert false in
      Ds.Map (replace "position" position (replace "content"
        (Ds.Map [Ds.Keyword "image", Ds.Uuid "a9000000-0000-4000-8000-000000000099"]) fields))
    | _ -> assert false in
  let semantic value = match Pending_ops.semantic_value_from_datascript value with Ok value -> value | Error message -> fail message in
  check_ok (Graph_runtime.stage runtime {Pending_ops.operation_id = "desktop-area"; base_t = 42;
    state = Pending_ops.Queued; intent = Pending_ops.Set_properties {uuid = highlight_id; changes =
      [{attr = "logseq.property.pdf/hl-value"; expected = Some (semantic original); value = Some (semantic area)};
       {attr = "logseq.property.pdf/hl-type"; expected = None; value = Some (Pending_ops.Keyword_value "area")}]}});
  let changed = annotations (call session "recolor" ["id", `String highlight_id; "color", `String "blue"]) in
  check_eq (U.member "color" (U.member "properties" (List.hd changed))) (`String "blue");
  check_eq (U.member "image" (U.member "content" (List.hd changed))) (`String "a9000000-0000-4000-8000-000000000099");
  check ~msg:"Recoloring must preserve the original annotation data"
    (Pending_projection.semantic_value_equal (Graph_runtime.db runtime)
      (Editor_command_test.value runtime highlight_id "logseq.property.pdf/hl-value") (Some (semantic area))))

let workspace_host_update_is_supported () =
  check ~msg:"Opening a PDF must reach the shared workspace instead of Quick Look"
    (Result.is_ok (Host_update.decode "open-pdf"
      {|{"uuid":"a9000000-0000-4000-8000-000000000001","title":"Research.pdf","path":"/tmp/Research.pdf"}|}))

let workspace_preserves_main_and_rejects_late_events () =
  let initial = { (Model.initial ()) with Model.selected_graph_id = Some "plain-1";
    sidebar_open = true; app_navigation_path = [Model.NodeRoute Q.page]; composer_draft = "Keep this draft" } in
  let opened = Model.update initial (Model.OpenPdf (asset, "Research.pdf", "/tmp/Research.pdf")) in
  check (not opened.sidebar_open);
  check_eq opened.app_navigation_path initial.app_navigation_path;
  check_eq opened.composer_draft initial.composer_draft;
  let stale = Model.update opened (Model.PdfWorkspaceEvent (J.to_string (`Assoc
    ["action", `String "delete"; "assetUuid", `String other_asset; "graphId", `String "plain-1";
     "id", `String highlight_id]))) in
  check_eq ~msg:"An outgoing PDF view must never mutate a newly opened PDF" stale.pending_effects opened.pending_effects

let shared_asset_actions_open_local_and_remote_pdfs () =
  List.iter (fun path ->
    let block = ["uuid", `String asset; "title", `String "Research.pdf";
      "pageId", `String Q.page; "isAsset", `Bool true; "assetType", `String "pdf"]
      @ (match path with Some path -> ["localPath", `String path] | None -> []) in
    let response = J.to_string (`Assoc ["ok", `Bool true; "result", `Assoc
      ["selectedGraphId", `String "plain-1"; "outlinerRows", `List
        [`Assoc ["block", `Assoc block; "depth", `Int 0]]]]) in
    let projection = match Response_snapshot.decode_response response with
      | Ok value -> value | Error message -> fail message in
    let model = Model.update (Model.initial ()) (Model.ApplyCoreSnapshot projection) in
    let opened = Model.update model (Model.OpenOutlinerAsset asset) in
    check ~msg:"All PDF asset entry points must open the split workspace" (opened.pdf_workspace <> None);
    check ~msg:"PDFs must not open a generic native file preview"
      (not (List.exists (function Model.PresentAssetEffect _ -> true | _ -> false) opened.pending_effects))
  ) [Some "/tmp/Research.pdf"; None]

let annotation_projection_keeps_the_pdf_page_link () = with_pdf (fun session _ _ ->
  let response = save session (highlight ~page:7 ()) in
  let blocks = Q.items "outlinerRows" (U.member "result" response) in
  let block = List.find_map (fun row -> let block = U.member "block" row in
    if U.member "uuid" block = `String highlight_id then Some block else None) blocks |> Option.get in
  let link = U.member "pdfAnnotation" block in
  check_eq ~msg:"Annotation blocks need the desktop PDF page prefix" (U.member "page" link) (`Int 7);
  check_eq (U.member "assetUuid" link) (`String asset);
  check_eq (U.member "assetTitle" link) (`String "Research.pdf");
  check_eq (U.member "id" link) (`String highlight_id);
  let projection = match Response_snapshot.decode_response (J.to_string response) with
    | Ok value -> value | Error message -> fail message in
  let model = Model.update (Model.initial ()) (Model.ApplyCoreSnapshot projection) in
  let row = List.find (fun (row : Model.outline_row) -> row.row_uuid = highlight_id) model.outliner_rows in
  check_eq (U.member "pdfAnnotation" (J.from_string row.row_metadata_json)) link)

let annotation_page_links_open_without_replacing_main () =
  let initial = { (Model.initial ()) with Model.selected_graph_id = Some "plain-1";
    sidebar_open = true; app_navigation_path = [Model.NodeRoute Q.page]; composer_draft = "My note" } in
  let open_at current page = Model.update current (Model.PdfWorkspaceEvent (J.to_string (`Assoc
    ["action", `String "open-annotation"; "annotation", `Assoc ["assetUuid", `String asset;
     "assetTitle", `String "Research.pdf"; "id", `String highlight_id; "page", `Int page]]))) in
  let opened = open_at initial 7 in
  check ~msg:"Clicking P7 must open the PDF" (opened.pdf_workspace <> None);
  let fields model = J.from_string (Option.get model.Model.pdf_workspace) in
  check_eq (U.member "targetPage" (fields opened)) (`Int 7);
  check_eq (U.member "targetAnnotation" (fields opened)) (`String highlight_id);
  check_eq opened.app_navigation_path initial.app_navigation_path;
  check_eq opened.composer_draft initial.composer_draft;
  check (not opened.sidebar_open);
  let next = open_at opened 2 in
  check_eq ~msg:"A second page prefix must navigate an already open PDF" (U.member "targetPage" (fields next)) (`Int 2);
  check (U.member "navigationToken" (fields opened) <> U.member "navigationToken" (fields next));
  let response = J.to_string (`Assoc ["ok", `Bool true; "result", `Assoc ["isPdfPatch", `Bool true;
    "pdfWorkspace", `Assoc ["graphId", `String "plain-1"; "assetUuid", `String asset; "page", `Int 1; "highlights", `List []]]]) in
  let projection = match Response_snapshot.decode_response response with Ok value -> value | Error message -> fail message in
  let loaded = Model.update next (Model.ApplyCoreSnapshot projection) in
  check_eq ~msg:"The clicked page must take precedence over last-visit-page" (U.member "targetPage" (fields loaded)) (`Int 2);
  check_eq (open_at initial 0).pdf_workspace None

let fullscreen_reading_preserves_main_and_exposes_notes () =
  let initial = { (Model.initial ()) with Model.selected_graph_id = Some "plain-1";
    app_navigation_path = [Model.NodeRoute Q.page]; composer_draft = "Keep my note" } in
  let opened = Model.update initial (Model.OpenPdf (asset, "Research.pdf", "/tmp/Research.pdf")) in
  let event action fields current = Model.update current (Model.PdfWorkspaceEvent (J.to_string
    (`Assoc (["action", `String action; "assetUuid", `String asset; "graphId", `String "plain-1"] @ fields)))) in
  let fullscreen = event "set-fullscreen" ["fullScreen", `Bool true] opened in
  let full model = U.member "fullScreen" (J.from_string (Option.get model.Model.pdf_workspace)) in
  check_eq ~msg:"The full-screen reading action must be reflected in workspace state" (full fullscreen) (`Bool true);
  check_eq fullscreen.app_navigation_path initial.app_navigation_path;
  check_eq fullscreen.composer_draft initial.composer_draft;
  check_eq fullscreen.pending_effects opened.pending_effects;
  let split = event "set-fullscreen" ["fullScreen", `Bool false] fullscreen in
  check_eq (full split) (`Bool false);
  let notes = event "open-annotations" [] fullscreen in
  check_eq ~msg:"Opening notes must reveal main again" (full notes) (`Bool false);
  check_eq (event "set-fullscreen" ["fullScreen", `String "invalid"] opened).pdf_workspace opened.pdf_workspace;
  check_eq (event "set-fullscreen" ["fullScreen", `Bool true] initial).pdf_workspace None

let cases = [
  case "full-screen reading preserves main and reveals notes on request" fullscreen_reading_preserves_main_and_exposes_notes;
  case "annotation projections retain the desktop PDF page link" annotation_projection_keeps_the_pdf_page_link;
  case "annotation page links open and navigate PDFs without replacing main" annotation_page_links_open_without_replacing_main;
  case "canonical annotation blocks and five desktop colors" canonical_blocks_and_colors;
  case "annotations survive restart and use the sync queue" survives_restart_and_pending_sync;
  case "recolor preserves notes and delete is retryable" recolor_and_delete_preserve_notes;
  case "annotation retries do not duplicate data" retries_do_not_duplicate_annotations;
  case "invalid annotation input cannot mutate the graph" invalid_input_never_stages_operations;
  case "cross asset and stale graph mutations are rejected" cross_asset_and_stale_graph_are_rejected;
  case "last page is persisted on the original PDF asset" last_page_is_saved_on_the_asset;
  case "selected text follows desktop Chinese and hyphenation rules" selected_text_uses_desktop_line_break_rules;
  case "recoloring desktop area annotations preserves their data" desktop_area_annotations_keep_their_original_data;
  case "PDF opening is a supported shared host update" workspace_host_update_is_supported;
  case "workspace retains main and rejects events from an old document" workspace_preserves_main_and_rejects_late_events;
  case "shared asset actions open local and remote PDFs in the workspace" shared_asset_actions_open_local_and_remote_pdfs;
]
