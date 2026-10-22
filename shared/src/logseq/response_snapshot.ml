module Json = Yojson.Basic
module Util = Yojson.Basic.Util

let fields_from_entries entries =
  List.fold_left
    (fun fields (name, value) ->
      if List.mem_assoc name fields then fields else (name, value) :: fields)
    [] entries

let object_fields input =
  match input with
  | `Assoc entries -> fields_from_entries entries
  | _ -> []

let object_member name fields =
  match List.assoc_opt name fields with
  | Some value -> object_fields value
  | None -> []

let string_member name fields =
  match List.assoc_opt name fields with
  | Some (`String text) -> Some text
  | _ -> None

let bool_member name fields =
  match List.assoc_opt name fields with
  | Some (`Bool value) -> value
  | _ -> false

let int_member name fields =
  match List.assoc_opt name fields with
  | Some (`Int value) -> Some value
  | _ -> None

let list_member name fields =
  match List.assoc_opt name fields with
  | Some (`List values) -> values
  | _ -> []

let string_list_member name fields =
  List.filter_map
    (function `String text -> Some text | _ -> None)
    (list_member name fields)

let filter_map_option f values = List.filter_map f values

let sidebar_page input =
  let fields = object_fields input in
  match string_member "uuid" fields, string_member "title" fields with
  | Some uuid, Some title -> Some { Model.uuid; title }
  | _ -> None

let sidebar_pages_member name fields =
  filter_map_option sidebar_page (list_member name fields)

let breadcrumbs fields = sidebar_pages_member "breadcrumbs" fields

let breadcrumb fields =
  let titles = List.map (fun (page : Model.sidebar_page) -> page.title)
      (breadcrumbs fields) in
  match titles with
  | [] ->
    (match string_member "title" (object_member "page" fields) with
     | Some title -> title
     | None -> "")
  | _ -> String.concat " › " titles

let search_hit input =
  let fields = object_fields input in
  match string_member "uuid" fields, string_member "title" fields with
  | Some hit_uuid, Some hit_title ->
    Some
      { Model.hit_uuid; hit_title;
        breadcrumb = breadcrumb fields;
        breadcrumbs = breadcrumbs fields;
        is_page = bool_member "isPage" fields }
  | _ -> None

let graph input =
  let fields = object_fields input in
  match string_member "id" fields, string_member "name" fields with
  | Some id, Some name ->
    Some
      { Model.id; name;
        is_encrypted = bool_member "isEncrypted" fields;
        is_ready = bool_member "isReady" fields;
        role = string_member "role" fields }
  | _ -> None

let task_status input =
  let fields = object_fields input in
  let icon = object_member "icon" fields in
  match string_member "uuid" fields, string_member "title" fields with
  | Some uuid, Some title ->
    Some
      { Model.uuid; title;
        ident = string_member "ident" fields;
        icon_type = string_member "type" icon;
        icon_id = string_member "id" icon;
        icon_color = string_member "color" icon }
  | _ -> None

let rec markup_text reveal_cloze input =
  let fields = object_fields input in
  let children =
    String.concat ""
      (List.map (markup_text reveal_cloze) (list_member "children" fields))
  in
  match string_member "type" fields |> Option.value ~default:"" with
  | "cloze" ->
    if reveal_cloze then Option.value ~default:"" (string_member "text" fields)
    else "[…]"
  | "nodeReference" -> Option.value ~default:"" (string_member "title" fields)
  | "tagReference" ->
    "#" ^ Option.value ~default:"" (string_member "title" fields)
  | "link" ->
    if children = "" then Option.value ~default:"" (string_member "url" fields)
    else children
  | "video" | "iframe" ->
    Option.value ~default:"" (string_member "url" fields)
  | "emphasis" | "quote" -> children
  | _ ->
    (match string_member "text" fields with
     | Some text -> text
     | None -> children)

let rec markup_has_cloze input =
  let fields = object_fields input in
  string_member "type" fields = Some "cloze"
  || List.exists markup_has_cloze (list_member "children" fields)

