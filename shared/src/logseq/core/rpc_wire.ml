module Json = Yojson.Basic
module Json_util = Yojson.Basic.Util
module Model = Cache_model
module Ops = Pending_ops
module Outliner = Outliner_state
module Cards = Flashcards
module Api_ = Api

let journal_page_uuid journal_day =
  Printf.sprintf "00000001-%04d-%04d-0000-000000000000"
    (journal_day / 10000) (journal_day mod 10000)

let journal_day_title journal_day =
  let months =
    [|
      "Jan"; "Feb"; "Mar"; "Apr"; "May"; "Jun"; "Jul"; "Aug"; "Sep"
    ; "Oct"; "Nov"; "Dec"
    |]
  in
  let year = journal_day / 10000 in
  let month = journal_day / 100 mod 100 in
  let day = journal_day mod 100 in
  let suffix =
    if day mod 100 >= 11 && day mod 100 <= 13 then "th"
    else
      match day mod 10 with
      | 1 -> "st"
      | 2 -> "nd"
      | 3 -> "rd"
      | _ -> "th"
  in
  if month >= 1 && month <= Array.length months then
    Printf.sprintf "%s %d%s, %04d" months.(month - 1) day suffix year
  else invalid_arg "invalid journal month"

let fields_of entries =
  List.fold_left
    (fun acc (name, value) ->
      if List.mem_assoc name acc then acc else (name, value) :: acc)
    [] entries
  |> List.rev

