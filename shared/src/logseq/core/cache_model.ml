module Ds = Datascript

type entity_summary =
  { uuid : string
  ; title : string
  }

type status =
  { uuid : string
  ; ident : string option
  ; title : string
  ; icon_type : string option
  ; icon_id : string option
  ; icon_color : string option
  }

type block =
  { uuid : string
  ; title : string
  ; page_id : string
  ; parent_id : string option
  ; order : string option
  ; created_at : int
  ; updated_at : int
  ; sync_status : string
  ; tags : entity_summary list
  ; references : entity_summary list
  ; breadcrumbs : entity_summary list
  ; priority : status option
  ; status : status option
  ; is_asset : bool
  ; asset_type : string option
  ; asset_size : int option
  ; asset_checksum : string option
  ; local_path : string option
  ; journal : (string * int) option
  }

type model_caches =
  { cache_revision : int ref
  ; cached_blocks : (string, block option) Hashtbl.t
  ; cached_journals : (string, (string * int) option) Hashtbl.t
  }

type model =
  { mutable db : Ds.db
  ; mutable selected_block_uuid : string option
  ; mutable last_refresh_at : int option
  ; mutable revision : int
  ; caches : model_caches
  }

type 'a attribute =
  { attr_name : string
  ; attr_spec : Ds.schema_attr
  ; attr_encode : 'a -> Ds.value
  ; attr_decode : Ds.value -> 'a
  }

let one value_type indexed unique =
  {
    Ds.cardinality = Ds.One;
    unique;
    indexed;
    is_component = false;
    no_history = false;
    doc = None;
    value_type = Some value_type;
    tuple_attrs = None;
    tuple_types = None;
  }

let string_decode = function Ds.String value -> value | _ -> failwith "expected string"
let int_decode = function Ds.Int64 value -> Int64.to_int value | _ -> failwith "expected int"

let text_attribute name indexed =
  { attr_name = name
  ; attr_spec = one Ds.StringType indexed None
  ; attr_encode = (fun value -> Ds.String value)
  ; attr_decode = string_decode
  }

let number_attribute name indexed =
  { attr_name = name
  ; attr_spec = one Ds.NumberType indexed None
  ; attr_encode = (fun value -> Ds.Int64 (Int64.of_int value))
  ; attr_decode = int_decode
  }

let block_uuid =
  {
    attr_name = "block/uuid";
    attr_spec = one Ds.StringType true (Some Ds.Identity);
    attr_encode = (fun value -> Ds.String value);
    attr_decode = string_decode;
  }

let block_title = text_attribute "block/title" false
let block_page_id = text_attribute "block/page-id" true
let block_parent_id = text_attribute "block/parent-id" false
let block_order = text_attribute "block/order" true
let block_created_at = number_attribute "block/created-at" true
let block_updated_at = number_attribute "block/updated-at" true
let block_sync_status = text_attribute "block/sync-status" true
let block_tags_json = text_attribute "block/tags-json" false
let block_references_json = text_attribute "block/references-json" false
let block_breadcrumbs_json = text_attribute "block/breadcrumbs-json" false
let block_priority_json = text_attribute "block/priority-json" false
let block_status_json = text_attribute "block/status-json" false
let block_asset_type = text_attribute "block/asset-type" true
let block_asset_size = number_attribute "block/asset-size" false
let block_asset_checksum = text_attribute "block/asset-checksum" false
let block_local_path = text_attribute "block/local-path" false
let page_journal_day = number_attribute "page/journal-day" true
let page_title = text_attribute "page/title" false