let rec inline_tag_ids input =
  let fields = object_fields input in
  let ids =
    if string_member "type" fields = Some "tagReference" then
      match string_member "uuid" fields with
      | Some uuid -> [ uuid ]
      | None -> []
    else []
  in
  ids
  @ List.concat_map inline_tag_ids (list_member "children" fields)

let trailing_tags fields =
  let inline_ids =
    List.concat_map inline_tag_ids (list_member "markup" fields)
  in
  let _seen, tags =
    List.fold_left
      (fun (seen, result) (tag : Model.sidebar_page) ->
        if List.mem tag.uuid inline_ids || List.mem tag.uuid seen then
          (seen, result)
        else (tag.uuid :: seen, result @ [ tag ]))
      ([], []) (sidebar_pages_member "tags" fields)
  in
  tags

let rec find_substring value pattern start =
  if start + String.length pattern > String.length value then None
  else if String.sub value start (String.length pattern) = pattern then
    Some start
  else find_substring value pattern (start + 1)

let legacy_cloze_text reveal value =
  let result = Buffer.create (String.length value) in
  let rec loop offset has_cloze =
    match find_substring value "{{" offset with
    | Some opening ->
      Buffer.add_substring result value offset (opening - offset);
      (match find_substring value "}}" (opening + 2) with
       | Some closing ->
         let body = String.sub value (opening + 2) (closing - opening - 2) in
         let cloze =
           let lowered = String.lowercase_ascii body in
           String.length lowered >= 6
           && String.sub lowered 0 6 = "cloze "
         in
         Buffer.add_string result
           (if cloze then
              if reveal then
                String.trim (String.sub body 6 (String.length body - 6))
              else "[…]"
            else String.sub value opening (closing + 2 - opening));
         loop (closing + 2) (has_cloze || cloze)
       | None ->
         Buffer.add_substring result value opening
           (String.length value - opening);
         (Buffer.contents result, has_cloze))
    | None ->
      Buffer.add_substring result value offset (String.length value - offset);
      (Buffer.contents result, has_cloze)
  in
  loop 0 false

let block_markup_text reveal fields =
  let markup = list_member "markup" fields in
  match markup with
  | [] ->
    fst
      (legacy_cloze_text reveal
         (Option.value ~default:"" (string_member "title" fields)))
  | _ -> String.concat "" (List.map (markup_text reveal) markup)

let flashcard_answer input =
  let fields = object_fields input in
  match string_member "uuid" fields with
  | Some answer_uuid ->
    Some
      { Model.answer_uuid; answer_index = 0;
        answer_text = block_markup_text true fields }
  | None -> None

let flashcard input =
  let fields = object_fields input in
  let block = object_member "block" fields in
  match string_member "uuid" block with
  | Some flashcard_uuid ->
    let answer_rows =
      List.mapi
        (fun index (row : Model.flashcard_answer_row) ->
          { row with Model.answer_index = index })
        (filter_map_option flashcard_answer (list_member "children" fields))
    in
    let has_cloze =
      List.exists markup_has_cloze (list_member "markup" block)
      || snd
           (legacy_cloze_text false
              (Option.value ~default:"" (string_member "title" block)))
    in
    Some
      { Model.flashcard_uuid;
        question_hidden = block_markup_text false block;
        question_revealed = block_markup_text true block;
        answer_rows; has_cloze }
  | None -> None

