module Ds = Datascript
module Model = Cache_model
module Ds_value = Datascript_value
module S = String_kit

type sidebar_pages =
  { favorites : Model.entity_summary list
  ; recent_pages : Model.entity_summary list
  }

let value db eid attr =
  match
    List.of_seq (Ds.Db.datoms db Ds.Eavt ~e:eid ~a:attr ())
  with
  | datom :: _ -> Some datom.Ds.v
  | [] -> None

let string_value = function
  | Some (Ds.String value) -> Some value
  | _ -> None

let uuid_value = function
  | Some (Ds.Uuid value) | Some (Ds.String value) -> Some value
  | _ -> None

let int_value = function
  | Some (Ds.Int64 value) -> Some (Int64.to_int value)
  | Some (Ds.Instant value) -> Some (Int64.to_int value)
  | _ -> None

let protected_string decrypt_title value =
  match string_value value with
  | Some value ->
    (match decrypt_title value with
     | Ok value -> Some value
     | Error message -> failwith ("decrypt graph title: " ^ message))
  | None -> None

let uuid_for_eid db eid = uuid_value (value db eid "block/uuid")

let has_ref db eid attr target_eid =
  Seq.exists
    (fun (datom : Ds.datom) ->
      Ds_value.ref_eid db attr datom.v = Some target_eid)
    (Ds.Db.datoms db Ds.Eavt ~e:eid ~a:attr ())

let ref_eids db eid attr =
  List.of_seq (Ds.Db.datoms db Ds.Eavt ~e:eid ~a:attr ())
  |> List.filter_map (fun (datom : Ds.datom) -> Ds_value.ref_eid db attr datom.v)

let class_descendants db root_eid =
  let rec loop pending seen =
    match pending with
    | [] -> seen
    | eid :: rest ->
      if List.mem eid seen then loop rest seen
      else
        loop
          (List.of_seq
             (Ds_value.datoms_by_ref db Ds.Aevt "logseq.property.class/extends"
                eid)
          |> List.map (fun (datom : Ds.datom) -> datom.e)
          |> fun children -> children @ rest)
          (eid :: seen)
  in
  loop [ root_eid ] []

let entity_is_instance_of db eid class_ident =
  match Ds.entid db "db/ident" (Ds.Keyword class_ident) with
  | Some class_eid ->
    let accepted = class_descendants db class_eid in
    List.exists
      (fun eid -> List.mem eid accepted)
      (ref_eids db eid "block/tags")
  | None -> false

let tag_display_type db tag_eid =
  List.find_map (fun (ident, display) ->
    match Ds.entid db "db/ident" (Ds.Keyword ident) with
    | Some eid when List.mem tag_eid (class_descendants db eid) -> Some display
    | _ -> None)
    ["logseq.class/Math-block", "math";
     "logseq.class/Quote-block", "quote";
     "logseq.class/Code-block", "code"]

let display_type_for_eid db eid =
  match value db eid "logseq.property.node/display-type" with
  | Some (Ds.Keyword ("math" | "quote" | "code" as display)) -> Some display
  | _ -> List.find_map (tag_display_type db) (ref_eids db eid "block/tags")

let default_task_status_eid db =
  let configured =
    Option.bind (Ds.entid db "db/ident" (Ds.Keyword "logseq.property/status"))
      (fun eid -> Ds_value.optional_ref_eid db "logseq.property/default-value"
        (value db eid "logseq.property/default-value")) in
  match configured with
  | Some _ -> configured
  | None -> Ds.entid db "db/ident" (Ds.Keyword "logseq.property/status.todo")

let entity_summary decrypt_title db eid =
  let uuid = uuid_for_eid db eid in
  let title = protected_string decrypt_title (value db eid "block/title") in
  match (uuid, title) with
  | Some uuid, Some title -> Some { Model.uuid; title }
  | _ -> None

let entity_summaries decrypt_title db eid attr =
  List.of_seq (Ds.Db.datoms db Ds.Eavt ~e:eid ~a:attr ())
  |> List.filter_map (fun (datom : Ds.datom) ->
    match Ds_value.ref_eid db attr datom.v with
    | Some eid -> entity_summary decrypt_title db eid
    | None -> None)

let tag_is_visible_in_node db eid =
  value db eid "db/ident" <> Some (Ds.Keyword "logseq.class/Task")
  && value db eid "logseq.property.class/hide-from-node"
     <> Some (Ds.Bool true)

let visible_tag_summaries decrypt_title db eid =
  List.of_seq (Ds.Db.datoms db Ds.Eavt ~e:eid ~a:"block/tags" ())
  |> List.filter_map (fun (datom : Ds.datom) ->
    match Ds_value.ref_eid db "block/tags" datom.v with
    | Some tag_eid ->
      if
        tag_is_visible_in_node db tag_eid
        && entity_is_instance_of db tag_eid "logseq.class/Tag"
      then entity_summary decrypt_title db tag_eid
      else None
    | None -> None)