let outliner_structure_source payload =
  match Json.from_string payload with
  | `Assoc entries ->
    let fields = fields_of entries in
    (match List.assoc_opt "type" fields with
     | Some (`String kind)
       when kind = "returnPressed" || kind = "backspacePressed" ->
       (match List.assoc_opt "uuid" fields with
        | Some (`String uuid) -> Some uuid
        | _ -> None)
     | _ -> None)
  | _ -> None

let outliner_structure_source_matches state payload =
  match outliner_structure_source payload with
  | Some uuid -> Outliner.editing_uuid state = Some uuid
  | None -> true

let toolbar_action wire =
  match wire with
  | "task" -> Ok Outliner.Task
  | "outdent" -> Ok Outliner.Outdent
  | "indent" -> Ok Outliner.Indent
  | "moveUp" -> Ok Outliner.Move_up
  | "moveDown" -> Ok Outliner.Move_down
  | "tag" -> Ok Outliner.Tag_action
  | "pageReference" -> Ok Outliner.Page_reference
  | "camera" -> Ok Outliner.Camera
  | "audio" -> Ok Outliner.Audio
  | "attachment" -> Ok Outliner.Attachment
  | "hideKeyboard" -> Ok Outliner.Hide_keyboard
  | "copy" -> Ok Outliner.Copy
  | "delete" -> Ok Outliner.Delete
  | "copyReference" -> Ok Outliner.Copy_reference
  | "copyURL" -> Ok Outliner.Copy_url
  | "unselect" -> Ok Outliner.Unselect
  | _ -> Error "unknown outliner toolbar action"

let flashcard_rating wire =
  match wire with
  | "again" -> Ok Cards.Again
  | "hard" -> Ok Cards.Hard
  | "good" -> Ok Cards.Good
  | "easy" -> Ok Cards.Easy
  | _ -> Error "rating must be again, hard, good, or easy"

let required_string fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok value
  | Some _ -> Error ("field must be a string: " ^ name)
  | None -> Error ("missing field: " ^ name)

let optional_string fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok (Some value)
  | Some `Null | None -> Ok None
  | _ -> Error ("field must be a string: " ^ name)

let required_string_list name input =
  match Json_util.member name input with
  | `List values ->
    List.fold_left
      (fun acc value ->
        let ( let* ) = Result.bind in
        let* items = acc in
        match value with
        | `String text when not (String_kit.is_blank text) ->
          Ok (items @ [ text ])
        | _ ->
          Error
            ("field must be a list of non-empty strings: " ^ name))
      (Ok []) values
  | _ -> Error ("field must be a list: " ^ name)

let decode_move input =
  match input with
  | `Assoc entries ->
    let fields = fields_of entries in
    let ( let* ) = Result.bind in
    let* uuid = required_string fields "uuid" in
    let* page_uuid = required_string fields "pageUuid" in
    let* parent_uuid = required_string fields "parentUuid" in
    let* order = required_string fields "order" in
    Ok { Ops.uuid; page_uuid; parent_uuid; order }
  | _ -> Error "moves must contain objects"

let required_moves input =
  match Json_util.member "moves" input with
  | `List values ->
    List.fold_left
      (fun acc value ->
        let ( let* ) = Result.bind in
        let* moves = acc in
        let* move = decode_move value in
        Ok (moves @ [ move ]))
      (Ok []) values
  | _ -> Error "field must be a list: moves"

let status_payload input =
  match Json_util.member "status" input with
  | `Assoc entries ->
    let fields = fields_of entries in
    let ( let* ) = Result.bind in
    let* uuid = required_string fields "uuid" in
    let* title = required_string fields "title" in
    let* ident = optional_string fields "ident" in
    let* icon_type = optional_string fields "iconType" in
    let* icon_id = optional_string fields "iconId" in
    let* icon_color = optional_string fields "iconColor" in
    Ok
      {
        Model.uuid;
        title;
        ident;
        icon_type;
        icon_id;
        icon_color;
      }
  | _ -> Error "missing field: status"

let optional_status_payload input =
  match Json_util.member "status" input with
  | `Null -> Ok None
  | _ ->
    Result.map (fun status -> Some status) (status_payload input)

let status_semantic_ref (status : Model.status) =
  match status.ident with
  | Some ident when not (String_kit.is_blank ident) ->
    Ops.Ref_ident ident
  | _ -> Ops.Ref_uuid status.uuid

let optional_int fields name =
  match List.assoc_opt name fields with
  | Some (`Int value) -> Ok (Some value)
  | Some `Null | None -> Ok None
  | _ -> Error ("field must be an integer: " ^ name)

let send_payload payload =
  let raw = match payload with Some text -> text | None -> "" in
  let parsed =
    try Some (Json.from_string raw) with _ -> None
  in
  match parsed with
  | Some (`Assoc entries) ->
    let fields = fields_of entries in
    let ( let* ) = Result.bind in
    let* text = required_string fields "text" in
    let* uuid = optional_string fields "uuid" in
    let* now = optional_int fields "now" in
    Ok (String_kit.trim text, uuid, now)
  | _ -> Ok (String_kit.trim raw, None, None)

let event_int fields name =
  match List.assoc_opt name fields with
  | Some (`Int value) -> Ok value
  | _ -> Error ("missing integer outliner event field: " ^ name)

let drop_placement wire =
  match wire with
  | "before" -> Ok Outliner.Before
  | "inside" -> Ok Outliner.Inside
  | "after" -> Ok Outliner.After
  | _ -> Error "unknown outliner drop placement"

let decode_outliner_event fields =
  let ( let* ) = Result.bind in
  let* kind = required_string fields "type" in
  match kind with
  | "tapBlock" ->
    let* uuid = required_string fields "uuid" in
    Ok (Outliner.Tap_block uuid)
  | "longPressBlock" ->
    let* uuid = required_string fields "uuid" in
    Ok (Outliner.Long_press_block uuid)
  | "textChanged" ->
    let* title = required_string fields "title" in
    let* caret = event_int fields "caretUTF16Offset" in
    Ok
      (Outliner.Text_changed { Outliner.title; caret })
  | "caretMoved" ->
    let* caret = event_int fields "caretUTF16Offset" in
    Ok (Outliner.Caret_moved caret)
  | "returnPressed" ->
    (match
       ( List.assoc_opt "title" fields
       , List.assoc_opt "caretUTF16Offset" fields )
     with
     | Some (`String title), Some (`Int caret) ->
       Ok
         (Outliner.Return_pressed_with_text
            { Outliner.title; caret })
     | None, None -> Ok Outliner.Return_pressed
     | _ ->
       Error "returnPressed requires both title and caretUTF16Offset")
  | "backspacePressed" ->
    let* length = event_int fields "selectionLength" in
    (match List.assoc_opt "title" fields with
     | Some (`String title) ->
       Ok
         (Outliner.Backspace_pressed_with_text
            {
              Outliner.backspace_title = title;
              backspace_selection_length = length;
            })
     | None ->
       Ok
         (Outliner.Backspace_pressed
            { Outliner.selection_length = length })
     | _ -> Error "backspacePressed title must be a string")
  | "toolbar" ->
    let* wire = required_string fields "action" in
    let* action = toolbar_action wire in
    Ok (Outliner.Toolbar action)
  | "dropBlocks" ->
    let* uuid = required_string fields "targetUuid" in
    let* wire = required_string fields "placement" in
    let* placement = drop_placement wire in
    Ok
      (Outliner.Drop_blocks
         { Outliner.target_uuid = uuid; placement })
  | "chooseAutocomplete" ->
    let* value = required_string fields "value" in
    Ok (Outliner.Choose_autocomplete value)
  | "confirmDelete" -> Ok Outliner.Confirm_delete
  | "saveEditing" -> Ok Outliner.Save_editing
  | "cancelEditing" -> Ok Outliner.Cancel_editing
  | "toggleCollapsed" ->
    let* uuid = required_string fields "uuid" in
    Ok (Outliner.Toggle_collapsed uuid)
  | "zoomIn" ->
    let* uuid = required_string fields "uuid" in
    Ok (Outliner.Zoom_in uuid)
  | "zoomOut" -> Ok Outliner.Zoom_out
  | "addRootBlock" ->
    let* uuid = required_string fields "uuid" in
    Ok (Outliner.Add_root_block uuid)
  | "setTaskPriority" ->
    let* uuid = required_string fields "uuid" in
    let* ident = optional_string fields "priorityIdent" in
    let* priority_uuid = optional_string fields "priorityUuid" in
    let priority = match ident, priority_uuid with
      | Some ident, _ -> Ok (Some (Ops.Ref_ident ident))
      | None, Some uuid -> Ok (Some (Ops.Ref_uuid uuid))
      | None, None when List.assoc_opt "priority" fields = Some `Null -> Ok None
      | _ -> Error "setTaskPriority requires a priority reference or explicit null" in
    let* priority = priority in
    Ok (Outliner.Set_task_priority {Outliner.priority_uuid = uuid; priority})
  | "setTaskStatus" ->
    let* uuid = required_string fields "uuid" in
    let* ident = optional_string fields "statusIdent" in
    (match ident with
     | Some ident ->
       Ok
         (Outliner.Set_task_status
            {
              Outliner.status_uuid = uuid;
              status = Ops.Ref_ident ident;
            })
     | None ->
       let* status = optional_string fields "statusUuid" in
       (match status with
        | Some status ->
          Ok
            (Outliner.Set_task_status
               {
                 Outliner.status_uuid = uuid;
                 status = Ops.Ref_uuid status;
               })
        | None -> Error "setTaskStatus requires a status reference"))
  | _ -> Error "unknown outliner event type"

let outliner_message payload =
  try
    match Json.from_string payload with
    | `Assoc fields ->
      (* The wire protocol keeps the first occurrence of duplicate fields. *)
      decode_outliner_event (fields_of fields)
    | _ -> Error "outliner event must be an object"
  with _ -> Error "outliner event must be valid JSON"

let json_strings values =
  `List (List.map (fun value -> `String value) values)

let json_object fields : Json.t = `Assoc fields
let json_list values : Json.t = `List values

let success result =
  Json.to_string
    (json_object
       [
         ("apiVersion", `Int 1)
       ; ("ok", `Bool true)
       ; ("result", result)
       ; ("error", `Null)
       ])

let failure code message =
  Json.to_string
    (json_object
       [
         ("apiVersion", `Int 1)
       ; ("ok", `Bool false)
       ; ("result", `Null)
       ; ( "error"
         , json_object
             [ ("code", `String code); ("message", `String message) ] )
       ])

let graph_creation_payload payload =
  match Json.from_string payload with
  | `Assoc entries ->
    let fields = fields_of entries in
    (match
       ( required_string fields "name"
       , List.assoc_opt "isEncrypted" fields )
     with
     | Ok name, Some (`Bool encrypted) ->
       if String_kit.is_blank name then
         Error ("invalid_params", "Graph name cannot be empty")
       else Ok (String_kit.trim name, encrypted)
     | _ ->
       Error
         ( "invalid_params"
         , "createSyncGraph requires a name and isEncrypted flag" ))
  | _ ->
    Error ("invalid_params", "createSyncGraph payload must be an object")

let graph_creation_response (response : Api.api_response) =
  if response.status >= 200 && response.status <= 299 then
    match Json.from_string response.body with
    | `Assoc entries ->
      (match
         List.assoc_opt "graph-id" (fields_of entries)
       with
       | Some (`String graph_id) -> Ok graph_id
       | _ -> Error "Graph creation returned no graph id")
    | _ -> Error "Graph creation returned no graph id"
  else
    Error
      (if response.body = "" then "Could not create graph"
       else response.body)

let graph_workflow_result code result =
  match result with
  | Ok value -> Ok value
  | Error message -> Error (code, message)

let action_fields action payload =
  try
    match Json.from_string payload with
    | `Assoc entries -> Ok (fields_of entries)
    | _ ->
      Error ("invalid_params", action ^ " payload must be an object")
  with _ ->
    Error ("invalid_json", action ^ " payload must be valid JSON")

let action_response result =
  match result with
  | Ok response -> response
  | Error (code, message) -> failure code message

let required_bool fields name =
  match List.assoc_opt name fields with
  | Some (`Bool value) -> Ok value
  | None -> Error ("missing field: " ^ name)
  | _ -> Error ("field must be a boolean: " ^ name)

let debug message = prerr_endline ("Logseq core " ^ message)

let mark_pending_sync_projection response =
  match Json.from_string response with
  | `Assoc fields when List.assoc_opt "ok" fields = Some (`Bool true) ->
    Json.to_string (`Assoc (List.map (fun (key, value) ->
      if key = "result" then
        (key, match value with
         | `Assoc fields -> `Assoc (("isPendingSyncProjection", `Bool true) :: fields)
         | _ -> value)
      else (key, value)) fields))
  | _ -> response

let route snapshot dispatch (input : Json.t) =
  match input with
  | `Assoc entries ->
    let fields = fields_of entries in
    (match List.assoc_opt "apiVersion" fields with
     | Some (`Int 1) ->
       (match required_string fields "method" with
        | Error message -> failure "invalid_request" message
        | Ok method_ ->
          (match List.assoc_opt "params" fields with
           | Some (`Assoc entries) ->
             (match method_ with
              | "snapshot" | "open" -> snapshot ()
              | "dispatch" ->
                let params = fields_of entries in
                let decoded =
                  let ( let* ) = Result.bind in
                  let* action = required_string params "action" in
                  let* payload = optional_string params "payload" in
                  Ok (action, payload)
                in
                (match decoded with
                 | Ok (action, payload) ->
                   let response = dispatch action payload in
                   let projected =
                     if List.assoc_opt "projection" params = Some (`String "snapshot") then
                       let result = Json.from_string response in
                       (match result with
                        | `Assoc fields when List.assoc_opt "ok" fields = Some (`Bool true) ->
                          (match List.assoc_opt "result" fields with
                           | Some (`Assoc fields) when List.exists (fun (key, value) ->
                               String.starts_with ~prefix:"is" key
                               && String.ends_with ~suffix:"Patch" key && value = `Bool true) fields -> snapshot ()
                           | _ -> response)
                        | _ -> response)
                     else response in
                   if List.mem action ["beginPendingSync"; "completePendingSync"; "cancelPendingSync"]
                   then mark_pending_sync_projection projected else projected
                 | Error message -> failure "invalid_params" message)
              | _ -> failure "unknown_method" ("unknown method: " ^ method_))
           | None -> failure "invalid_request" "missing field: params"
           | _ -> failure "invalid_request" "params must be an object"))
     | Some (`Int _) ->
       failure "unsupported_version" "only API version 1 is supported"
     | None -> failure "invalid_request" "missing field: apiVersion"
     | _ -> failure "invalid_request" "apiVersion must be an integer")
  | _ -> failure "invalid_request" "request must be an object"

let call snapshot dispatch request =
  try route snapshot dispatch (Json.from_string request)
  with _ -> failure "invalid_json" "request must be valid JSON"

let request_json id (request : Api.api_request) file_path content_type
    headers =
  json_object
    ([
       ("id", `Int id)
     ; ("method", `String request.method_)
     ; ("url", `String request.url)
     ; ("token", `String request.token)
     ; ("contentType", `String content_type)
     ; ( "headers"
       , json_object
           (List.map (fun (key, value) -> (key, `String value)) headers) )
     ]
     @ (match request.body with
        | Some body ->
          let fields = [ ("body", `String body) ] in
          (try
             fields @ [ ("bodyObject", Json.from_string body) ]
           with _ -> fields)
        | None -> [])
     @ (match file_path with
        | Some path -> [ ("filePath", `String path) ]
        | None -> []))