let outline_row_from_block youtube_target_url opens_as_page depth
    has_children is_collapsed fields =
  match string_member "uuid" fields, string_member "title" fields with
  | Some row_uuid, Some row_title ->
    Some
      { Model.row_uuid; row_title; row_list_number = int_member "listNumber" fields;
        row_display_type = string_member "displayType" fields; row_loaded = not (bool_member "isShell" fields);
        query_json = (match List.assoc_opt "query" fields with
          | Some (`Assoc _ as value) -> Yojson.Basic.to_string value | _ -> "");
        markup_json =
          (match List.assoc_opt "markup" fields with
           | Some markup -> Yojson.Basic.to_string markup
           | None -> "[]");
        youtube_target_url;
        row_breadcrumb = breadcrumb fields;
        row_breadcrumbs = breadcrumbs fields;
        opens_as_page; depth; has_children; is_collapsed;
        is_asset = bool_member "isAsset" fields;
        asset_type = string_member "assetType" fields;
        local_path = string_member "localPath" fields;
        row_priority = Option.bind (List.assoc_opt "priority" fields) task_status;
        row_status =
          (match List.assoc_opt "status" fields with
           | Some status -> task_status status
           | None -> None);
        tags = trailing_tags fields;
        sync_status = string_member "syncStatus" fields;
        page_id = Option.value ~default:"" (string_member "pageId" fields);
        journal_title = string_member "journalTitle" fields;
        journal_day = int_member "journalDay" fields }
  | _ -> None

let outline_row input =
  let fields = object_fields input in
  match int_member "depth" fields with
  | Some depth ->
    outline_row_from_block
      (string_member "youtubeTargetURL" fields)
      false depth (bool_member "hasChildren" fields)
      (bool_member "isCollapsed" fields)
      (object_member "block" fields)
  | None -> None

let related_row input =
  let fields = object_fields input in
  let opens_as_page =
    match string_member "uuid" fields with
    | Some uuid -> string_member "pageId" fields = Some uuid
    | None -> false
  in
  outline_row_from_block
    (string_member "youtubeTargetURL" fields)
    opens_as_page 0 false false fields

let outliner_rows_member name fields =
  filter_map_option outline_row (list_member name fields)

let related_rows_member name fields =
  filter_map_option related_row (list_member name fields)

let outliner_editing input =
  let fields = object_fields input in
  match
    ( string_member "uuid" fields,
      string_member "title" fields,
      int_member "caretUTF16Offset" fields )
  with
  | Some editing_uuid, Some editing_title, Some caret_utf16_offset ->
    Some { Model.editing_uuid; editing_title; caret_utf16_offset }
  | _ -> None

let outliner_autocomplete input =
  let fields = object_fields input in
  let kind =
    match string_member "kind" fields |> Option.value ~default:"" with
    | "node" -> Some Model.NodeAutocomplete
    | "tag" -> Some Model.TagAutocomplete
    | "property" -> Some Model.PropertyAutocomplete
    | "command" -> Some Model.CommandAutocomplete
    | ("embed" | "template" | "link" | "image" | "date" | "deadline" | "scheduled" | "youtube") as kind -> Some (Model.PickerAutocomplete kind)
    | _ -> None
  in
  match kind, string_member "query" fields with
  | Some autocomplete_kind, Some autocomplete_query ->
    Some { Model.autocomplete_kind; autocomplete_query }
  | _ -> None

let autocomplete_candidate input =
  let fields = object_fields input in
  match string_member "label" fields, string_member "value" fields with
  | Some candidate_label, Some candidate_value ->
    Some { Model.candidate_index = 0; candidate_label; candidate_value }
  | _ -> None

let autocomplete_candidates_member fields =
  List.mapi
    (fun candidate_index (candidate : Model.outliner_autocomplete_candidate)
      -> { candidate with Model.candidate_index })
    (filter_map_option autocomplete_candidate
       (list_member "outlinerAutocompleteCandidates" fields))

let editing_member fields =
  match List.assoc_opt "editing" (object_member "outlinerState" fields) with
  | Some value -> outliner_editing value
  | None -> None

let autocomplete_member fields =
  match
    List.assoc_opt "autocomplete" (object_member "outlinerState" fields)
  with
  | Some value -> outliner_autocomplete value
  | None -> None

let selection_member fields =
  string_list_member "selectedBlockIds"
    (object_member "outlinerState" fields)

let outliner_row_splice input =
  let fields = object_fields input in
  match int_member "deleteCount" fields with
  | Some delete_count ->
    Some
      { Model.splice_start = int_member "start" fields;
        after_block_id = string_member "afterBlockId" fields;
        before_block_id = string_member "beforeBlockId" fields;
        delete_count;
        splice_rows = outliner_rows_member "rows" fields }
  | None -> None

let node_title uuid is_tag fields =
  let title =
    Option.value ~default:"Untitled"
      (string_member "title" (object_member "page" fields))
  in
  if is_tag then "#" ^ title
  else
    match
      List.find_map
        (fun block ->
          let block_fields = object_fields block in
          if string_member "uuid" block_fields = Some uuid then
            Some (block_markup_text true block_fields)
          else None)
        (list_member "blocks" fields)
    with
    | Some found -> found
    | None -> title

let node_route input =
  let fields = object_fields input in
  match string_member "uuid" fields with
  | Some node_uuid ->
    let node_is_tag = bool_member "isTag" fields in
    Some
      { Model.node_uuid;
        node_page_uuid =
          Option.value ~default:node_uuid
            (string_member "uuid" (object_member "page" fields));
        node_title = node_title node_uuid node_is_tag fields;
        node_is_tag;
        node_is_property = bool_member "isProperty" fields;
        node_breadcrumbs = breadcrumbs fields;
        node_scroll_target = string_member "scrollTarget" fields;
        node_outliner_rows = outliner_rows_member "outlinerRows" fields;
        node_properties_json = (match List.assoc_opt "nodeProperties" fields with Some (`Assoc _ as value) -> Json.to_string value | _ -> "");
        node_result_views_json = (match List.assoc_opt "resultViews" fields with Some (`Assoc _ as value) -> Json.to_string value | _ -> "");
        node_related_rows = related_rows_member "relatedBlocks" fields;
        node_linked_reference_rows =
          related_rows_member "linkedReferenceBlocks" fields;
        node_outliner_editing = editing_member fields;
        node_outliner_autocomplete = autocomplete_member fields;
        node_outliner_autocomplete_candidates =
          autocomplete_candidates_member fields;
        node_outliner_selected_block_ids = selection_member fields }
  | None -> None

let sidebar_projection fields =
  { Model.favorites = sidebar_pages_member "favorites" fields;
    recent_pages = sidebar_pages_member "recentPages" fields;
    selected_page =
      (match List.assoc_opt "selectedPage" fields with
       | Some page -> sidebar_page page
       | None -> None);
    selected_page_is_tag = bool_member "selectedPageIsTag" fields;
    selected_page_is_property =
      bool_member "selectedPageIsProperty" fields;
    properties_json = (match List.assoc_opt "nodeProperties" fields with Some (`Assoc _ as value) -> Json.to_string value | _ -> "");
    result_views_json = (match List.assoc_opt "resultViews" fields with Some (`Assoc _ as value) -> Json.to_string value | _ -> "");
    related_rows = related_rows_member "relatedBlocks" fields;
    linked_reference_rows =
      related_rows_member "linkedReferenceBlocks" fields }

let core_projection fields =
  let is_patch = bool_member "isOutlinerPatch" fields in
  let base_rows = outliner_rows_member "outlinerRows" fields in
  let routes =
    List.filter_map node_route (list_member "nodeRoutes" fields)
  in
  let active =
    match List.rev routes with
    | last :: _ -> Some last
    | [] -> None
  in
  let or_route get fallback =
    match active with
    | Some route -> get route
    | None -> fallback
  in
  { Model.graph_name = string_member "graphName" fields;
    selected_graph_id = string_member "selectedGraphId" fields;
    graphs = List.filter_map graph (list_member "graphs" fields);
    is_graph_encrypted = bool_member "isGraphEncrypted" fields;
    is_graph_unlocked = bool_member "isGraphUnlocked" fields;
    sidebar = sidebar_projection fields;
    task_priorities = List.filter_map task_status (list_member "taskPriorities" fields);
    task_statuses =
      List.filter_map task_status (list_member "taskStatuses" fields);
    flashcards = List.filter_map flashcard (list_member "flashcards" fields);
    search_offset = Option.value ~default:0 (int_member "searchOffset" fields);
    search_has_more = bool_member "searchHasMore" fields;
    projection_search_query =
      Option.value ~default:"" (string_member "searchQuery" fields);
    search_results =
      List.filter_map search_hit (list_member "searchResults" fields);
    node_routes = routes;
    empty_journals = List.filter_map (fun item -> match item with
      | `Assoc fields -> (match string_member "uuid" fields, string_member "title" fields,
          int_member "journalDay" fields with
        | Some uuid, Some title, Some day -> Some ({Model.uuid; title}, day)
        | _ -> None)
      | _ -> None) (list_member "emptyJournals" fields);
    journal_outliner_rows = base_rows;
    outliner_rows =
      or_route
        (fun (route : Model.node_projection) -> route.node_outliner_rows)
        base_rows;
    outliner_row_splices =
      List.filter_map outliner_row_splice
        (list_member "outlinerRowSplices" fields);
    projection_outliner_editing =
      or_route
        (fun (route : Model.node_projection) -> route.node_outliner_editing)
        (editing_member fields);
    projection_outliner_autocomplete =
      or_route
        (fun (route : Model.node_projection) ->
          route.node_outliner_autocomplete)
        (autocomplete_member fields);
    projection_outliner_autocomplete_candidates =
      or_route
        (fun (route : Model.node_projection) ->
          route.node_outliner_autocomplete_candidates)
        (autocomplete_candidates_member fields);
    projection_outliner_selected_block_ids =
      or_route
        (fun (route : Model.node_projection) ->
          route.node_outliner_selected_block_ids)
        (selection_member fields);
    has_older_journals = bool_member "hasOlderJournals" fields;
    is_outliner_patch = is_patch;
    reference_update = (if bool_member "isReferencePatch" fields then
      Option.map (fun uuid -> (uuid, related_rows_member "referenceBlocks" fields))
        (string_member "referenceUuid" fields) else None);
    pending_reference_uuid = string_member "pendingReferenceUuid" fields;
    is_outliner_content_patch = bool_member "isOutlinerContentPatch" fields;
    hydrated_rows =
      (if is_patch then related_rows_member "blocks" fields else [])
      @ related_rows_member "hydratedBlocks" fields;
    is_search_patch = bool_member "isSearchPatch" fields;
    sync_connected = bool_member "syncConnected" fields;
    applied_server_t = int_member "appliedServerT" fields;
    has_pending_semantic_operations =
      bool_member "hasPendingSemanticOperations" fields;
    has_pending_sync_request =
      (match List.assoc_opt "pendingSyncRequest" fields with
       | None | Some `Null -> false
       | Some _ -> true);
    node_icons = (object_member "nodeIcons" fields |> List.fold_left (fun icons (uuid, value) ->
      Lui_protocol.String_map.add uuid (if value = `Null then "" else Yojson.Basic.to_string value) icons) Lui_protocol.String_map.empty);
    pending_sync_error = string_member "pendingSyncError" fields;
    is_pending_sync_patch = bool_member "isPendingSyncPatch" fields;
    is_pending_sync_projection = bool_member "isPendingSyncProjection" fields;
    is_graph_catalog_patch = bool_member "isGraphCatalogPatch" fields }

let error_message fields =
  let error = object_member "error" fields in
  Option.value ~default:"core_request_failed" (string_member "code" error)
  ^ "\n"
  ^ Option.value ~default:"Core request failed"
      (string_member "message" error)

let decode_response encoded =
  try
    match Json.from_string encoded with
    | `Assoc entries ->
      let fields = fields_from_entries entries in
      if bool_member "ok" fields then
        match List.assoc_opt "result" fields with
        | Some (`Assoc result_entries) ->
          Ok (core_projection (fields_from_entries result_entries))
        | _ -> Error "Core response did not contain a snapshot"
      else Error (error_message fields)
    | _ -> Error "Core response must be a JSON object"
  with Yojson.Json_error message ->
    Error ("Invalid core response: " ^ message)
