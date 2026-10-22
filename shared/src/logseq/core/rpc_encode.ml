module Json = Yojson.Basic
module Wire = Rpc_wire
module Model = Cache_model
module Outliner = Outliner_state
module Effects = Outliner_effects
module Cards = Flashcards

let youtube_url url = Media.youtube_id url <> None

let youtube_target_urls (blocks : Model.block list) =
  let _, reversed = List.fold_left (fun (current, targets) (block : Model.block) ->
    let markup = Markup.to_yojson (Markup.parse block.references block.tags block.title) in
    let resolved, current = Media.resolve_markup ?preceding:current markup in
    let targets = match Media.first_timestamp_target resolved with
      | Some url -> (block.uuid, url) :: targets | None -> targets in
    current, targets) (None, []) blocks in
  List.rev reversed

let youtube_target_map blocks =
  let targets = Hashtbl.create 16 in
  List.iter (fun (id, url) -> Hashtbl.replace targets id url) (youtube_target_urls blocks);
  targets

let summary_json (summary : Model.entity_summary) =
  Wire.json_object
    [ ("uuid", `String summary.uuid); ("title", `String summary.title) ]

let status_response_json (status : Model.status) =
  Wire.json_object
    ([ ("uuid", `String status.uuid); ("title", `String status.title) ]
     @ (match status.ident with
        | Some ident -> [ ("ident", `String ident) ]
        | None -> [])
     @ (match (status.icon_type, status.icon_id) with
        | Some kind, Some id ->
          [
            ( "icon"
            , Wire.json_object
                ([ ("type", `String kind); ("id", `String id) ]
                 @ (match status.icon_color with
                    | Some color -> [ ("color", `String color) ]
                    | None -> [])) )
          ]
        | _ -> []))

(* Cache markup until its source text, references, tags, or display type changes. *)
let markup_cache :
    (string, string * Model.entity_summary list * Model.entity_summary list * string option * Json.t)
    Hashtbl.t =
  Hashtbl.create 256

let markup_json_encode (block : Model.block) =
  let nodes =
    match block.display_type with
    | Some "math" -> [Markup.Markup_math (block.title, true)]
    | Some "code" -> [Markup.Markup_code_block (None, block.title)]
    | Some "quote" ->
      [Markup.Markup_quote (Markup.parse block.references block.tags block.title)]
    | _ -> Markup.parse block.references block.tags block.title
  in
  let encoded = Markup.to_yojson nodes
  in
  if Hashtbl.length markup_cache > 8192 then Hashtbl.reset markup_cache;
  Hashtbl.replace markup_cache block.uuid
    (block.title, block.references, block.tags, block.display_type, encoded);
  encoded

let markup_json (block : Model.block) =
  match Hashtbl.find_opt markup_cache block.uuid with
  | Some (title, references, tags, display_type, encoded)
    when title = block.title
         && references = block.references
         && tags = block.tags
         && display_type = block.display_type ->
    encoded
  | _ -> markup_json_encode block

let block_json (block : Model.block) =
  Wire.json_object
    ([ ("uuid", `String block.uuid)
     ; ("title", `String block.title)
     ; ("displayTitle", `String (Markup.plain_text (Markup.parse block.references block.tags block.title)))
     ; ("pageId", `String block.page_id)
     ; ("createdAt", `Int block.created_at)
     ; ("updatedAt", `Int block.updated_at)
     ; ("syncStatus", `String block.sync_status)
     ; ("isAsset", `Bool block.is_asset)
     ; ("tags", `List (List.map summary_json block.tags))
     ; ("references", `List (List.map summary_json block.references))
     ; ("breadcrumbs", `List (List.map summary_json block.breadcrumbs))
     ; ("markup", markup_json block)
     ]
     @ (match block.display_type with Some typ -> ["displayType", `String typ] | None -> [])
     @ (match block.order with
        | Some order -> [ ("order", `String order) ]
        | None -> [])
     @ (match block.priority with
        | Some priority -> [ ("priority", status_response_json priority) ]
        | None -> [])
     @ (match block.status with
        | Some status -> [ ("status", status_response_json status) ]
        | None -> [])
     @ (match block.asset_type with
        | Some kind -> [ ("assetType", `String kind) ]
        | None -> [])
     @ (match block.asset_size with
        | Some size -> [ ("assetSize", `Int size) ]
        | None -> [])
     @ (match block.asset_checksum with
        | Some checksum -> [ ("assetChecksum", `String checksum) ]
        | None -> [])
     @ (match block.local_path with
        | Some path -> [ ("localPath", `String path) ]
        | None -> [])
     @ (match block.parent_id with
        | Some parent -> [ ("parentId", `String parent) ]
        | None -> []))

