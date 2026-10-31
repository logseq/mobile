module Ds = Datascript
module S = String_kit

type pending_state =
  | Queued
  | Submitted
  | Accepted of int
  | Retryable
  | Applied
  | Conflicted of string

type semantic_value =
  | Nil_value
  | Uuid_value of string
  | Vector_value of semantic_value list
  | Set_value of semantic_value list
  | String_value of string
  | Int_value of int
  | Instant_value of int
  | Float_value of float
  | Bool_value of bool
  | Keyword_value of string
  | Map_value of (string * semantic_value) list
  | Ref_uuid of string
  | Ref_ident of string

let rec semantic_value_from_datascript input =
  let ( let* ) = Result.bind in
  match input with
  | Ds.Nil -> Ok Nil_value
  | Ds.Uuid value -> Ok (Uuid_value value)
  | Ds.Vector values | Ds.Set values ->
    let* converted = List.fold_left (fun result value ->
      let* acc = result in let* value = semantic_value_from_datascript value in Ok (value :: acc)) (Ok []) values in
    Ok (match input with Ds.Set _ -> Set_value (List.rev converted) | _ -> Vector_value (List.rev converted))
  | Ds.String value -> Ok (String_value value)
  | Ds.Int64 value -> Ok (Int_value (Int64.to_int value))
  | Ds.Instant value -> Ok (Instant_value (Int64.to_int value))
  | Ds.Float value -> Ok (Float_value value)
  | Ds.Bool value -> Ok (Bool_value value)
  | Ds.Keyword value -> Ok (Keyword_value value)
  | Ds.Map entries ->
    let* converted =
      List.fold_left
        (fun result (key, native_value) ->
          let* acc = result in
          match key with
          | Ds.Keyword name ->
            let* converted_value =
              semantic_value_from_datascript native_value
            in
            Ok ((name, converted_value) :: acc)
          | _ -> Error "semantic map contains a non-keyword key")
        (Ok []) entries
    in
    Ok (Map_value (List.rev converted))
  | _ -> Error "unsupported semantic value"

type property_change =
  { attr : string
  ; expected : semantic_value option
  ; value : semantic_value option
  }

type pending_move =
  { uuid : string
  ; page_uuid : string
  ; parent_uuid : string
  ; order : string
  }

type pending_title =
  { uuid : string
  ; expected_title : string
  ; title : string
  }

type pending_property =
  { uuid : string
  ; attr : string
  ; expected : semantic_value option
  ; value : semantic_value option
  }

type pending_properties =
  { uuid : string
  ; changes : property_change list
  }

type pending_insert =
  { uuid : string
  ; title : string
  ; page_uuid : string
  ; parent_uuid : string
  ; order : string
  ; created_at : int
  }

type pending_asset =
  { uuid : string
  ; title : string
  ; page_uuid : string
  ; parent_uuid : string
  ; order : string
  ; created_at : int
  ; asset_type : string
  ; asset_size : int
  ; asset_checksum : string
  ; transcript : pending_insert option
  }

type pending_moves =
  { moves : pending_move list
  }

type pending_split =
  { uuid : string
  ; expected_title : string
  ; before : string
  ; after : string
  ; new_uuid : string
  ; new_order : string
  ; created_at : int
  }

type pending_merge =
  { uuid : string
  ; expected_title : string
  ; title : string
  ; previous_uuid : string
  ; expected_previous_title : string
  ; merged_title : string option
  }

type pending_delete =
  { uuids : string list
  }

type pending_create =
  { uuid : string
  ; title : string
  ; created_at : int
  }

type pending_journal =
  { page_uuid : string
  ; block_uuid : string
  ; block_title : string
  ; title : string
  ; journal_day : int
  ; created_at : int
  }

type pending_tag =
  { uuid : string
  ; tag_uuid : string
  }

type pending_favorite =
  { page_uuid : string
  ; favorite_uuid : string
  ; favorite : bool
  ; order : string
  ; created_at : int
  }

type pending_page_delete =
  { page_uuid : string
  ; order : string
  ; deleted_at : int
  }