let schema =
  [
    (block_uuid.attr_name, block_uuid.attr_spec);
    (block_title.attr_name, block_title.attr_spec);
    (block_page_id.attr_name, block_page_id.attr_spec);
    (block_parent_id.attr_name, block_parent_id.attr_spec);
    (block_order.attr_name, block_order.attr_spec);
    (block_created_at.attr_name, block_created_at.attr_spec);
    (block_updated_at.attr_name, block_updated_at.attr_spec);
    (block_sync_status.attr_name, block_sync_status.attr_spec);
    (block_tags_json.attr_name, block_tags_json.attr_spec);
    (block_references_json.attr_name, block_references_json.attr_spec);
    (block_breadcrumbs_json.attr_name, block_breadcrumbs_json.attr_spec);
    (block_priority_json.attr_name, block_priority_json.attr_spec);
    (block_status_json.attr_name, block_status_json.attr_spec);
    (block_asset_type.attr_name, block_asset_type.attr_spec);
    (block_asset_size.attr_name, block_asset_size.attr_spec);
    (block_asset_checksum.attr_name, block_asset_checksum.attr_spec);
    (block_local_path.attr_name, block_local_path.attr_spec);
    (page_journal_day.attr_name, page_journal_day.attr_spec);
    (page_title.attr_name, page_title.attr_spec);
  ]

let add attribute entity value =
  Ds.Add (entity, attribute.attr_name, attribute.attr_encode value)

let read attribute entity =
  match entity with
  | Some entity ->
    (match Ds.entity_attr entity attribute.attr_name with
     | Some (Ds.One_value value) -> Some (attribute.attr_decode value)
     | _ -> None)
  | None -> None

let block_ref uuid = Ds.Lookup_ref ("block/uuid", Ds.String uuid)

let create storage =
  let db =
    match storage with
    | Some storage ->
      (match Ds.restore storage with
       | Some db -> db
       | None ->
         let db = Ds.empty_db ~schema ~storage () in
         Ds.store ~storage db)
    | None -> Ds.empty_db ~schema ()
  in
  {
    db;
    selected_block_uuid = None;
    last_refresh_at = None;
    revision = 0;
    caches =
      {
        cache_revision = ref (-1);
        cached_blocks = Hashtbl.create 64;
        cached_journals = Hashtbl.create 16;
      };
  }

let summaries_json summaries =
  Yojson.Basic.to_string
    (`List
       (List.map
          (fun (summary : entity_summary) ->
            `Assoc
              [ ("uuid", `String summary.uuid); ("title", `String summary.title) ])
          summaries))

