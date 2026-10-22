module J = Yojson.Basic

let request ~now ~fresh_id payload =
  let ( let* ) = Result.bind in
  let string fields key = match List.assoc_opt key fields with
    | Some (`String value) -> Ok value
    | _ -> Error ("The effect requires " ^ key) in
  let integer fields key = match List.assoc_opt key fields with
    | Some (`Int value) -> Ok value
    | _ -> Error ("The effect requires integer " ^ key) in
  let object_string value = try match J.from_string value with
    | `Assoc _ as value -> Ok value
    | _ -> Error "Effect metadata must be an object"
    with _ -> Error "Effect metadata must be valid JSON" in
  try
    let* fields = match payload with
      | Some payload -> (match J.from_string payload with
          | `Assoc fields -> Ok fields | _ -> Error "Effect must be an object")
      | None -> Error "An effect payload is required" in
    let* kind = string fields "kind" in
    let text () = string fields "text" in
    let raw action = let* value = text () in Ok (action, Some value) in
    let empty action = Ok (action, None) in
    let json action fields = Ok (action, Some (J.to_string (`Assoc fields))) in
    let metadata () = let* value = string fields "metadata" in object_string value in
    let event name extra = json "outlinerEvent" (("type", `String name) :: extra) in
    let text_event name key = let* value = text () in event name [key, `String value] in
    let identity () = ["uuid", `String (fresh_id ()); "now", `Int (now ())] in
    let operation () = ["operationId", `String (fresh_id ()); "now", `Int (now ())] in
    match kind with
    | "send-capture" -> let* value = text () in json "send" (("text", `String value) :: identity ())
    | "send-task" ->
      let* value = text () in let* status = metadata () in
      json "sendTask" (["text", `String value; "status", status] @ identity ())
    | "send-asset" -> raw "addAsset"
    | "result-view" -> raw "resultView"
    | "recording-transcribed" -> let* uuid = string fields "uuid" in let* text = text () in
      json "completeAssetTranscription" ["parentId", `String uuid; "text", `String text]
    | "load-page-references" -> raw "loadPageReferences"
    | "hydrate-outliner-rows" -> raw "hydrateOutlinerRows"
    | "search-nodes" -> raw "searchNodes"
    | "load-search-page" -> let* query = text () in let* offset = integer fields "value" in
      json "searchNodesPage" ["query", `String query; "offset", `Int offset]
    | "open-node" | "open-search-result" -> let* uuid = text () in
      json "openNode" ["uuid", `String uuid; "reveal", `Bool (kind = "open-search-result")]
    | "close-node" -> empty "closeNode"
    | "select-sidebar-page" -> raw "selectPage"
    | "clear-selected-page" -> empty "clearSelectedPage"
    | "load-older-journals" -> empty "loadOlderJournals"
    | "load-flashcards" -> Ok ("loadFlashcards", Some (string_of_int (now ())))
    | "refresh-graphs" -> empty "refresh"
    | "set-page-favorite" -> let* uuid = text () in let* value = integer fields "value" in
      json "setPageFavorite" (["pageUuid", `String uuid; "favorite", `Bool (value = 1)] @ operation ())
    | "delete-page" -> let* uuid = text () in json "deletePage" (("pageUuid", `String uuid) :: operation ())
    | "review-flashcard" -> let* uuid = string fields "uuid" in let* rating = text () in
      json "reviewFlashcard" (["uuid", `String uuid; "rating", `String rating] @ operation ())
    | "tap-outliner-block" -> text_event "tapBlock" "uuid"
    | "toggle-outliner-collapsed" -> text_event "toggleCollapsed" "uuid"
    | "long-press-outliner-block" -> text_event "longPressBlock" "uuid"
    | "add-root-block" -> text_event "addRootBlock" "uuid"
    | "drop-outliner-blocks" -> let* target = text () in let* placement = string fields "metadata" in
      event "dropBlocks" ["targetUuid", `String target; "placement", `String placement]
    | "set-outliner-task-status" ->
      let* uuid = text () in let* status = metadata () in
      let field name = match status with `Assoc fields -> Option.value ~default:`Null (List.assoc_opt name fields) | _ -> `Null in
      event "setTaskStatus" ["uuid", `String uuid; "statusIdent", field "ident"; "statusUuid", field "uuid"]
    | "outliner-toolbar" -> text_event "toolbar" "action"
    | "choose-outliner-autocomplete" -> text_event "chooseAutocomplete" "value"
    | "save-outliner-editing" -> event "saveEditing" []
    | "confirm-outliner-delete" -> event "confirmDelete" []
    | "cancel-outliner-editing" -> event "cancelEditing" []
    | "change-outliner-text" | "return-outliner-editor" | "backspace-outliner-editor" | "move-outliner-caret" ->
      let* uuid = string fields "uuid" in let* value = integer fields "value" in
      let name, key = match kind with
        | "change-outliner-text" -> "textChanged", "caretUTF16Offset"
        | "return-outliner-editor" -> "returnPressed", "caretUTF16Offset"
        | "backspace-outliner-editor" -> "backspacePressed", "selectionLength"
        | _ -> "caretMoved", "caretUTF16Offset" in
      let* extra = if kind = "move-outliner-caret" then Ok [] else
        let* title = text () in Ok ["title", `String title] in
      event name (["uuid", `String uuid; key, `Int value] @ extra)
    | "open-graph" -> raw "selectGraph"
    | "unlock-graph" -> raw "unlockGraph"
    | "create-graph" -> let* name = text () in let* value = integer fields "value" in
      let* password = string fields "metadata" in
      json "createSyncGraph" ["name", `String name; "isEncrypted", `Bool (value = 1); "password", `String password]
    | _ -> Error ("Unsupported core effect: " ^ kind)
  with Yojson.Json_error _ -> Error "Effect must be valid JSON"