let rec breadcrumbs_loop decrypt_title db seen eid ancestors =
  if List.mem eid seen then ancestors
  else
    match
      Ds_value.optional_ref_eid db "block/parent"
        (value db eid "block/parent")
    with
    | Some parent_eid ->
      let ancestors =
        match entity_summary decrypt_title db parent_eid with
        | Some summary -> summary :: ancestors
        | None -> ancestors
      in
      breadcrumbs_loop decrypt_title db (eid :: seen) parent_eid ancestors
    | None -> ancestors

let breadcrumbs decrypt_title db eid =
  breadcrumbs_loop decrypt_title db [] eid []

let choice_for_eid decrypt_title db eid property =
  let selected =
    Ds_value.optional_ref_eid db property
      (value db eid property)
  in
  let selected =
    if selected = None && property = "logseq.property/status"
       && value db eid property = None
       && entity_is_instance_of db eid "logseq.class/Task"
    then default_task_status_eid db else selected in
  match selected with
  | Some status_eid ->
    let ident =
      match value db status_eid "db/ident" with
      | Some (Ds.Keyword ident) -> Some ident
      | _ -> None
    in
    let uuid = Option.value ~default:(Option.value ~default:"" ident) (uuid_for_eid db status_eid) in
    let title =
      Option.value ~default:uuid
        (protected_string decrypt_title (value db status_eid "block/title"))
    in
    if uuid <> "" then
      Some
        {
          Model.uuid;
          ident;
          title;
          icon_type = None;
          icon_id = None;
          icon_color = None;
        }
    else None
  | None -> None

let status_for_eid decrypt_title db eid =
  choice_for_eid decrypt_title db eid "logseq.property/status"

let read_block ?(with_breadcrumbs = true) ?page_info ?fields decrypt_title db eid =
  let attributes = Hashtbl.create 24 in
  (match fields with
   | None ->
     Seq.iter (fun (datom : Ds.datom) ->
       if not (Hashtbl.mem attributes datom.a) then
         Hashtbl.add attributes datom.a datom.v)
       (Ds.Db.datoms db Ds.Eavt ~e:eid ())
   | Some fields ->
     List.iter (fun attr ->
       Option.iter (fun value -> Hashtbl.replace attributes attr value)
         (value db eid attr)) fields);
  let original_value = value in
  let value db entity attr =
    if entity = eid then Hashtbl.find_opt attributes attr
    else original_value db entity attr in
  let uuid = uuid_value (value db eid "block/uuid") in
  let title = protected_string decrypt_title (value db eid "block/title") in
  let name = value db eid "block/name" in
  match name with
  | Some _ -> None
  | None ->
    (match (uuid, title) with
     | Some uuid, Some title ->
       let referenced_uuid attr =
         match
           Ds_value.optional_ref_eid db attr (value db eid attr)
         with
         | Some eid -> uuid_for_eid db eid
         | None -> None
       in
       let page_eid =
         Ds_value.optional_ref_eid db "block/page" (value db eid "block/page")
       in
       let page_id =
         match page_info with
         | Some info -> fst (Lazy.force info)
         | None -> Option.value ~default:""
           (match page_eid with
            | Some eid -> uuid_for_eid db eid
            | None -> None)
       in
       let ancestors =
         if with_breadcrumbs then breadcrumbs decrypt_title db eid else []
       in
       let journal =
         match page_info with
         | Some info -> snd (Lazy.force info)
         | None -> match page_eid with
         | Some page_eid ->
           let title =
             match ancestors with
             | [] ->
               protected_string decrypt_title
                 (value db page_eid "block/title")
             | _ ->
               List.find_map
                 (fun (summary : Model.entity_summary) ->
                   if summary.uuid = page_id then Some summary.title
                   else None)
                 ancestors
           in
           let day = int_value (value db page_eid "block/journal-day") in
           (match (title, day) with
            | Some title, Some day -> Some (title, day)
            | _ -> None)
         | None -> None
       in
       let created_at =
         Option.value ~default:0 (int_value (value db eid "block/created-at"))
       in
       Some
         {
           Model.uuid;
           title;
           page_id;
           parent_id = referenced_uuid "block/parent";
           order = string_value (value db eid "block/order");
           created_at;
           updated_at =
             Option.value ~default:created_at
               (int_value (value db eid "block/updated-at"));
           sync_status = "synced";
           tags = visible_tag_summaries decrypt_title db eid;
           references = entity_summaries decrypt_title db eid "block/refs";
           breadcrumbs = ancestors;
           priority = choice_for_eid decrypt_title db eid "logseq.property/priority";
           status = status_for_eid decrypt_title db eid;
           display_type = display_type_for_eid db eid;
           is_asset = entity_is_instance_of db eid "logseq.class/Asset";
           asset_type =
             string_value (value db eid "logseq.property.asset/type");
           asset_size =
             int_value (value db eid "logseq.property.asset/size");
           asset_checksum =
             string_value (value db eid "logseq.property.asset/checksum");
           local_path = None;
           journal;
         }
     | _ -> None)