type pending_property_value =
  { uuid : string
  ; owner_uuid : string
  ; property_ident : string
  ; content : semantic_value
  ; created_at : int
  }

type pending_intent =
  | Atomic of pending_intent list
  | Set_key_value of { key : string; value : semantic_value option }
  | Create_property_value of pending_property_value
  | Save_title of pending_title
  | Set_property of pending_property
  | Set_properties of pending_properties
  | Insert_block of pending_insert
  | Create_asset of pending_asset
  | Move_block of pending_move
  | Move_blocks of pending_moves
  | Split_block of pending_split
  | Merge_backward of pending_merge
  | Delete_blocks of pending_delete
  | Create_tag of pending_create
  | Create_page of pending_create
  | Create_property of pending_create
  | Create_journal of pending_journal
  | Add_tag of pending_tag
  | Set_favorite of pending_favorite
  | Delete_page of pending_page_delete

type pending_operation =
  { operation_id : string
  ; base_t : int
  ; state : pending_state
  ; intent : pending_intent
  }

let raw_title db uuid =
  match Ds.entity db (Ds.Lookup_ref ("block/uuid", Ds.Uuid uuid)) with
  | Some block ->
    (match Ds.entity_attr block "block/title" with
     | Some (Ds.One_value (Ds.String title)) -> Ok title
     | _ -> Error "block title is missing")
  | None -> Error "block no longer exists"

let normalize_expected_title db uuid expected =
  let ( let* ) = Result.bind in
  let* current = raw_title db uuid in
  if current = expected then Ok current
  else Error "title changed on the server"

let rec normalize_fsrs_value attr value =
  match value with
  | Instant_value time ->
    if attr = "logseq.property.fsrs/due" then Int_value time else value
  | Map_value entries ->
    if attr = "logseq.property.fsrs/state" then
      Map_value
        (List.map
           (fun (key, entry) ->
             ( key
             , match entry with
               | Instant_value time ->
                 if key = "last-repeat" then Int_value time else entry
               | _ -> entry ))
           entries)
    else value
  | _ -> value

let normalize_optional_value attr value =
  match value with
  | Some present -> Some (normalize_fsrs_value attr present)
  | None -> None

let normalize_property_change (change : property_change) =
  {
    attr = change.attr;
    expected = normalize_optional_value change.attr change.expected;
    value = normalize_optional_value change.attr change.value;
  }

let rec normalize_operation db operation =
  let ( let* ) = Result.bind in
  let* intent =
    match operation.intent with
    | Atomic intents ->
      let* normalized = List.fold_left (fun result intent ->
        let* acc = result in let* next = normalize_operation db {operation with intent} in
        Ok (next.intent :: acc)) (Ok []) intents in
      Ok (Atomic (List.rev normalized))
    | Save_title value ->
      let* expected =
        normalize_expected_title db value.uuid value.expected_title
      in
      Ok (Save_title { value with expected_title = expected })
    | Split_block value ->
      let* expected =
        normalize_expected_title db value.uuid value.expected_title
      in
      Ok (Split_block { value with expected_title = expected })
    | Merge_backward value ->
      let* expected =
        normalize_expected_title db value.uuid value.expected_title
      in
      let* previous =
        normalize_expected_title db value.previous_uuid
          value.expected_previous_title
      in
      Ok
        (Merge_backward
           {
             value with
             expected_title = expected;
             expected_previous_title = previous;
             merged_title = Some (previous ^ value.title);
           })
    | Set_property value ->
      Ok
        (Set_property
           {
             value with
             expected = normalize_optional_value value.attr value.expected;
             value = normalize_optional_value value.attr value.value;
           })
    | Set_properties value ->
      Ok
        (Set_properties
           { value with changes = List.map normalize_property_change value.changes })
    | other -> Ok other
  in
  Ok { operation with intent }