let json_string fields key =
  match List.assoc_opt key fields with
  | Some (`String value) -> Some value
  | _ -> None

let summaries_of_json source =
  try
    match Yojson.Basic.from_string source with
    | `List values ->
      List.filter_map
        (fun value ->
          match value with
          | `Assoc entries ->
            (match (json_string entries "uuid", json_string entries "title") with
             | Some uuid, Some title ->
               Some ({ uuid; title } : entity_summary)
             | _ -> None)
          | _ -> None)
        values
    | _ -> []
  with _ -> []

let status_json (status : status) =
  let optional =
    List.filter_map
      (fun (key, value) ->
        match value with Some value -> Some (key, `String value) | None -> None)
      [
        ("ident", status.ident);
        ("icon-type", status.icon_type);
        ("icon-id", status.icon_id);
        ("icon-color", status.icon_color);
      ]
  in
  Yojson.Basic.to_string
    (`Assoc
       ([ ("uuid", `String status.uuid); ("title", `String status.title) ]
       @ optional))

let status_of_json source =
  try
    match Yojson.Basic.from_string source with
    | `Assoc entries ->
      (match (json_string entries "uuid", json_string entries "title") with
       | Some uuid, Some title ->
         Some
           ({
             uuid;
             title;
             ident = json_string entries "ident";
             icon_type = json_string entries "icon-type";
             icon_id = json_string entries "icon-id";
             icon_color = json_string entries "icon-color";
           } : status)
       | _ -> None)
    | _ -> None
  with _ -> None

let block_exists model uuid =
  Option.is_some (read block_uuid (Ds.entity model.db (block_ref uuid)))

let ensure_cache_revision model =
  let caches = model.caches in
  if !(caches.cache_revision) <> model.revision then (
    caches.cache_revision := model.revision;
    Hashtbl.reset caches.cached_blocks;
    Hashtbl.reset caches.cached_journals)

let materialize_block model uuid =
  let entity = Ds.entity model.db (block_ref uuid) in
  match read block_uuid entity with
  | None -> None
  | Some uuid ->
    let asset_type = read block_asset_type entity in
    Some
      {
        uuid;
        title = Option.value ~default:"" (read block_title entity);
        page_id = Option.value ~default:"" (read block_page_id entity);
        parent_id = read block_parent_id entity;
        order = read block_order entity;
        created_at = Option.value ~default:0 (read block_created_at entity);
        updated_at = Option.value ~default:0 (read block_updated_at entity);
        sync_status =
          Option.value ~default:"synced" (read block_sync_status entity);
        tags =
          summaries_of_json
            (Option.value ~default:"[]" (read block_tags_json entity));
        references =
          summaries_of_json
            (Option.value ~default:"[]" (read block_references_json entity));
        breadcrumbs =
          summaries_of_json
            (Option.value ~default:"[]" (read block_breadcrumbs_json entity));
        priority = Option.bind (read block_priority_json entity) status_of_json;
        status =
          Option.bind (read block_status_json entity) status_of_json;
        is_asset = Option.is_some asset_type;
        asset_type;
        asset_size = read block_asset_size entity;
        asset_checksum = read block_asset_checksum entity;
        local_path = read block_local_path entity;
        journal = None;
      }

let read_block model uuid =
  ensure_cache_revision model;
  match Hashtbl.find_opt model.caches.cached_blocks uuid with
  | Some cached -> cached
  | None ->
    let block = materialize_block model uuid in
    Hashtbl.replace model.caches.cached_blocks uuid block;
    block

let journal_metadata model page_id =
  ensure_cache_revision model;
  match Hashtbl.find_opt model.caches.cached_journals page_id with
  | Some cached -> cached
  | None ->
    let entity = Ds.entity model.db (block_ref page_id) in
    let day = Option.value ~default:0 (read page_journal_day entity) in
    let metadata =
      if day > 0 then
        Some (Option.value ~default:"" (read page_title entity), day)
      else None
    in
    Hashtbl.replace model.caches.cached_journals page_id metadata;
    metadata

let all_block_uuids model =
  List.of_seq (Ds.Db.datoms model.db Ds.Aevt ~a:"block/uuid" ())
  |> List.filter_map (fun (datom : Ds.datom) ->
    match datom.v with Ds.String uuid -> Some uuid | _ -> None)

let all_blocks model =
  List.filter_map (fun uuid -> read_block model uuid) (all_block_uuids model)

let all_statuses model =
  List.filter_map
    (fun uuid ->
      if
        String.length uuid > 15
        && String_kit.starts_with ~prefix:"status-catalog/" uuid
      then
        match read_block model uuid with
        | Some block -> block.status
        | None -> None
      else None)
    (all_block_uuids model)

let local_time now = Unix.localtime (float_of_int now /. 1000.0)

let journal_day_for_ms now =
  let tm = local_time now in
  ((tm.Unix.tm_year + 1900) * 10000) + ((tm.Unix.tm_mon + 1) * 100) + tm.Unix.tm_mday

let journal_page_id_for_ms now =
  let tm = local_time now in
  Printf.sprintf "journal/%04d-%02d-%02d" (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1) tm.Unix.tm_mday

let block_journal_metadata model block =
  match block.journal with
  | Some journal -> Some journal
  | None -> journal_metadata model block.page_id

let journal_feed_block model block =
  block.page_id <> ""
  &&
  match block_journal_metadata model block with
  | Some (_, day) ->
    day <= journal_day_for_ms (int_of_float (Unix.gettimeofday () *. 1000.0))
  | None -> false

let recent_feed_block model block =
  String_kit.trim block.title <> "" && journal_feed_block model block

let compare_recent left right =
  let order = compare right.created_at left.created_at in
  if order = 0 then compare left.uuid right.uuid else order

let compare_outliner left right =
  match (left.order, right.order) with
  | Some left_order, Some right_order ->
    let order = compare left_order right_order in
    if order = 0 then compare left.uuid right.uuid else order
  | Some _, None -> -1
  | None, Some _ -> 1
  | None, None ->
    let order = compare left.created_at right.created_at in
    if order = 0 then compare left.uuid right.uuid else order

let outliner_preorder page_id blocks =
  let by_uuid = Hashtbl.create 16 in
  List.iter (fun block -> Hashtbl.replace by_uuid block.uuid block) blocks;
  let children = Hashtbl.create 16 in
  List.iter
    (fun block ->
      let parent =
        match block.parent_id with
        | Some parent ->
          if Hashtbl.mem by_uuid parent || parent = page_id then parent
          else page_id
        | None -> page_id
      in
      let siblings =
        match Hashtbl.find_opt children parent with
        | Some siblings -> siblings
        | None -> []
      in
      Hashtbl.replace children parent (block :: siblings))
    blocks;
  let children_of id =
    match Hashtbl.find_opt children id with
    | Some siblings -> List.rev siblings
    | None -> []
  in
  let seen = Hashtbl.create 16 in
  let rec loop pending ordered =
    match pending with
    | [] ->
      List.rev ordered
      @ List.sort compare_outliner
          (List.filter (fun block -> not (Hashtbl.mem seen block.uuid)) blocks)
    | block :: rest ->
      if Hashtbl.mem seen block.uuid then loop rest ordered
      else (
        Hashtbl.replace seen block.uuid ();
        loop
          (List.sort compare_outliner (children_of block.uuid) @ rest)
          (block :: ordered))
  in
  loop (List.sort compare_outliner (children_of page_id)) []

let journal_blocks include_empty model blocks =
  let groups = Hashtbl.create 16 in
  let page_ids = ref [] in
  List.iter
    (fun block ->
      if
        if include_empty then journal_feed_block model block
        else recent_feed_block model block
      then (
        let siblings =
          match Hashtbl.find_opt groups block.page_id with
          | Some siblings -> siblings
          | None ->
            page_ids := block.page_id :: !page_ids;
            []
        in
        Hashtbl.replace groups block.page_id (block :: siblings)))
    blocks;
  let day_of page_id siblings =
    let journal =
      match siblings with
      | block :: _ -> block_journal_metadata model block
      | [] -> journal_metadata model page_id
    in
    match journal with Some (_, day) -> day | None -> 0
  in
  let groups =
    List.map
      (fun page_id -> (page_id, List.rev (Hashtbl.find groups page_id)))
      (List.sort_uniq compare !page_ids)
  in
  let sorted =
    List.sort
      (fun (left_page, left_blocks) (right_page, right_blocks) ->
        let order = compare (day_of left_page left_blocks) (day_of right_page right_blocks) in
        if order = 0 then compare left_page right_page else order)
      groups
  in
  List.concat_map (fun (page_id, blocks) -> outliner_preorder page_id blocks) sorted

let recent_blocks model =
  journal_blocks false model
    (all_blocks model
    |> List.filter (fun block -> recent_feed_block model block)
    |> List.sort compare_recent
    |> fun blocks ->
    let rec take count items =
      match items with
      | [] -> []
      | item :: rest -> if count = 0 then [] else item :: take (count - 1) rest
    in
    take 100 blocks)

let visible_blocks model = recent_blocks model

let visible_from model blocks =
  journal_blocks true model
    (blocks
    |> List.filter (fun block -> journal_feed_block model block)
    |> List.sort compare_recent
    |> fun items ->
    let rec take count items =
      match items with
      | [] -> []
      | item :: rest -> if count = 0 then [] else item :: take (count - 1) rest
    in
    take 100 items)

let selected_block model =
  match model.selected_block_uuid with
  | Some uuid -> read_block model uuid
  | None -> None

let commit model transactions =
  let report = Ds.transact model.db transactions in
  model.db <- report.Ds.db_after;
  model.revision <- model.revision + 1;
  (match Ds.storage model.db with
   | Some storage -> ignore (Ds.store ~storage model.db)
   | None -> ());
  ()

let upsert_statuses model statuses =
  let transactions =
    List.concat_map
      (fun (status : status) ->
        let uuid = "status-catalog/" ^ status.uuid in
        let entity =
          if block_exists model uuid then block_ref uuid
          else Ds.Temp_id ("status-" ^ status.uuid)
        in
        [
          add block_uuid entity uuid;
          add block_title entity "";
          add block_page_id entity "";
          add block_created_at entity 0;
          add block_updated_at entity 0;
          add block_sync_status entity "synced";
          add block_status_json entity (status_json status);
        ])
      statuses
  in
  if transactions <> [] then commit model transactions;
  ()

let prefer_local_asset local remote =
  {
    remote with
    is_asset = local.is_asset || remote.is_asset;
    asset_type =
      (match local.asset_type with Some v -> Some v | None -> remote.asset_type);
    asset_size =
      (match local.asset_size with Some v -> Some v | None -> remote.asset_size);
    asset_checksum =
      (match local.asset_checksum with
       | Some v -> Some v
       | None -> remote.asset_checksum);
    local_path =
      (match local.local_path with Some v -> Some v | None -> remote.local_path);
  }

let block_transactions model incoming =
  let existing = read_block model incoming.uuid in
  let block =
    match existing with
    | Some existing ->
      if existing.sync_status <> "synced" && incoming.sync_status = "synced"
      then existing
      else if Option.is_some existing.local_path && incoming.local_path = None
      then prefer_local_asset existing incoming
      else incoming
    | None -> incoming
  in
  let entity =
    match existing with
    | Some _ -> block_ref block.uuid
    | None -> Ds.Temp_id ("block-" ^ block.uuid)
  in
  let created_at =
    if block.created_at > 0 then block.created_at
    else match existing with Some existing -> existing.created_at | None -> 0
  in
  let updated_at =
    if block.updated_at > 0 then block.updated_at
    else
      match existing with
      | Some existing -> existing.updated_at
      | None -> created_at
  in
  let page_id =
    if block.page_id <> "" then block.page_id
    else match existing with Some existing -> existing.page_id | None -> ""
  in
  let order =
    match block.order with
    | Some _ -> block.order
    | None -> (match existing with Some existing -> existing.order | None -> None)
  in
  let optional =
    List.filter_map Fun.id
      [
        (match block.priority with
         | Some priority -> Some (add block_priority_json entity (status_json priority))
         | None ->
           Option.bind existing (fun previous ->
             Option.map (fun priority -> Ds.Retract (entity, block_priority_json.attr_name,
               Some (Ds.String (status_json priority)))) previous.priority));
        (match block.status with
         | Some status -> Some (add block_status_json entity (status_json status))
         | None -> None);
        (match block.asset_type with
         | Some value -> Some (add block_asset_type entity value)
         | None -> None);
        (match block.asset_size with
         | Some value -> Some (add block_asset_size entity value)
         | None -> None);
        (match block.asset_checksum with
         | Some value -> Some (add block_asset_checksum entity value)
         | None -> None);
        (match block.local_path with
         | Some value -> Some (add block_local_path entity value)
         | None -> None);
        (match order with
         | Some value -> Some (add block_order entity value)
         | None -> None);
        (match block.parent_id with
         | Some value -> Some (add block_parent_id entity value)
         | None -> None);
      ]
  in
  [
    add block_uuid entity block.uuid;
    add block_title entity block.title;
    add block_page_id entity page_id;
    add block_created_at entity created_at;
    add block_updated_at entity updated_at;
    add block_sync_status entity block.sync_status;
    add block_tags_json entity (summaries_json block.tags);
    add block_references_json entity (summaries_json block.references);
    add block_breadcrumbs_json entity (summaries_json block.breadcrumbs);
  ]
  @ optional

let upsert_blocks model blocks refresh_time =
  let transactions =
    List.concat_map (fun block -> block_transactions model block) blocks
  in
  if transactions <> [] then commit model transactions;
  model.last_refresh_at <- Some refresh_time;
  ()

let select model uuid =
  if block_exists model uuid then (
    model.selected_block_uuid <- Some uuid;
    Ok ())
  else Error ("unknown block: " ^ uuid)

let clear_selection model = model.selected_block_uuid <- None

let upsert_journal_page model uuid day title =
  let entity =
    if block_exists model uuid then block_ref uuid
    else Ds.Temp_id ("page-" ^ uuid)
  in
  commit model
    [
      add block_uuid entity uuid;
      add page_journal_day entity day;
      add page_title entity title;
    ]

let local_block uuid title page_id parent_id now =
  {
    uuid;
    title;
    page_id;
    parent_id;
    order = None;
    created_at = now;
    updated_at = now;
    sync_status = "pending";
    tags = [];
    references = [];
    breadcrumbs = [];
    priority = None;
    status = None;
    is_asset = false;
    asset_type = None;
    asset_size = None;
    asset_checksum = None;
    local_path = None;
    journal = None;
  }

let local_journal model now =
  let page_id = journal_page_id_for_ms now in
  upsert_journal_page model page_id (journal_day_for_ms now) "";
  page_id

let cache_local_message model uuid title now =
  upsert_blocks model [ local_block uuid title (local_journal model now) None now ] now

let cache_local_task model uuid title status now =
  upsert_blocks model
    [
      {
        (local_block uuid title (local_journal model now) None now) with
        status = Some status;
      };
    ]
    now

let cache_local_asset model uuid title asset_type asset_size asset_checksum
    local_path now target_block_id =
  let target =
    match target_block_id with
    | Some uuid -> read_block model uuid
    | None -> None
  in
  let page_id =
    match target with
    | Some target -> target.page_id
    | None -> local_journal model now
  in
  let parent_id =
    match target with Some target -> Some target.uuid | None -> None
  in
  upsert_blocks model
    [
      {
        (local_block uuid title page_id parent_id now) with
        is_asset = true;
        asset_type = Some asset_type;
        asset_size = Some asset_size;
        asset_checksum = Some asset_checksum;
        local_path = Some local_path;
      };
    ]
    now

let cache_local_child model uuid title parent_id now =
  match read_block model parent_id with
  | Some parent ->
    upsert_blocks model
      [ local_block uuid title parent.page_id (Some parent_id) now ]
      now;
    Ok ()
  | None -> Error ("unknown parent block: " ^ parent_id)

let pending_blocks model =
  all_blocks model
  |> List.filter (fun block ->
    block.sync_status = "pending" || block.sync_status = "failed")
  |> List.sort compare_recent

let unsynced_blocks model =
  all_blocks model
  |> List.filter (fun block -> block.sync_status <> "synced")
  |> List.sort compare_recent

let update_sync_status model uuid sync_status =
  if block_exists model uuid then (
    commit model [ add block_sync_status (block_ref uuid) sync_status ];
    Ok ())
  else Error ("unknown block: " ^ uuid)

let mark_block_synced model uuid = update_sync_status model uuid "synced"
let mark_block_submitted model uuid = update_sync_status model uuid "submitted"
let mark_block_sync_failed model uuid = update_sync_status model uuid "failed"

let reconcile_created_block model local_uuid remote_uuid sync_status =
  match read_block model local_uuid with
  | None -> Error ("unknown block: " ^ local_uuid)
  | Some local ->
    if local_uuid = remote_uuid then
      update_sync_status model local_uuid sync_status
    else (
      let base =
        match read_block model remote_uuid with
        | Some block -> block
        | None -> local
      in
      let reconciled =
        {
          (prefer_local_asset local base) with
          uuid = remote_uuid;
          sync_status;
        }
      in
      upsert_blocks model [ reconciled ] (max local.updated_at base.updated_at);
      commit model [ Ds.RetractEntity (block_ref local_uuid) ];
      Ok ())

let update_block_title model uuid title now =
  if block_exists model uuid then (
    let entity = block_ref uuid in
    commit model
      [
        add block_title entity title;
        add block_updated_at entity now;
        add block_sync_status entity "pending";
      ];
    Ok ())
  else Error ("unknown block: " ^ uuid)

let update_block_status model uuid status now =
  if block_exists model uuid then (
    let entity = block_ref uuid in
    commit model
      [
        add block_status_json entity (status_json status);
        add block_updated_at entity now;
        add block_sync_status entity "pending";
      ];
    Ok ())
  else Error ("unknown block: " ^ uuid)