let block ?with_breadcrumbs decrypt_title db eid =
  read_block ?with_breadcrumbs decrypt_title db eid

let page_is_hidden db eid =
  let rec loop seen eid =
    if List.mem eid seen then false
    else if value db eid "logseq.property/hide?" = Some (Ds.Bool true) then true
    else if Option.is_some (value db eid "logseq.property/deleted-at") then true
    else
      match
        Ds_value.optional_ref_eid db "block/parent"
          (value db eid "block/parent")
      with
      | Some parent_eid -> loop (eid :: seen) parent_eid
      | None -> false
  in
  loop [] eid

let page_summary decrypt_title db eid =
  let uuid = uuid_for_eid db eid in
  let title = protected_string decrypt_title (value db eid "block/title") in
  let name = string_value (value db eid "block/name") in
  match (uuid, title, name) with
  | Some uuid, Some title, Some name ->
    if
      S.trim title <> ""
      && not (S.starts_with ~prefix:"$$$" name)
      && not (page_is_hidden db eid)
    then Some { Model.uuid; title }
    else None
  | _ -> None

let favorite_page_eid db =
  match
    List.of_seq
      (Ds.Db.datoms db Ds.Aevt ~a:"block/name" ~v:(Ds.String "$$$favorites") ())
  with
  | datom :: _ -> Some datom.Ds.e
  | [] -> None

let recycle_page_eid db =
  match
    List.of_seq
      (Ds.Db.datoms db Ds.Aevt ~a:"block/name" ~v:(Ds.String "recycle") ())
  with
  | datom :: _ -> Some datom.Ds.e
  | [] -> None

let last_order db attr eid =
  let orders =
    List.of_seq (Ds_value.datoms_by_ref db Ds.Aevt attr eid)
    |> List.filter_map (fun (datom : Ds.datom) ->
      string_value (value db datom.e "block/order"))
  in
  match orders with
  | first :: rest ->
    Some (List.fold_left (fun latest order -> if compare latest order >= 0 then latest else order) first rest)
  | [] -> None

let last_recycle_order db =
  match recycle_page_eid db with
  | Some eid -> last_order db "block/parent" eid
  | None -> None

let last_favorite_order db =
  match favorite_page_eid db with
  | Some eid -> last_order db "block/page" eid
  | None -> None

let favorite_block_eid db page_uuid =
  match (favorite_page_eid db, Ds.entid db "block/uuid" (Ds.Uuid page_uuid)) with
  | Some favorites_eid, Some page_eid ->
    List.of_seq (Ds_value.datoms_by_ref db Ds.Aevt "block/page" favorites_eid)
    |> List.find_map (fun (datom : Ds.datom) ->
      if
        Ds_value.optional_ref_eid db "block/link"
          (value db datom.e "block/link")
        = Some page_eid
      then Some datom.e
      else None)
  | _ -> None

let favorite_block_uuid db page_uuid =
  match favorite_block_eid db page_uuid with
  | Some eid -> uuid_for_eid db eid
  | None -> None

let page_is_favorite db page_uuid =
  Option.is_some (favorite_block_eid db page_uuid)

let built_in_class db eid =
  match value db eid "db/ident" with
  | Some (Ds.Keyword ident) -> S.starts_with ~prefix:"logseq.class/" ident
  | _ -> false

let trace_sidebar started stage =
  if Sys.getenv_opt "LOGSEQ_TRACE_STARTUP" = Some "1" then
    prerr_endline
      ("LOGSEQ_SIDEBAR_METRIC stage=" ^ stage
       ^ Printf.sprintf " elapsed_ms=%.3f"
           ((Unix.gettimeofday () -. started) *. 1000.0))