let block_shell_json (block : Model.block) =
  Wire.json_object (["uuid", `String block.uuid; "title", `String "";
    "pageId", `String block.page_id; "isShell", `Bool true;
    "createdAt", `Int block.created_at; "updatedAt", `Int block.updated_at]
    @ match block.journal with
      | Some (title, day) -> ["journalTitle", `String title; "journalDay", `Int day]
      | None -> [])

let visible_block_json (block : Model.block) =
  let encoded = block_json block in
  match block.journal with
  | Some (title, day) ->
    (match encoded with
     | `Assoc fields ->
       Wire.json_object
         ([ ("journalTitle", `String title); ("journalDay", `Int day) ]
          @ fields)
     | _ -> encoded)
  | None -> encoded

let flashcard_json (due_card : Cards.due_card) =
  let card = due_card.card in
  Wire.json_object
    [
      ("block", block_json due_card.block)
    ; ( "children", `List (List.map block_json due_card.children) )
    ; ("due", `Int card.due)
    ; ("repetitions", `Int card.reps)
    ; ("lapses", `Int card.lapses)
    ; ("state", `String (Cards.state_name card.state))
    ]

let graph_json (graph : Api.api_graph) =
  Wire.json_object
    ([
      ("id", `String graph.id)
    ; ("name", `String graph.name)
    ; ( "schemaVersion"
      , match graph.schema_version with
        | Some version -> `String version
        | None -> `Null )
    ; ("isEncrypted", `Bool graph.e2ee)
    ; ("isReady", `Bool graph.ready)
    ]
    @ (match graph.role with None -> [] | Some role -> [ "role", `String role ]))

let search_hit_json (hit : Search_index.indexed_search_hit) =
  Wire.json_object
    [
      ("uuid", `String hit.uuid)
    ; ("title", `String hit.title)
    ; ("isPage", `Bool hit.is_page)
    ; ( "page"
      , match hit.page with
        | Some page -> summary_json page
        | None -> `Null )
    ; ("breadcrumbs", `List (List.map summary_json hit.breadcrumbs))
    ]

let outliner_row_json youtube_target_url serialize_block
    (row : Outliner.outliner_row) =
  Wire.json_object
    ([ ("block", (match serialize_block row.block with
         | `Assoc fields -> (match List.assoc_opt "markup" fields with
             | Some markup -> let markup, _ = Media.resolve_markup ?preceding:youtube_target_url markup in
               `Assoc (("markup", markup) :: List.remove_assoc "markup" fields)
             | None -> `Assoc fields)
         | value -> value))
     ; ("depth", `Int row.depth)
     ; ("hasChildren", `Bool row.has_children)
     ; ("isCollapsed", `Bool row.is_collapsed)
     ]
     @ (match youtube_target_url with
        | Some url -> [ ("youtubeTargetURL", `String url) ]
        | None -> []))

let outliner_rows_json serialize_block context state =
  let rows = Outliner.visible_rows context state in
  let targets =
    youtube_target_map (List.map (fun row -> row.Outliner.block) rows)
  in
  Wire.json_list
    (List.map
       (fun row ->
         outliner_row_json
           (Hashtbl.find_opt targets row.Outliner.block.Model.uuid)
           serialize_block row)
       rows)

let rec common_row_prefix before after =
  match (before, after) with
  | b :: bs, a :: at when b = a -> 1 + common_row_prefix bs at
  | _ -> 0

let sub_list list start length =
  let rec take acc n xs =
    match xs with
    | x :: rest when n > 0 -> take (x :: acc) (n - 1) rest
    | _ -> List.rev acc
  in
  let rec drop n xs =
    match xs with
    | _ :: rest when n > 0 -> drop (n - 1) rest
    | _ -> xs
  in
  take [] length (drop start list)

let common_row_suffix before after start =
  let rec loop length =
    let before_index = List.length before - length - 1 in
    let after_index = List.length after - length - 1 in
    if
      before_index >= start && after_index >= start
      && List.nth before before_index = List.nth after after_index
    then loop (length + 1)
    else length
  in
  loop 0

let row_splice_position anchored before start =
  if anchored then
    let anchors =
      (if start > 0 then
         [
           ( "afterBlockId"
           , `String
               (List.nth before (start - 1)).Outliner.block.Model.uuid )
         ]
       else [])
      @
      if start < List.length before then
        [
          ( "beforeBlockId"
          , `String (List.nth before start).Outliner.block.Model.uuid )
        ]
      else []
    in
    if anchors = [] then [ ("start", `Int 0) ] else anchors
  else [ ("start", `Int start) ]

let structural_outliner_delta anchored before_context before_state
    after_context after_state =
  let before_rows = Outliner.visible_rows before_context before_state in
  let after_rows = Outliner.visible_rows after_context after_state in
  let before_uuids =
    List.map
      (fun (block : Model.block) -> (block.uuid, block))
      before_context.Outliner.blocks
  in
  let after_uuids =
    List.map
      (fun (block : Model.block) -> block.uuid)
      after_context.Outliner.blocks
  in
  let blocks =
    List.filter
      (fun (block : Model.block) ->
        List.assoc_opt block.uuid before_uuids <> Some block)
      after_context.Outliner.blocks
  in
  let deleted =
    List.filter_map
      (fun (block : Model.block) ->
        if List.mem block.uuid after_uuids then None else Some block.uuid)
      before_context.Outliner.blocks
  in
  let start = common_row_prefix before_rows after_rows in
  let suffix = common_row_suffix before_rows after_rows start in
  let delete_count = List.length before_rows - start - suffix in
  let insert_count = List.length after_rows - start - suffix in
  let targets =
    youtube_target_map
      (List.map (fun row -> row.Outliner.block) after_rows)
  in
  let splices =
    if delete_count = 0 && insert_count = 0 then []
    else
      [
        Wire.json_object
          (row_splice_position anchored before_rows start
           @ [
               ("deleteCount", `Int delete_count)
             ; ( "rows"
               , Wire.json_list
                   (List.map
                      (fun row ->
                        outliner_row_json
                          (Hashtbl.find_opt targets row.Outliner.block.Model.uuid)
                          visible_block_json row)
                      (sub_list after_rows start insert_count)) )
             ]);
      ]
  in
  (blocks, deleted, splices)

let outliner_candidates_json context state =
  Wire.json_list
    (match Outliner.autocomplete state with
     | Some request ->
       let groups = Hashtbl.create 9 in
       List.map
         (fun (candidate : Outliner.outliner_candidate) ->
           let group = if request.kind <> Outliner.Command || String.trim request.query <> "" then None
             else Option.bind (Editor_command.group candidate.value) (fun group ->
               if Hashtbl.mem groups group then None
               else (Hashtbl.add groups group (); Some group)) in
           Wire.json_object
             (["label", `String candidate.label; "value", `String candidate.value]
              @ match group with Some group -> ["group", `String group] | None -> []))
         (Outliner.autocomplete_candidates context request)
     | None -> [])

let autocomplete_kind_json kind =
  match kind with
  | Outliner.Node -> "node"
  | Outliner.Tag -> "tag"
  | Outliner.Property -> "property"
  | Outliner.Command -> "command"
  | Outliner.Picker picker -> Editor_command.picker_name picker

let outliner_state_json (state : Outliner.outliner_state) =
  Wire.json_object
    [
      ( "editing"
      , match state.editing with
        | Some editing ->
          Wire.json_object
            [
              ("uuid", `String editing.uuid)
            ; ("title", `String editing.title)
            ; ("caretUTF16Offset", `Int editing.caret)
            ]
        | None -> `Null )
    ; ( "selectedBlockIds"
      , Wire.json_strings (Outliner.selected_uuids state) )
    ; ( "collapsedBlockIds"
      , Wire.json_strings (Outliner.collapsed_uuids state) )
    ; ("zoomedBlockIds", Wire.json_strings state.zoomed)
    ; ( "autocomplete"
      , match state.autocomplete with
        | Some request ->
          Wire.json_object
            [
              ( "kind"
              , `String (autocomplete_kind_json request.kind) )
            ; ("query", `String request.query)
            ]
        | None -> `Null )
    ]

let outliner_command_json (command : Effects.outliner_platform_command) =
  let kind, key, value =
    match command with
    | Effects.Platform_haptic haptic ->
      ( "haptic"
      , "style"
      , `String
          (match haptic with
           | Outliner.Selection -> "selection"
           | Outliner.Impact -> "impact") )
    | Effects.Focus_block uuid ->
      ("focusBlock", "uuid", `String uuid)
    | Effects.Confirm_delete uuids ->
      ("confirmDelete", "uuids", Wire.json_strings uuids)
    | Effects.Set_clipboard_text text ->
      ("setClipboardText", "text", `String text)
    | Effects.Set_clipboard_references uuids ->
      ("setClipboardReferences", "uuids", Wire.json_strings uuids)
    | Effects.Set_clipboard_urls uuids ->
      ("setClipboardURLs", "uuids", Wire.json_strings uuids)
    | Effects.Platform_pick_attachment uuid ->
      ("pickAttachment", "uuid", `String uuid)
    | Effects.Platform_take_photo uuid ->
      ("takePhoto", "uuid", `String uuid)
    | Effects.Platform_record_audio uuid ->
      ("recordAudio", "uuid", `String uuid)
  in
  Wire.json_object [ ("type", `String kind); (key, value) ]

let with_node_icons resolve result =
  let ids = Hashtbl.create 64 in
  let add = function `String uuid when uuid <> "" -> Hashtbl.replace ids uuid () | _ -> () in
  let rec collect = function
    | `Assoc fields when List.assoc_opt "isShell" fields <> Some (`Bool true) ->
      List.iter (fun (key, value) ->
        if key = "uuid" || key = "nodeUuid" || key = "pageId" then add value;
        collect value) fields
    | `List values -> List.iter collect values
    | _ -> () in
  collect result;
  match result with
  | `Assoc fields -> `Assoc (("nodeIcons", `Assoc (Hashtbl.fold (fun uuid () icons ->
      (uuid, Option.value ~default:`Null (resolve uuid)) :: icons) ids [])) :: fields)
  | _ -> result

let outliner_patch_result ?(node_icon = fun _ -> None) ?sync_error revision context state command_revision commands
    pending blocks deleted splices =
  Wire.success
    (with_node_icons node_icon (Wire.json_object
       [
         ("revision", `Int revision)
       ; ("blocks", Wire.json_list (List.map visible_block_json blocks))
       ; ("deletedBlockIds", Wire.json_strings deleted)
       ; ("selectedBlock", `Null)
       ; ("outlinerState", outliner_state_json state)
       ; ( "outlinerAutocompleteCandidates"
         , outliner_candidates_json context state )
       ; ("outlinerRows", Wire.json_list [])
       ; ("outlinerRowSplices", Wire.json_list splices)
       ; ("outlinerCommandRevision", `Int command_revision)
       ; ( "outlinerCommands"
         , Wire.json_list (List.map outliner_command_json commands) )
       ; ("hasPendingSemanticOperations", `Bool pending)
       ; ("pendingSyncError", match sync_error with Some message -> `String message | None -> `Null)
       ; ("isOutlinerPatch", `Bool true)
       ]))