let subtree_uuids db roots =
  let rec loop pending result =
    match pending with
    | [] -> result
    | uuid :: remaining ->
      let children =
        match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
        | Some eid ->
          List.of_seq
            (Ds.Db.datoms db Ds.Aevt ~a:"block/parent" ~v:(Ds.Ref eid) ())
          |> List.filter_map (fun (datom : Ds.datom) ->
            match
              List.of_seq
                (Ds.Db.datoms db Ds.Eavt ~e:datom.e ~a:"block/uuid" ())
            with
            | identity :: _ ->
              (match identity.Ds.v with
               | Ds.Uuid child -> Some child
               | _ -> None)
            | [] -> None)
        | None -> []
      in
      loop (children @ remaining) (result @ [ uuid ])
  in
  loop roots []

let search_visible_property attr =
  List.mem attr
    [
      "block/title";
      "block/name";
      "block/page";
      "block/parent";
      "block/journal-day";
      "block/refs";
      "logseq.property/built-in?";
      "block/closed-value-property";
      "logseq.property/hide?";
      "logseq.property/deleted-at";
    ]

let rec affected_uuids db intent =
  match intent with
  | Atomic intents -> List.concat_map (affected_uuids db) intents |> List.sort_uniq String.compare
  | Set_key_value _ -> []
  | Set_property value -> if search_visible_property value.attr then [ value.uuid ] else []
  | Set_properties value ->
    if
      List.exists
        (fun (change : property_change) -> search_visible_property change.attr)
        value.changes
    then [ value.uuid ]
    else []
  | Create_property_value value -> [ value.uuid ]
  | Save_title value -> [ value.uuid ]
  | Insert_block value -> [ value.uuid ]
  | Create_asset value -> value.uuid :: (match value.transcript with Some child -> [child.uuid] | None -> [])
  | Move_block value -> [ value.uuid ]
  | Add_tag value -> [ value.uuid ]
  | Create_tag value -> [ value.uuid ]
  | Create_page value | Create_property value -> [ value.uuid ]
  | Move_blocks value -> List.map (fun (move : pending_move) -> move.uuid) value.moves
  | Split_block value -> [ value.uuid; value.new_uuid ]
  | Merge_backward value -> [ value.uuid; value.previous_uuid ]
  | Delete_blocks value -> subtree_uuids db value.uuids
  | Create_journal value -> [ value.page_uuid; value.block_uuid ]
  | Set_favorite value -> [ value.page_uuid; value.favorite_uuid ]
  | Delete_page value -> [ value.page_uuid ]

let rec safe_to_rebase intent =
  match intent with
  | Atomic intents -> List.for_all safe_to_rebase intents
  | Set_key_value _ | Create_property_value _ | Save_title _ | Set_property _ | Set_properties _ | Split_block _
  | Merge_backward _ | Create_tag _ | Create_page _ | Create_property _ | Create_journal _
  | Add_tag _ | Insert_block _ | Create_asset _ | Move_block _ | Move_blocks _
  | Set_favorite _ | Delete_page _ -> true
  | Delete_blocks _ -> false

let inserted_result_exists db intent =
  match intent with
  | Insert_block value ->
    Option.is_some (Ds.entid db "block/uuid" (Ds.Uuid value.uuid))
  | Create_asset value ->
    Option.is_some (Ds.entid db "block/uuid" (Ds.Uuid value.uuid))
    && (match value.transcript with None -> true | Some child ->
      Option.is_some (Ds.entid db "block/uuid" (Ds.Uuid child.uuid)))
  | _ -> false

let split_result_exists db intent =
  match intent with
  | Split_block value ->
    Option.is_some (Ds.entid db "block/uuid" (Ds.Uuid value.new_uuid))
  | _ -> false

let committed_despite_later_changes server_t db operation =
  let intent = operation.intent in
  inserted_result_exists db intent
  ||
  match operation.state with
  | Accepted accepted_t ->
    accepted_t <= server_t && split_result_exists db intent
  | Submitted -> split_result_exists db intent
  | Conflicted "split block UUID already exists" ->
    split_result_exists db intent
  | _ -> false

let store_raw = Graph_sqlite.store_pending
let list_raw = Graph_sqlite.list_pending
let set_state_raw = Graph_sqlite.set_pending_state
let remove_raw = Graph_sqlite.remove_pending