let sidebar_pages decrypt_title db =
  let started = Unix.gettimeofday () in
  let favorites =
    match favorite_page_eid db with
    | Some eid ->
      List.of_seq (Ds_value.datoms_by_ref db Ds.Aevt "block/page" eid)
      |> List.filter_map (fun (datom : Ds.datom) ->
        match
          Ds_value.optional_ref_eid db "block/link"
            (value db datom.e "block/link")
        with
        | Some page_eid ->
          (match page_summary decrypt_title db page_eid with
           | Some page ->
             Some
               ( Option.value ~default:""
                   (string_value (value db datom.e "block/order"))
               , page )
           | None -> None)
        | None -> None)
      |> List.sort (fun (left, _) (right, _) -> compare left right)
      |> List.map snd
    | None -> []
  in
  trace_sidebar started "favorites";
  let favorite_uuids =
    List.fold_left (fun set (page : Model.entity_summary) -> page.uuid :: set) [] favorites
  in
  (* Set-scans instead of per-entity queries: collect the named eids
     once, then pull ident / built-in / updated-at / journal-day for
     just those eids while scanning each attr index. *)
  let named =
    List.of_seq (Ds.Db.datoms db Ds.Aevt ~a:"block/name" ())
    |> List.filter_map (fun (datom : Ds.datom) ->
      match datom.v with
      | Ds.String name when not (S.starts_with ~prefix:"$$$" name) ->
        Some datom.e
      | _ -> None)
  in
  let named_set = Hashtbl.create (List.length named) in
  List.iter (fun eid -> Hashtbl.replace named_set eid ()) named;
  let for_named attr f =
    let table = Hashtbl.create 64 in
    Seq.iter
      (fun (datom : Ds.datom) ->
        if Hashtbl.mem named_set datom.e then f table datom)
      (Ds.Db.datoms db Ds.Aevt ~a:attr ());
    table
  in
  let mark attr pred =
    for_named attr (fun table (datom : Ds.datom) ->
      if pred datom.v then Hashtbl.replace table datom.e ())
  in
  let class_eids =
    mark "db/ident" (fun v ->
      match v with
      | Ds.Keyword ident -> S.starts_with ~prefix:"logseq.class/" ident
      | _ -> false)
  in
  let builtin_eids =
    mark "logseq.property/built-in?" (fun v -> v = Ds.Bool true)
  in
  let ints attr =
    for_named attr (fun table (datom : Ds.datom) ->
      match int_value (Some datom.v) with
      | Some value -> Hashtbl.replace table datom.e value
      | None -> ())
  in
  let updated_map = ints "block/updated-at" in
  let day_map = ints "block/journal-day" in
  let candidates =
    List.filter_map
      (fun eid ->
        if Hashtbl.mem class_eids eid || Hashtbl.mem builtin_eids eid then None
        else
          Some
            ( Option.value ~default:0 (Hashtbl.find_opt updated_map eid)
            , Option.value ~default:0 (Hashtbl.find_opt day_map eid)
            , eid ))
      named
  in
  trace_sidebar started "candidates";
  let ranked =
    List.sort
      (fun (left_updated, left_day, left_eid) (right_updated, right_day, right_eid) ->
        let updated = compare right_updated left_updated in
        let day = compare right_day left_day in
        if updated <> 0 then updated
        else if day <> 0 then day
        else compare right_eid left_eid)
      candidates
  in
  trace_sidebar started "ranked";

  (* Resolve and decrypt only enough ranked pages to fill the window:
     stay lazy like the original seq pipeline. *)
  let seq_distinct xs =
    let seen = Hashtbl.create 16 in
    let rec loop xs () =
      match xs () with
      | Seq.Nil -> Seq.Nil
      | Seq.Cons (x, rest) ->
        if Hashtbl.mem seen x then loop rest ()
        else (
          Hashtbl.replace seen x ();
          Seq.Cons (x, loop rest))
    in
    loop xs
  in
  let recent_seq =
    List.to_seq ranked
    |> Seq.map (fun (_, _, eid) -> eid)
    |> seq_distinct
    |> Seq.filter_map (fun eid ->
      match page_summary decrypt_title db eid with
      | Some page ->
        if List.mem page.Model.uuid favorite_uuids then None else Some page
      | None -> None)
  in
  let rec take n xs () =
    if n <= 0 then Seq.Nil
    else
      match xs () with
      | Seq.Nil -> Seq.Nil
      | Seq.Cons (x, rest) -> Seq.Cons (x, take (n - 1) rest)
  in
  let result = List.of_seq (take 15 recent_seq) in
  trace_sidebar started "resolved";
  { favorites; recent_pages = result }

let page_block decrypt_title db eid =
  match page_summary decrypt_title db eid with
  | Some page ->
    let created_at =
      Option.value ~default:0 (int_value (value db eid "block/created-at"))
    in
    Some
      {
        Model.uuid = page.uuid;
        title = page.title;
        page_id = page.uuid;
        parent_id = None;
        order = None;
        created_at;
        updated_at =
          Option.value ~default:created_at
            (int_value (value db eid "block/updated-at"));
        sync_status = "synced";
        tags = visible_tag_summaries decrypt_title db eid;
        references = [];
        breadcrumbs = [];
        priority = None;
        status = None;
        display_type = display_type_for_eid db eid;
        is_asset = false;
        asset_type = None;
        asset_size = None;
        asset_checksum = None;
        local_path = None;
        journal =
          (match int_value (value db eid "block/journal-day") with
           | Some day -> Some (page.title, day)
           | None -> None);
      }
  | None -> None

let tag_available_for_completion db eid =
  match value db eid "db/ident" with
  | Some (Ds.Keyword ident) ->
    not
      (List.mem ident
         [
           "logseq.class/Root";
           "logseq.class/Page";
           "logseq.class/Property";
           "logseq.class/Tag";
           "logseq.class/Asset";
           "logseq.class/Journal";
           "logseq.class/Whiteboard";
           "logseq.class/Pdf-annotation";
           "logseq.class/Comment";
           "logseq.class/Comments";
         ])
  | _ -> true

let tag_last_used db eid =
  List.fold_left
    (fun latest (datom : Ds.datom) -> max latest datom.tx)
    0
    (List.of_seq (Ds_value.datoms_by_ref db Ds.Aevt "block/tags" eid))

let tag_pages decrypt_title db =
  match Ds.entid db "db/ident" (Ds.Keyword "logseq.class/Tag") with
  | Some eid ->
    List.of_seq (Ds_value.datoms_by_ref db Ds.Aevt "block/tags" eid)
    |> List.filter_map (fun (datom : Ds.datom) ->
      if tag_available_for_completion db datom.e then
        match page_summary decrypt_title db datom.e with
        | Some page -> Some (tag_last_used db datom.e, page)
        | None -> None
      else None)
    |> List.sort
         (fun (left_used, (left : Model.entity_summary))
              (right_used, (right : Model.entity_summary)) ->
           let used = compare right_used left_used in
           let title = compare left.title right.title in
           if used <> 0 then used
           else if title <> 0 then title
           else compare left.uuid right.uuid)
    |> List.map snd
  | None -> []

let node_is_tag db uuid =
  match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
  | Some eid -> entity_is_instance_of db eid "logseq.class/Tag"
  | None -> false

let node_is_property db uuid =
  match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
  | Some eid -> entity_is_instance_of db eid "logseq.class/Property"
  | None -> false

let unique_named_uuid require_tag db name =
  let key = String.lowercase_ascii (S.trim name) in
  if key = "" then None
  else (
    let matches =
      List.of_seq (Ds.Db.datoms db Ds.Aevt ~a:"block/name" ~v:(Ds.String key) ())
      |> List.map (fun (datom : Ds.datom) -> datom.e)
      |> List.filter (fun eid ->
        (not require_tag) || entity_is_instance_of db eid "logseq.class/Tag")
    in
    match matches with
    | [ eid ] -> uuid_for_eid db eid
    | _ -> None)

let known_title summaries name =
  let key = String.lowercase_ascii (S.trim name) in
  if key = "" then None
  else (
    let matches =
      List.filter
        (fun (summary : Model.entity_summary) ->
          String.lowercase_ascii summary.title = key)
        summaries
    in
    match matches with
    | [ summary ] -> Some summary.Model.uuid
    | _ -> None)

let normalize_title_text create_tag db uuid title =
  let refs, tags =
    match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
    | Some eid ->
      ( entity_summaries (fun value -> Ok value) db eid "block/refs"
      , entity_summaries (fun value -> Ok value) db eid "block/tags" )
    | None -> ([], [])
  in
  Ref_text.to_ids
    (fun name ->
      match known_title (refs @ tags) name with
      | Some uuid -> Some uuid
      | None -> unique_named_uuid false db name)
    (fun name ->
      match known_title tags name with
      | Some uuid -> Some uuid
      | None ->
        (match unique_named_uuid true db name with
         | Some uuid -> Some uuid
         | None -> create_tag name))
    title

type created_tags =
  { entries : (string * string) list ref
  }

let normalize_titles_creating_tags db fresh_uuid uuid titles =
  let created = { entries = ref [] } in
  let create_tag name =
    let name = S.trim name in
    let key = String.lowercase_ascii name in
    if key = "" then None
    else
      match
        List.find_map
          (fun (uuid, existing) ->
            if String.lowercase_ascii existing = key then Some uuid else None)
          !(created.entries)
      with
      | Some uuid -> Some uuid
      | None ->
        let uuid = fresh_uuid () in
        created.entries := (uuid, name) :: !(created.entries);
        Some uuid
  in
  let titles = List.map (normalize_title_text create_tag db uuid) titles in
  (titles, List.rev !(created.entries))

let compare_blocks left right =
  match (left.Model.order, right.Model.order) with
  | Some left_order, Some right_order -> compare left_order right_order
  | Some _, None -> -1
  | None, Some _ -> 1
  | None, None -> compare left.Model.created_at right.Model.created_at

let journal_day (block : Model.block) =
  match block.journal with Some (_, day) -> day | None -> 0

let compare_journal_blocks left right =
  let order = compare (journal_day right) (journal_day left) in
  if order = 0 then compare_blocks left right else order