let outliner_op intent =
  match intent with
  | Atomic _ | Set_key_value _ | Create_property_value _ | Save_title _ | Set_property _ | Set_properties _ | Create_tag _
  | Create_page _ | Create_property _ | Add_tag _ -> "save-block"
  | Insert_block _ | Create_asset _ | Create_journal _ -> "insert-blocks"
  | Set_favorite value -> if value.favorite then "insert-blocks" else "delete-blocks"
  | Move_block _ | Move_blocks _ -> "move-blocks"
  | Split_block _ -> "split-block"
  | Merge_backward _ -> "merge-blocks"
  | Delete_blocks _ -> "delete-blocks"
  | Delete_page _ -> "delete-page"

let state_string state =
  match state with
  | Queued -> "queued"
  | Submitted -> "submitted"
  | Accepted cursor -> "accepted:" ^ string_of_int cursor
  | Retryable -> "retryable"
  | Applied -> "applied"
  | Conflicted message -> "conflicted:" ^ message

let state_of_string value =
  if value = "queued" then Queued
  else if value = "submitted" then Submitted
  else if S.starts_with ~prefix:"accepted:" value then
    match int_of_string_opt (String.sub value 9 (String.length value - 9)) with
    | Some cursor -> Accepted cursor
    | None -> Retryable
  else if value = "accepted" then Submitted
  else if value = "applied" then Applied
  else if S.starts_with ~prefix:"conflicted:" value then
    Conflicted (String.sub value 11 (String.length value - 11))
  else Retryable

let json_object entries = `Assoc entries
let json_array values = `List values

let option_json f value =
  match value with Some value -> f value | None -> `Null

let option_value f value =
  match value with `Null -> None | _ -> Some (f value)