let outline_metadata_chain db =
  let cached = Hashtbl.create 64 in
  fun root ->
    let seen = Hashtbl.create 8 in
    let finish trail result =
      List.iter (fun eid -> Hashtbl.replace cached eid result) trail;
      result in
    let rec loop trail eid =
      match Hashtbl.find_opt cached eid with
      | Some result -> finish trail result
      | None when Hashtbl.mem seen eid -> finish trail false
      | None ->
        Hashtbl.add seen eid ();
        let trail = eid :: trail in
        if value db eid "logseq.property/created-from-property" <> None
           || value db eid "block/closed-value-property" <> None then finish trail true
        else match Ds_value.optional_ref_eid db "block/parent" (value db eid "block/parent") with
          | Some parent -> loop trail parent
          | None -> finish trail false in
    loop [] root

let related_candidate_is_visible db =
  let is_metadata = outline_metadata_chain db in
  fun eid ->
    (not (page_is_hidden db eid))
    && not (is_metadata eid)
    && value db eid "logseq.property/view-for" = None

let read_blocks_referencing ?(with_breadcrumbs = true) ?page_info decrypt_title db attr
    target_uuid =
  match Ds.entid db "block/uuid" (Ds.Uuid target_uuid) with
  | Some eid ->
    let is_visible = related_candidate_is_visible db in
    List.of_seq (Ds_value.datoms_by_ref db Ds.Aevt attr eid)
    |> List.filter_map (fun (datom : Ds.datom) ->
      if is_visible datom.e then
        read_block ~with_breadcrumbs ?page_info decrypt_title db datom.e
      else None)
    |> List.sort compare_blocks
  | None -> []

let blocks_referencing ?with_breadcrumbs decrypt_title db attr uuid =
  read_blocks_referencing ?with_breadcrumbs decrypt_title db attr uuid

let references_for_node decrypt_title db uuid =
  blocks_referencing decrypt_title db "block/refs" uuid

type page_window_row =
  { block : Model.block
  ; depth : int
  ; has_children : bool
  ; is_collapsed : bool
  }

type page_window =
  { rows : page_window_row list
  ; next_offset : int option
  }

module Page_uuid_set = Set.Make (String)

type page_metadata_row =
  { entity_id : int
  ; row_depth : int
  ; row_has_children : bool
  ; row_is_collapsed : bool
  ; has_following : bool
  }

type page_tree =
  { tree_db : Ds.db
  ; page_uuid : string
  ; page_eid : int option
  ; child_orders : (int, int list) Hashtbl.t
  ; visible_entities : (int, bool) Hashtbl.t
  ; child_presence : (int, bool) Hashtbl.t
  }

type page_reader =
  { tree : page_tree
  ; reader_collapsed : string list
  ; metadata_rows : page_metadata_row Seq.t
  }

let page_entity_visible tree eid =
  match Hashtbl.find_opt tree.visible_entities eid with
  | Some visible -> visible
  | None ->
    let db = tree.tree_db in
    let visible =
      Ds_value.optional_ref_eid db "block/page" (value db eid "block/page") = tree.page_eid
      && value db eid "block/name" = None
      && value db eid "logseq.property/hide?" <> Some (Ds.Bool true)
      && value db eid "logseq.property/deleted-at" = None
      && value db eid "logseq.property/view-for" = None
      && value db eid "logseq.property/created-from-property" = None
      && value db eid "block/closed-value-property" = None in
    Hashtbl.replace tree.visible_entities eid visible;
    visible

let page_child_ids tree parent =
  Ds_value.datoms_by_ref tree.tree_db Ds.Aevt "block/parent" parent
  |> Seq.map (fun (datom : Ds.datom) -> datom.e)

let page_has_children tree parent =
  match Hashtbl.find_opt tree.child_presence parent with
  | Some present -> present
  | None ->
    let present = Seq.exists (page_entity_visible tree) (page_child_ids tree parent) in
    Hashtbl.replace tree.child_presence parent present;
    present

let ordered_page_children tree parent =
  match Hashtbl.find_opt tree.child_orders parent with
  | Some ids -> ids
  | None ->
    let db = tree.tree_db in
    let children = page_child_ids tree parent |> List.of_seq
      |> List.map (fun eid ->
        (eid, string_value (value db eid "block/order"),
         lazy (Option.value ~default:0 (int_value (value db eid "block/created-at"))),
         lazy (Option.value ~default:"" (uuid_for_eid db eid)))) in
    let compare_child (_, left, left_time, left_uuid) (_, right, right_time, right_uuid) =
      match left, right with
      | Some a, Some b when a <> b -> String.compare a b
      | Some _, None -> -1
      | None, Some _ -> 1
      | _ ->
        let order = Int.compare (Lazy.force left_time) (Lazy.force right_time) in
        if order <> 0 then order
        else String.compare (Lazy.force left_uuid) (Lazy.force right_uuid) in
    let ids = List.sort compare_child children |> List.map (fun (eid, _, _, _) -> eid) in
    Hashtbl.replace tree.child_orders parent ids;
    ids

type page_walk_frame =
  | Visit_children of int * int
  | Visit_siblings of int list * int

let page_reader_for_tree tree collapsed =
  let collapsed = List.sort_uniq String.compare collapsed in
  let collapsed_set = Page_uuid_set.of_list collapsed in
  let visited = Hashtbl.create 64 in
  let rec walk frames () =
    match frames with
    | [] -> Seq.Nil
    | Visit_children (parent, depth) :: rest ->
      walk (Visit_siblings (ordered_page_children tree parent, depth) :: rest) ()
    | Visit_siblings ([], _) :: rest -> walk rest ()
    | Visit_siblings (eid :: siblings, depth) :: rest ->
      let rest = if siblings = [] then rest else Visit_siblings (siblings, depth) :: rest in
      if Hashtbl.mem visited eid || not (page_entity_visible tree eid) then walk rest ()
      else begin
        Hashtbl.add visited eid ();
        let has_children = page_has_children tree eid in
        let is_collapsed =
          not (Page_uuid_set.is_empty collapsed_set)
          && (match uuid_for_eid tree.tree_db eid with
              | Some uuid -> Page_uuid_set.mem uuid collapsed_set
              | None -> false) in
        let enters_children = has_children && not is_collapsed in
        let next = if enters_children then Visit_children (eid, depth + 1) :: rest else rest in
        Seq.Cons (
          { entity_id = eid; row_depth = depth; row_has_children = has_children;
            row_is_collapsed = is_collapsed; has_following = enters_children || rest <> [] },
          walk next)
      end
  in
  let rows () =
    match tree.page_eid with
    | Some eid when not (page_is_hidden tree.tree_db eid) -> walk [Visit_children (eid, 0)] ()
    | _ -> Seq.Nil in
  { tree; reader_collapsed = collapsed; metadata_rows = Seq.memoize rows }

let page_reader ?(collapsed = []) db uuid =
  let tree = { tree_db = db; page_uuid = uuid;
    page_eid = Ds.entid db "block/uuid" (Ds.Uuid uuid);
    child_orders = Hashtbl.create 32; visible_entities = Hashtbl.create 64;
    child_presence = Hashtbl.create 64 } in
  page_reader_for_tree tree collapsed

let page_reader_with_collapsed reader collapsed =
  let collapsed = List.sort_uniq String.compare collapsed in
  if collapsed = reader.reader_collapsed then reader
  else page_reader_for_tree reader.tree collapsed

let window_block_fields =
  ["block/uuid"; "block/title"; "block/name"; "block/page"; "block/parent";
   "block/order"; "block/created-at"; "block/updated-at";
   "logseq.property.asset/type"; "logseq.property.asset/size";
   "logseq.property.asset/checksum"; "logseq.property.node/display-type"]

let read_page_window ?(offset = 0) ?(limit = 32) decrypt_title reader =
  if offset < 0 || limit < 0 || limit > 32 then
    invalid_arg "page window requires a nonnegative offset and a limit between 0 and 32";
  if limit = 0 then { rows = []; next_offset = None }
  else
    let tree = reader.tree in
    let db = tree.tree_db in
    let page_info = lazy (
      let journal = match tree.page_eid with
        | Some eid ->
          (match int_value (value db eid "block/journal-day") with
           | Some day -> Option.map (fun title -> title, day)
               (protected_string decrypt_title (value db eid "block/title"))
           | None -> None)
        | None -> None in
      tree.page_uuid, journal) in
    let rec skip count rows =
      if count = 0 then rows
      else match rows () with Seq.Nil -> Seq.empty | Seq.Cons (_, rest) -> skip (count - 1) rest in
    let rec collect index count result rows =
      match rows () with
      | Seq.Nil -> { rows = List.rev result; next_offset = None }
      | Seq.Cons (metadata, rest) ->
        (match read_block ~with_breadcrumbs:false ~page_info ~fields:window_block_fields
          decrypt_title db metadata.entity_id with
         | None -> collect (index + 1) count result rest
         | Some block ->
           let row = { block; depth = metadata.row_depth;
             has_children = metadata.row_has_children; is_collapsed = metadata.row_is_collapsed } in
           let result = row :: result in
           if count = 1 then
             { rows = List.rev result;
               next_offset = if metadata.has_following then Some (index + 1) else None }
           else collect (index + 1) (count - 1) result rest)
    in
    collect offset limit [] (skip offset reader.metadata_rows)

(* Match master direct-child membership: property values and choices are
   metadata, not outline children. Traverse parent membership rather than
   treating every entity with the same block/page as rendered content. *)
let blocks_for_page decrypt_title db uuid =
  let reader = page_reader db uuid in
  let page_info = lazy (
    let journal = match reader.tree.page_eid with
      | Some eid ->
        (match int_value (value db eid "block/journal-day") with
         | Some day -> Option.map (fun title -> title, day)
             (protected_string decrypt_title (value db eid "block/title"))
         | None -> None)
      | None -> None in
    uuid, journal) in
  reader.metadata_rows
  |> Seq.filter_map (fun row ->
       read_block ~with_breadcrumbs:false ~page_info decrypt_title db row.entity_id)
  |> List.of_seq