let rec semantic_value_json value =
  let kind, value =
    match value with
    | Nil_value -> ("nil", `Null)
    | Uuid_value value -> ("uuid", `String value)
    | Vector_value values -> ("vector", `List (List.map semantic_value_json values))
    | Set_value values -> ("set", `List (List.map semantic_value_json values))
    | String_value value -> ("string", `String value)
    | Int_value value -> ("int", `Int value)
    | Instant_value value -> ("instant", `Int value)
    | Float_value value -> ("float", `Float value)
    | Bool_value value -> ("bool", `Bool value)
    | Keyword_value value -> ("keyword", `String value)
    | Ref_uuid value -> ("ref-uuid", `String value)
    | Ref_ident value -> ("ref-ident", `String value)
    | Map_value entries ->
      ( "map"
      , json_array
          (List.map
             (fun (key, value) ->
               json_object
                 [ ("key", `String key); ("value", semantic_value_json value) ])
             entries) )
  in
  json_object [ ("type", `String kind); ("value", value) ]

let object_fields input message =
  match input with
  | `Assoc _ -> Yojson.Basic.Util.to_assoc input
  | _ -> invalid_arg message

let rec semantic_value_of_json input =
  match object_fields input "invalid pending semantic value" with
  | [ ("type", `String kind); ("value", value) ] ->
    (match (kind, value) with
     | "nil", `Null -> Nil_value
     | "uuid", `String value -> Uuid_value value
     | "vector", `List values -> Vector_value (List.map semantic_value_of_json values)
     | "set", `List values -> Set_value (List.map semantic_value_of_json values)
     | "string", `String value -> String_value value
     | "int", `Int value -> Int_value value
     | "instant", `Int value -> Instant_value value
     | "float", `Float value -> Float_value value
     | "float", `Int value -> Float_value (float_of_int value)
     | "bool", `Bool value -> Bool_value value
     | "keyword", `String value -> Keyword_value value
     | "ref-uuid", `String value -> Ref_uuid value
     | "ref-ident", `String value -> Ref_ident value
     | "map", `List entries ->
       Map_value
         (List.map
            (fun entry ->
              match object_fields entry "invalid pending semantic map entry" with
              | [ ("key", `String key); ("value", value) ] ->
                (key, semantic_value_of_json value)
              | _ -> invalid_arg "invalid pending semantic map entry")
            entries)
     | _ -> invalid_arg "invalid pending semantic value")
  | _ -> invalid_arg "invalid pending semantic value"

let field fields key =
  List.find_map
    (fun (name, value) -> if name = key then Some value else None)
    fields

let required_field fields key =
  match field fields key with
  | Some value -> value
  | None -> raise Not_found

let string_field fields key =
  match field fields key with
  | Some (`String value) -> value
  | _ -> invalid_arg ("invalid pending intent field: " ^ key)

let int_field fields key =
  match field fields key with
  | Some (`Int value) -> value
  | _ -> invalid_arg ("invalid pending intent field: " ^ key)

let bool_field fields key =
  match field fields key with
  | Some (`Bool value) -> value
  | _ -> invalid_arg ("invalid pending intent field: " ^ key)

let array_field fields key =
  match field fields key with
  | Some (`List values) -> values
  | _ -> invalid_arg ("invalid pending intent field: " ^ key)

let semantic_field fields key =
  option_value semantic_value_of_json (required_field fields key)

let move_json (value : pending_move) =
  json_object
    [
      ("uuid", `String value.uuid);
      ("pageUuid", `String value.page_uuid);
      ("parentUuid", `String value.parent_uuid);
      ("order", `String value.order);
    ]

let move_of_json input =
  let fields = object_fields input "invalid pending move" in
  {
    uuid = string_field fields "uuid";
    page_uuid = string_field fields "pageUuid";
    parent_uuid = string_field fields "parentUuid";
    order = string_field fields "order";
  }

let change_json (value : property_change) =
  json_object
    [
      ("attr", `String value.attr);
      ("expected", option_json semantic_value_json value.expected);
      ("value", option_json semantic_value_json value.value);
    ]

let change_of_json input =
  let fields = object_fields input "invalid pending property change" in
  {
    attr = string_field fields "attr";
    expected = semantic_field fields "expected";
    value = semantic_field fields "value";
  }

let creation_fields (value : pending_create) =
  [
    ("uuid", `String value.uuid);
    ("title", `String value.title);
    ("createdAt", `Int value.created_at);
  ]

let insert_fields (value : pending_insert) =
  [
    ("uuid", `String value.uuid);
    ("title", `String value.title);
    ("pageUuid", `String value.page_uuid);
    ("parentUuid", `String value.parent_uuid);
    ("order", `String value.order);
    ("createdAt", `Int value.created_at);
  ]

let rec intent_json intent =
  let kind, fields =
    match intent with
    | Atomic intents -> ("atomic", ["intents", `List (List.map intent_json intents)])
    | Set_key_value {key; value} -> ("set-key-value", ["key", `String key; "value", option_json semantic_value_json value])
    | Create_property_value value -> ("create-property-value", [
        "uuid", `String value.uuid; "ownerUuid", `String value.owner_uuid;
        "propertyIdent", `String value.property_ident; "content", semantic_value_json value.content;
        "createdAt", `Int value.created_at])
    | Save_title value ->
      ( "save-title"
      , [
          ("uuid", `String value.uuid);
          ("expectedTitle", `String value.expected_title);
          ("title", `String value.title);
        ] )
    | Set_property value ->
      ( "set-property"
      , [
          ("uuid", `String value.uuid);
          ("attr", `String value.attr);
          ("expected", option_json semantic_value_json value.expected);
          ("value", option_json semantic_value_json value.value);
        ] )
    | Set_properties value ->
      ( "set-properties"
      , [
          ("uuid", `String value.uuid);
          ("changes", json_array (List.map change_json value.changes));
        ] )
    | Insert_block value -> ("insert-block", insert_fields value)
    | Create_asset value ->
      ( "create-asset"
      , [
          ("uuid", `String value.uuid);
          ("title", `String value.title);
          ("pageUuid", `String value.page_uuid);
          ("parentUuid", `String value.parent_uuid);
          ("order", `String value.order);
          ("createdAt", `Int value.created_at);
          ("assetType", `String value.asset_type);
          ("assetSize", `Int value.asset_size);
          ("assetChecksum", `String value.asset_checksum);
        ] @ (match value.transcript with None -> [] | Some child -> ["transcript", json_object (insert_fields child)]) )
    | Move_block value ->
      ( "move-block"
      , [
          ("uuid", `String value.uuid);
          ("pageUuid", `String value.page_uuid);
          ("parentUuid", `String value.parent_uuid);
          ("order", `String value.order);
        ] )
    | Move_blocks value ->
      ("move-blocks", [ ("moves", json_array (List.map move_json value.moves)) ])
    | Split_block value ->
      ( "split-block"
      , [
          ("uuid", `String value.uuid);
          ("expectedTitle", `String value.expected_title);
          ("before", `String value.before);
          ("after", `String value.after);
          ("newUuid", `String value.new_uuid);
          ("newOrder", `String value.new_order);
          ("createdAt", `Int value.created_at);
        ] )
    | Merge_backward value ->
      ( "merge-backward"
      , [
          ("uuid", `String value.uuid);
          ("expectedTitle", `String value.expected_title);
          ("title", `String value.title);
          ("previousUuid", `String value.previous_uuid);
          ("expectedPreviousTitle", `String value.expected_previous_title);
          ("mergedTitle", option_json (fun value -> `String value) value.merged_title);
        ] )
    | Delete_blocks value ->
      ( "delete-blocks"
      , [
          ( "uuids"
          , json_array (List.map (fun uuid -> `String uuid) value.uuids) );
        ] )
    | Create_tag value -> ("create-tag", creation_fields value)
    | Create_page value -> ("create-page", creation_fields value)
    | Create_property value -> ("create-property", creation_fields value)
    | Create_journal value ->
      ( "create-journal"
      , [
          ("pageUuid", `String value.page_uuid);
          ("blockUuid", `String value.block_uuid);
          ("title", `String value.title);
          ("journalDay", `Int value.journal_day);
          ("createdAt", `Int value.created_at);
        ] @ (if value.block_title = "" then [] else ["blockTitle", `String value.block_title]) )
    | Add_tag value ->
      ( "add-tag"
      , [
          ("uuid", `String value.uuid);
          ("tagUuid", `String value.tag_uuid);
        ] )
    | Set_favorite value ->
      ( "set-favorite"
      , [
          ("pageUuid", `String value.page_uuid);
          ("favoriteUuid", `String value.favorite_uuid);
          ("favorite", `Bool value.favorite);
          ("order", `String value.order);
          ("createdAt", `Int value.created_at);
        ] )
    | Delete_page value ->
      ( "delete-page"
      , [
          ("pageUuid", `String value.page_uuid);
          ("order", `String value.order);
          ("deletedAt", `Int value.deleted_at);
        ] )
  in
  json_object ([ ("type", `String kind) ] @ fields)

let create_of_fields fields =
  {
    uuid = string_field fields "uuid";
    title = string_field fields "title";
    created_at = int_field fields "createdAt";
  }

let merged_title fields =
  match field fields "mergedTitle" with
  | Some (`String value) -> Some value
  | Some `Null -> None
  | None -> None
  | _ -> invalid_arg "invalid pending intent field: mergedTitle"

let rec intent_of_json input =
  let fields = object_fields input "pending intent must be an object" in
  match string_field fields "type" with
  | "atomic" -> Atomic (List.map intent_of_json (array_field fields "intents"))
  | "set-key-value" -> Set_key_value {key = string_field fields "key"; value = semantic_field fields "value"}
  | "save-title" ->
    Save_title
      {
        uuid = string_field fields "uuid";
        expected_title = string_field fields "expectedTitle";
        title = string_field fields "title";
      }
  | "set-property" ->
    Set_property
      {
        uuid = string_field fields "uuid";
        attr = string_field fields "attr";
        expected = semantic_field fields "expected";
        value = semantic_field fields "value";
      }
  | "set-properties" ->
    Set_properties
      {
        uuid = string_field fields "uuid";
        changes = List.map change_of_json (array_field fields "changes");
      }
  | "create-property-value" ->
    Create_property_value {uuid = string_field fields "uuid";
      owner_uuid = string_field fields "ownerUuid"; property_ident = string_field fields "propertyIdent";
      content = semantic_value_of_json (Option.get (field fields "content"));
      created_at = int_field fields "createdAt"}
  | "insert-block" ->
    Insert_block
      {
        uuid = string_field fields "uuid";
        title = string_field fields "title";
        page_uuid = string_field fields "pageUuid";
        parent_uuid = string_field fields "parentUuid";
        order = string_field fields "order";
        created_at = int_field fields "createdAt";
      }
  | "create-asset" ->
    Create_asset
      {
        uuid = string_field fields "uuid";
        title = string_field fields "title";
        page_uuid = string_field fields "pageUuid";
        parent_uuid = string_field fields "parentUuid";
        order = string_field fields "order";
        created_at = int_field fields "createdAt";
        asset_type = string_field fields "assetType";
        asset_size = int_field fields "assetSize";
        asset_checksum = string_field fields "assetChecksum";
        transcript = (match field fields "transcript" with
          | None | Some `Null -> None
          | Some input ->
            let child = object_fields input "asset transcript must be an object" in
            Some { uuid = string_field child "uuid"; title = string_field child "title";
              page_uuid = string_field child "pageUuid"; parent_uuid = string_field child "parentUuid";
              order = string_field child "order"; created_at = int_field child "createdAt" });
      }
  | "move-block" -> Move_block (move_of_json input)
  | "move-blocks" ->
    Move_blocks { moves = List.map move_of_json (array_field fields "moves") }
  | "split-block" ->
    Split_block
      {
        uuid = string_field fields "uuid";
        expected_title = string_field fields "expectedTitle";
        before = string_field fields "before";
        after = string_field fields "after";
        new_uuid = string_field fields "newUuid";
        new_order = string_field fields "newOrder";
        created_at = int_field fields "createdAt";
      }
  | "merge-backward" ->
    Merge_backward
      {
        uuid = string_field fields "uuid";
        expected_title = string_field fields "expectedTitle";
        title = string_field fields "title";
        previous_uuid = string_field fields "previousUuid";
        expected_previous_title = string_field fields "expectedPreviousTitle";
        merged_title = merged_title fields;
      }
  | "delete-blocks" ->
    Delete_blocks
      {
        uuids =
          List.map
            (fun value ->
              match value with
              | `String uuid -> uuid
              | _ -> invalid_arg "invalid pending delete uuid")
            (array_field fields "uuids");
      }
  | "create-tag" -> Create_tag (create_of_fields fields)
  | "create-page" -> Create_page (create_of_fields fields)
  | "create-property" -> Create_property (create_of_fields fields)
  | "create-journal" ->
    Create_journal
      {
        page_uuid = string_field fields "pageUuid";
        block_uuid = string_field fields "blockUuid";
        block_title = (match List.assoc_opt "blockTitle" fields with Some (`String title) -> title | _ -> "");
        title = string_field fields "title";
        journal_day = int_field fields "journalDay";
        created_at = int_field fields "createdAt";
      }
  | "add-tag" ->
    Add_tag
      {
        uuid = string_field fields "uuid";
        tag_uuid = string_field fields "tagUuid";
      }
  | "set-favorite" ->
    Set_favorite
      {
        page_uuid = string_field fields "pageUuid";
        favorite_uuid = string_field fields "favoriteUuid";
        favorite = bool_field fields "favorite";
        order = string_field fields "order";
        created_at = int_field fields "createdAt";
      }
  | "delete-page" ->
    Delete_page
      {
        page_uuid = string_field fields "pageUuid";
        order = string_field fields "order";
        deleted_at = int_field fields "deletedAt";
      }
  | kind -> invalid_arg ("unknown pending intent: " ^ kind)

let save path operation =
  store_raw path operation.operation_id operation.base_t
    (state_string operation.state)
    (Yojson.Basic.to_string (intent_json operation.intent))

let list path =
  List.map
    (fun (id, cursor, state, intent) ->
      {
        operation_id = id;
        base_t = cursor;
        state = state_of_string state;
        intent = intent_of_json (Yojson.Basic.from_string intent);
      })
    (list_raw path)

let set_state path operation_id state =
  set_state_raw path operation_id (state_string state)

let remove path operation_id = remove_raw path operation_id

let confirm path operation_ids =
  List.iter (fun operation_id -> remove path operation_id) operation_ids