let node_destination decrypt_title db uuid =
  match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
  | Some eid ->
    if page_is_hidden db eid then None
    else (
      let is_page =
        Option.is_some (string_value (value db eid "block/name"))
      in
      let page_eid =
        if is_page then Some eid
        else
          Ds_value.optional_ref_eid db "block/page"
            (value db eid "block/page")
      in
      match page_eid with
      | Some page_eid ->
        (match page_summary decrypt_title db page_eid with
         | Some page -> Some (page, not is_page)
         | None -> None)
      | None -> None)
  | None -> None

let objects_for_tag decrypt_title db uuid =
  match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
  | Some eid ->
    let is_visible = related_candidate_is_visible db in
    let ids =
      class_descendants db eid
      |> List.sort_uniq compare
      |> List.concat_map (fun eid ->
        List.of_seq (Ds_value.datoms_by_ref db Ds.Aevt "block/tags" eid)
        |> List.map (fun (datom : Ds.datom) -> datom.e))
      |> List.sort_uniq compare
    in
    ids
    |> List.filter_map (fun eid ->
      if is_visible eid then
        match block decrypt_title db eid with
        | Some block -> Some block
        | None -> page_block decrypt_title db eid
      else None)
    |> List.sort compare_journal_blocks
  | None -> []

let rec take n list =
  match (n, list) with
  | 0, _ | _, [] -> []
  | n, x :: rest -> x :: take (n - 1) rest

let today () =
  Model.journal_day_for_ms (int_of_float (Unix.gettimeofday () *. 1000.))

let recent_journal_pages ?(through_day = today ()) limit db =
  List.of_seq (Ds.Db.datoms db Ds.Aevt ~a:"block/journal-day" ())
  |> List.filter_map (fun (datom : Ds.datom) ->
    match datom.v with
    | Ds.Int64 day when day <= Int64.of_int through_day -> Some (day, datom.e)
    | _ -> None)
  |> List.sort (fun (left, _) (right, _) -> compare right left)
  |> fun sorted ->
  let rec collect n acc entries =
    match (n, entries) with
    | 0, _ | _, [] -> List.rev acc
    | n, (day, eid) :: rest ->
      if page_is_hidden db eid then collect n acc rest
      else collect (n - 1) ((day, eid) :: acc) rest
  in
  collect limit [] sorted

let recent_journal_page_ids ?through_day limit db =
  List.map snd (recent_journal_pages ?through_day limit db)

let journal_page_count db =
  List.fold_left
    (fun count (datom : Ds.datom) ->
      if page_is_hidden db datom.e then count else count + 1)
    0
    (List.of_seq (Ds.Db.datoms db Ds.Aevt ~a:"block/journal-day" ()))

let journal_page_uuid db day =
  List.of_seq (Ds.Db.datoms db Ds.Aevt ~a:"block/journal-day" ())
  |> List.find_map (fun (datom : Ds.datom) ->
    match datom.v with
    | Ds.Int64 candidate ->
      if Int64.equal candidate (Int64.of_int day) && not (page_is_hidden db datom.e) then
        uuid_for_eid db datom.e
      else None
    | _ -> None)

let blocks ?block_limit ?through_day decrypt_title journal_limit db =
  let entries =
    recent_journal_pages ?through_day journal_limit db
    |> List.concat_map (fun (day, page_eid) ->
      List.of_seq (Ds_value.datoms_by_ref db Ds.Aevt "block/page" page_eid)
      |> List.map (fun (datom : Ds.datom) -> (day, datom.e)))
  in
  let is_visible = related_candidate_is_visible db in
  let entries = List.filter (fun (_, eid) -> is_visible eid) entries in
  let eids =
    match block_limit with
    | Some limit when List.length entries > limit ->
      entries
      |> List.map (fun (day, eid) ->
        ( day
        , string_value (value db eid "block/order")
        , int_value (value db eid "block/created-at")
        , eid ))
      |> List.stable_sort
           (fun (day_left, order_left, created_left, _)
                (day_right, order_right, created_right, _) ->
             let by_day = compare day_right day_left in
             if by_day <> 0 then by_day
             else
               (match (order_left, order_right) with
                | Some left, Some right -> compare left right
                | Some _, None -> -1
                | None, Some _ -> 1
                | None, None ->
                  compare
                    (Option.value ~default:0 created_left)
                    (Option.value ~default:0 created_right)))
      |> take limit
      |> List.map (fun (_, _, _, eid) -> eid)
    | _ -> List.map snd entries
  in
  eids
  |> List.filter_map (fun eid ->
    block ~with_breadcrumbs:false decrypt_title db eid)
  |> List.sort compare_journal_blocks
