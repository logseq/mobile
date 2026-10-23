module Ds = Datascript
module Ops = Pending_ops
module Db = Ds.Db
module Entity = Ds.Entity

type pending_projection_snapshot =
  { db : Datascript.db
  ; server_t : int
  ; statuses : (string * Ops.pending_state) list
  }

let lookup uuid = Ds.Lookup_ref ("block/uuid", Ds.Uuid uuid)

let one_value db reference attr =
  match Ds.entity db reference with
  | Some value ->
    (match Entity.entity_attr_raw value attr with
     | Some (Ds.One_value value) -> Some value
     | _ -> None)
  | None -> None

let string_value value =
  match value with Some (Ds.String text) -> Some text | _ -> None

let bool_value value =
  match value with Some (Ds.Bool flag) -> Some flag | _ -> None

let has_ref db eid attr target_eid =
  Seq.exists
    (fun datom ->
      Datascript_value.ref_eid db attr datom.Ds.v = Some target_eid)
    (Db.datoms db Ds.Eavt ~e:eid ~a:attr ())

let named_page_eid db name =
  match
    Db.datoms db Ds.Aevt ~a:"block/name" ~v:(Ds.String name) ()
  with
  | seq ->
    (match Seq.uncons seq with
     | Some (datom, _) -> Some datom.Ds.e
     | None -> None)

let favorite_page_eid db = named_page_eid db "$$$favorites"
let recycle_page_eid db = named_page_eid db "recycle"

let favorite_block_eid db page_uuid =
  match favorite_page_eid db with
  | Some favorites_eid ->
    (match Ds.entid db "block/uuid" (Ds.Uuid page_uuid) with
     | Some page_eid ->
       Seq.find_map
         (fun datom ->
           if has_ref db datom.Ds.e "block/link" page_eid then
             Some datom.Ds.e
           else None)
         (Db.datoms db Ds.Aevt ~a:"block/page" ~v:(Ds.Ref favorites_eid) ())
     | None -> None)
  | None -> None

let rec datascript_value (value : Ops.semantic_value) : Ds.value =
  match value with
  | Ops.Nil_value -> Ds.Nil
  | Ops.Uuid_value uuid -> Ds.Uuid uuid
  | Ops.Vector_value values -> Ds.Vector (List.map datascript_value values)
  | Ops.Set_value values -> Ds.Set (List.map datascript_value values)
  | Ops.String_value value -> Ds.String value
  | Ops.Int_value value -> Ds.Int64 (Int64.of_int value)
  | Ops.Instant_value value -> Ds.Instant (Int64.of_int value)
  | Ops.Float_value value -> Ds.Float value
  | Ops.Bool_value value -> Ds.Bool value
  | Ops.Keyword_value value -> Ds.Keyword value
  | Ops.Map_value entries ->
    Ds.Map
      (List.map
         (fun (key, value) -> (Ds.Keyword key, datascript_value value))
         entries)
  | Ops.Ref_uuid uuid -> Ds.Ref_to (lookup uuid)
  | Ops.Ref_ident ident ->
    Ds.Ref_to (Ds.Lookup_ref ("db/ident", Ds.Keyword ident))

let rec semantic_value_equal_value db left right =
  match (left, right) with
  | Ds.Nil, Ops.Nil_value -> true
  | Ds.Uuid value, Ops.Uuid_value expected -> value = expected
  | Ds.Vector values, Ops.Vector_value expected ->
    List.length values = List.length expected && List.for_all2 (semantic_value_equal_value db) values expected
  | Ds.Set values, Ops.Set_value expected ->
    List.length values = List.length expected && List.for_all (fun expected ->
      List.exists (fun value -> semantic_value_equal_value db value expected) values) expected
  | Ds.String value, Ops.String_value expected -> value = expected
  | Ds.Int64 value, Ops.Int_value expected -> Int64.equal value (Int64.of_int expected)
  | Ds.Instant value, Ops.Instant_value expected -> Int64.equal value (Int64.of_int expected)
  | Ds.Float value, Ops.Float_value expected ->
    Float.equal value expected
  | Ds.Int64 value, Ops.Float_value expected ->
    Float.equal (Int64.to_float value) expected
  | Ds.Bool value, Ops.Bool_value expected -> value = expected
  | Ds.Keyword value, Ops.Keyword_value expected -> value = expected
  | Ds.Map entries, Ops.Map_value expected ->
    List.length entries = List.length expected
    && List.for_all
         (fun (key, value) ->
           List.exists
             (fun (actual_key, actual_value) ->
               match actual_key with
               | Ds.Keyword actual_key ->
                 actual_key = key
                 && semantic_value_equal_value db actual_value value
               | _ -> false)
             entries)
         expected
  | Ds.Ref eid, Ops.Ref_uuid uuid ->
    Ds.entid db "block/uuid" (Ds.Uuid uuid) = Some eid
  | Ds.Int64 eid, Ops.Ref_uuid uuid ->
    Ds.entid db "block/uuid" (Ds.Uuid uuid) = Some (Int64.to_int eid)
  | Ds.Ref eid, Ops.Ref_ident ident ->
    Ds.entid db "db/ident" (Ds.Keyword ident) = Some eid
  | Ds.Int64 eid, Ops.Ref_ident ident ->
    Ds.entid db "db/ident" (Ds.Keyword ident) = Some (Int64.to_int eid)
  | _ -> false

let semantic_value_equal db left right =
  match (left, right) with
  | None, None -> true
  | Some value, Some expected ->
    semantic_value_equal_value db value expected
  | _ -> false

let page_names = Ref_text.page_names
let inline_tag_names = Ref_text.tag_names

let eid_for_node db value =
  match Ds.entid db "block/uuid" (Ds.Uuid value) with
  | Some eid -> Some eid
  | None -> named_page_eid db (String.lowercase_ascii value)

let refs_for_title db title =
  List.sort_uniq compare
    (List.filter_map (eid_for_node db) (page_names title))

let tag_eids_for_title db title =
  match Ds.entid db "db/ident" (Ds.Keyword "logseq.class/Tag") with
  | Some tag_class_eid ->
    List.sort_uniq compare
      (List.filter_map
         (fun name ->
           match eid_for_node db name with
           | Some eid when has_ref db eid "block/tags" tag_class_eid ->
             Some eid
           | _ -> None)
         (inline_tag_names title))
  | None -> []

let tag_behavior_tx db uuid tag_eid =
  let reference = lookup uuid in
  let display =
    match Graph_read.tag_display_type db tag_eid with
    | Some display ->
      [Ds.Add (reference, "logseq.property.node/display-type", Ds.Keyword display)]
    | None -> [] in
  let task =
    match Ds.entid db "db/ident" (Ds.Keyword "logseq.class/Task") with
    | Some task_eid
      when List.mem tag_eid (Graph_read.class_descendants db task_eid)
           && one_value db reference "logseq.property/status" = None ->
      (match Graph_read.default_task_status_eid db with
       | Some eid -> [Ds.Add (reference, "logseq.property/status", Ds.Ref eid)]
       | None -> [])
    | _ -> [] in
  display @ task

let title_tx db uuid title =
  let reference = lookup uuid in
  let retractions =
    match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
    | Some eid ->
      let old_title =
        match string_value (one_value db reference "block/title") with
        | Some title -> title
        | None -> ""
      in
      List.map
        (fun eid -> Ds.Retract (reference, "block/tags", Some (Ds.Ref eid)))
        (tag_eids_for_title db old_title)
      @ List.of_seq
          (Seq.map
             (fun datom ->
               Ds.Retract (reference, "block/refs", Some datom.Ds.v))
             (Db.datoms db Ds.Eavt ~e:eid ~a:"block/refs" ()))
    | None -> []
  in
  [ Ds.Add (reference, "block/title", Ds.String title) ]
  @ (match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
     | Some id when Node_title.is_page db id -> [Ds.Add (reference, "block/name", Ds.String (Node_title.name title))]
     | _ -> [])
  @ retractions
  @ List.map
      (fun eid -> Ds.Add (reference, "block/refs", Ds.Ref eid))
      (refs_for_title db title)
  @ List.map
      (fun eid -> Ds.Add (reference, "block/tags", Ds.Ref eid))
      (tag_eids_for_title db title)
  @ List.concat_map (tag_behavior_tx db uuid) (tag_eids_for_title db title)

let uuid_for_eid db eid =
  match one_value db (Ds.Entity_id eid) "block/uuid" with
  | Some (Ds.Uuid uuid) -> Some uuid
  | _ -> None

let journal_page_eid db day =
  Seq.find_map
    (fun datom ->
      match datom.Ds.v with
      | Ds.Int64 value when Int64.equal value (Int64.of_int day) -> Some datom.Ds.e
      | _ -> None)
    (Db.datoms db Ds.Aevt ~a:"block/journal-day" ())

let outliner_block db uuid =
  let ( let* ) = Option.bind in
  let reference = lookup uuid in
  let* title = string_value (one_value db reference "block/title") in
  let* page_eid =
    Datascript_value.optional_ref_eid db "block/page"
      (one_value db reference "block/page")
  in
  let* parent_eid =
    Datascript_value.optional_ref_eid db "block/parent"
      (one_value db reference "block/parent")
  in
  let* order = string_value (one_value db reference "block/order") in
  let* page_uuid = uuid_for_eid db page_eid in
  let* parent_uuid = uuid_for_eid db parent_eid in
  Some
    { Outliner.uuid; title; page_uuid; parent_uuid; order }

let entity_tx reference attrs =
  Ds.Entity { Ds.db_id = Some reference; attrs }

let many_refs attr eids =
  if eids = [] then []
  else
    [ ( attr
      , Ds.Many_values
          (List.map (fun eid -> Ds.Ref_to (Ds.Entity_id eid)) eids) )
    ]

let insert_tx db (block : Outliner.outliner_block) created_at =
  [
    entity_tx
      (Ds.Temp_id ("pending/" ^ block.uuid))
      ([ ( "block/uuid", Ds.One_value (Ds.Uuid block.uuid) )
       ; ( "block/title", Ds.One_value (Ds.String block.title) )
       ; ( "block/page", Ds.One_value (Ds.Ref_to (lookup block.page_uuid)) )
       ; ( "block/parent"
         , Ds.One_value (Ds.Ref_to (lookup block.parent_uuid)) )
       ; ( "block/order", Ds.One_value (Ds.String block.order) )
       ; ( "block/created-at", Ds.One_value (Ds.Int64 (Int64.of_int created_at)) )
       ; ( "block/updated-at", Ds.One_value (Ds.Int64 (Int64.of_int created_at)) )
       ]
       @ many_refs "block/refs" (refs_for_title db block.title)
       @ many_refs "block/tags" (tag_eids_for_title db block.title));
  ]
  @ List.concat_map (tag_behavior_tx db block.uuid) (tag_eids_for_title db block.title)

let outliner_mutation_tx db (mutation : Outliner.mutation) =
  match mutation with
  | Outliner.Set_title value ->
    title_tx db value.uuid value.title
  | Outliner.Insert value ->
    insert_tx db value.insert_block value.created_at
  | Outliner.Reparent value ->
    [ Ds.Add
        ( lookup value.uuid
        , "block/page"
        , Ds.Ref_to (lookup value.page_uuid) )
    ; Ds.Add
        ( lookup value.uuid
        , "block/parent"
        , Ds.Ref_to (lookup value.parent_uuid) )
    ]
  | Outliner.Delete value ->
    (match Ds.entid db "block/uuid" (Ds.Uuid value.uuid) with
     | Some eid -> [ Ds.RetractEntity (Ds.Entity_id eid) ]
     | None -> [])

let compile_outliner db command =
  let ( let* ) = Result.bind in
  let find_block uuid = outliner_block db uuid in
  let children uuid =
    match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
    | Some eid ->
      List.filter_map find_block
        (List.filter_map
           (fun datom -> uuid_for_eid db datom.Ds.e)
           (List.of_seq
              (Datascript_value.datoms_by_ref db Ds.Aevt "block/parent" eid)))
    | None -> []
  in
  let* mutations = Outliner.plan find_block children command in
  Ok
    (List.concat_map
       (fun mutation -> outliner_mutation_tx db mutation)
       mutations)

let children db eid =
  List.of_seq
    (Seq.map (fun datom -> datom.Ds.e)
       (Datascript_value.datoms_by_ref db Ds.Aevt "block/parent" eid))

let subtree db roots =
  let rec loop pending seen result =
    match pending with
    | [] -> List.rev result
    | eid :: rest ->
      if List.mem eid seen then loop rest seen result
      else
        loop (children db eid @ rest) (eid :: seen) (eid :: result)
  in
  loop roots [] []

let page_entity db eid =
  (match Db.datoms db Ds.Eavt ~e:eid ~a:"block/name" () with
   | seq -> Seq.uncons seq <> None)
  || (match Db.datoms db Ds.Eavt ~e:eid ~a:"block/journal-day" () with
      | seq -> Seq.uncons seq <> None)

let would_create_cycle db moving_eid parent_eid =
  List.exists (fun eid -> eid = parent_eid) (subtree db [ moving_eid ])

let property_tx uuid attr = function
  | Some value -> Ds.Add (lookup uuid, attr, datascript_value value)
  | None -> Ds.RetractAttr (lookup uuid, attr)

let property_value db reference attr =
  match Ds.entity db reference with
  | Some entity -> (match Entity.entity_attr_raw entity attr with
      | Some (Ds.One_value value) -> Some value
      | Some (Ds.Many_values values) when values <> [] -> Some (Ds.Set values)
      | _ -> None)
  | None -> None

let property_txs db uuid attr value =
  let many = Option.fold ~none:false ~some:(fun spec -> spec.Ds.cardinality = Ds.Many)
      (List.assoc_opt attr db.Ds.schema) in
  match many, value with
  | true, Some (Ops.Set_value values) ->
    Ds.RetractAttr (lookup uuid, attr) :: List.map (fun value ->
      Ds.Add (lookup uuid, attr, datascript_value value)) values
  | _, value -> [property_tx uuid attr value]

let property_value_attrs db (value : Ops.pending_property_value) =
  let owner = lookup value.owner_uuid in
  let page = Option.value ~default:(Ds.Ref_to owner) (one_value db owner "block/page") in
  let content_attr = match value.content with Ops.String_value _ -> "block/title" | _ -> "logseq.property/value" in
  ["block/uuid", Ds.One_value (Ds.Uuid value.uuid);
   "block/page", Ds.One_value page;
   "block/parent", Ds.One_value (Ds.Ref_to owner);
   "block/order", Ds.One_value (Ds.String (Result.get_ok (Fractional_order.between None None)));
   "logseq.property/created-from-property", Ds.One_value (Ds.Ref_to (Ds.Ident value.property_ident));
   content_attr, Ds.One_value (datascript_value value.content);
   "block/created-at", Ds.One_value (Ds.Int64 (Int64.of_int value.created_at));
   "block/updated-at", Ds.One_value (Ds.Int64 (Int64.of_int value.created_at))]

let create_attrs db uuid title created_at =
  let attrs = [ ("block/uuid", Ds.One_value (Ds.Uuid uuid))
  ; ( "block/name"
    , Ds.One_value (Ds.String (String.lowercase_ascii title)) )
  ; ("block/title", Ds.One_value (Ds.String title))
  ; ("block/created-at", Ds.One_value (Ds.Int64 (Int64.of_int created_at)))
  ; ("block/updated-at", Ds.One_value (Ds.Int64 (Int64.of_int created_at)))
  ] in
  match Ds.entid db "db/ident" (Ds.Keyword "logseq.class/Page") with
  | Some eid -> ("block/tags", Ds.Many_values [Ds.Ref eid]) :: attrs
  | None -> attrs

(* Resolve pasted and directly typed page refs at the transaction boundary, so
   nested clipboard operations share the same creation and deduplication rules. *)
let resolve_page_references literal_blocks db intent =
  let created = ref [] and seen = Hashtbl.create 8 in
  let title uuid text =
    let literal = match Hashtbl.find_opt literal_blocks uuid with
      | Some literal -> literal
      | None -> Option.fold ~none:false ~some:(fun id ->
          List.mem (Graph_read.display_type_for_eid db id) [Some "code"; Some "math"])
          (Ds.entid db "block/uuid" (Ds.Uuid uuid)) in
    if literal then text else Ref_text.to_ids (fun name ->
      match Graph_read.unique_named_uuid false db name with
      | Some _ as uuid -> uuid
      | None ->
        let key = Node_title.name name in
        match Hashtbl.find_opt seen key with
        | Some uuid -> Some uuid
        | None ->
          let uuid = match Ds.squuid () with Ds.Uuid uuid -> uuid | _ -> assert false in
          Hashtbl.add seen key uuid;
          created := Ops.Create_page {uuid; title = name; created_at = int_of_float (Unix.gettimeofday () *. 1000.)} :: !created;
          Some uuid) (Graph_read.unique_named_uuid true db) text in
  let next = match intent with
    | Ops.Save_title value -> Ops.Save_title {value with title = title value.uuid value.title}
    | Ops.Insert_block value -> Ops.Insert_block {value with title = title value.uuid value.title}
    | Ops.Split_block value -> Ops.Split_block {value with before = title value.uuid value.before; after = title value.uuid value.after}
    | Ops.Merge_backward value -> Ops.Merge_backward {value with title = title value.uuid value.title}
    | Ops.Create_journal value -> Ops.Create_journal {value with block_title = title value.block_uuid value.block_title}
    | _ -> intent in
  if !created = [] then next else Ops.Atomic (List.rev !created @ [next])

let rec compile_with_literals literal_blocks db (intent : Ops.pending_intent) =
  let resolved = resolve_page_references literal_blocks db intent in
  if resolved <> intent then compile_with_literals literal_blocks db resolved else
  match intent with
  | Ops.Atomic intents ->
    if intents = [] then Error "atomic operation cannot be empty"
    else
      let ( let* ) = Result.bind in
      let* _, reversed = List.fold_left (fun result intent ->
        let* projected, reversed = result in
        let* tx = compile_with_literals literal_blocks projected intent in
        try Ok (Ds.db_with tx projected, List.rev_append tx reversed)
        with error -> Error (Printexc.to_string error)) (Ok (db, [])) intents in
      Ok (List.rev reversed)
  | Ops.Create_property_value value ->
    if Ds.entid db "block/uuid" (Ds.Uuid value.uuid) <> None then Error "property value UUID already exists"
    else if Ds.entid db "block/uuid" (Ds.Uuid value.owner_uuid) = None then Error "property owner no longer exists"
    else if Ds.entid db "db/ident" (Ds.Keyword value.property_ident) = None then Error "property no longer exists"
    else Ok [entity_tx (Ds.Temp_id ("pending/" ^ value.uuid)) (property_value_attrs db value)]
  | Ops.Save_title value ->
    (match
       string_value (one_value db (lookup value.uuid) "block/title")
     with
     | Some current ->
       if current = value.expected_title then
         let id = Option.get (Ds.entid db "block/uuid" (Ds.Uuid value.uuid)) in
         Result.map (fun () -> title_tx db value.uuid value.title) (Node_title.validate db id value.title)
       else Error "title changed on the server"
     | None -> Error "block no longer exists")
  | Ops.Set_property value ->
    if Ds.entid db "block/uuid" (Ds.Uuid value.uuid) = None then
      Error "block no longer exists"
    else if
      not
        (semantic_value_equal db
           (property_value db (lookup value.uuid) value.attr)
           value.expected)
    then Error "property changed on the server"
    else Ok (property_txs db value.uuid value.attr value.value)
  | Ops.Set_properties value ->
    if value.changes = [] then
      Error "property changes cannot be empty"
    else if Ds.entid db "block/uuid" (Ds.Uuid value.uuid) = None then
      Error "block no longer exists"
    else if
      not
        (List.for_all
           (fun (change : Ops.property_change) ->
             semantic_value_equal db
               (property_value db (lookup value.uuid) change.attr)
               change.expected)
           value.changes)
    then Error "property changed on the server"
    else
      Ok
        (List.concat_map
           (fun (change : Ops.property_change) ->
             property_txs db value.uuid change.attr change.value)
           value.changes)
  | Ops.Insert_block value ->
    if Ds.entid db "block/uuid" (Ds.Uuid value.uuid) <> None then
      Error "inserted block UUID already exists"
    else if
      Ds.entid db "block/uuid" (Ds.Uuid value.page_uuid) = None
      || Ds.entid db "block/uuid" (Ds.Uuid value.parent_uuid) = None
    then Error "insert parent or page no longer exists"
    else
      Ok
        (insert_tx db
           {
             Outliner.uuid = value.uuid;
             title = value.title;
             page_uuid = value.page_uuid;
             parent_uuid = value.parent_uuid;
             order = value.order;
           }
           value.created_at)
  | Ops.Create_asset value ->
    if Ds.entid db "block/uuid" (Ds.Uuid value.uuid) <> None then
      Error "asset block UUID already exists"
    else if
      Ds.entid db "block/uuid" (Ds.Uuid value.page_uuid) = None
      || Ds.entid db "block/uuid" (Ds.Uuid value.parent_uuid) = None
    then Error "asset parent or page no longer exists"
    else if
      Ds.entid db "db/ident" (Ds.Keyword "logseq.class/Asset") = None
    then Error "the graph does not define logseq.class/Asset"
    else if (match value.transcript with
      | None -> false
      | Some child -> child.uuid = value.uuid || child.parent_uuid <> value.uuid
        || child.page_uuid <> value.page_uuid
        || Ds.entid db "block/uuid" (Ds.Uuid child.uuid) <> None)
    then Error "asset transcript identity or location is invalid"
    else
      Ok
        ([
          entity_tx
            (Ds.Temp_id ("pending/" ^ value.uuid))
            [ ("block/uuid", Ds.One_value (Ds.Uuid value.uuid))
            ; ("block/title", Ds.One_value (Ds.String value.title))
            ; ( "block/page"
              , Ds.One_value (Ds.Ref_to (lookup value.page_uuid)) )
            ; ( "block/parent"
              , Ds.One_value (Ds.Ref_to (lookup value.parent_uuid)) )
            ; ("block/order", Ds.One_value (Ds.String value.order))
            ; ( "block/tags"
              , Ds.Many_values
                  [
                    Ds.Ref_to
                      (Ds.Lookup_ref
                         ("db/ident", Ds.Keyword "logseq.class/Asset"))
                  ] )
            ; ( "block/created-at"
              , Ds.One_value (Ds.Int64 (Int64.of_int value.created_at)) )
            ; ( "block/updated-at"
              , Ds.One_value (Ds.Int64 (Int64.of_int value.created_at)) )
            ; ( "logseq.property.asset/type"
              , Ds.One_value (Ds.String value.asset_type) )
            ; ( "logseq.property.asset/size"
              , Ds.One_value (Ds.Int64 (Int64.of_int value.asset_size)) )
            ; ( "logseq.property.asset/checksum"
              , Ds.One_value (Ds.String value.asset_checksum) )
            ; ( "logseq.property.asset/remote-metadata"
              , Ds.One_value
                  (Ds.Map
                     [
                       ( Ds.Keyword "checksum"
                       , Ds.String value.asset_checksum )
                     ; (Ds.Keyword "type", Ds.String value.asset_type)
                     ]) )
            ];
        ] @ (match value.transcript with
          | None -> []
          | Some child -> insert_tx db
              { Outliner.uuid = child.uuid; title = child.title; page_uuid = child.page_uuid;
                parent_uuid = child.parent_uuid; order = child.order } child.created_at))
  | Ops.Move_block value ->
    (match
       ( Ds.entid db "block/uuid" (Ds.Uuid value.uuid)
       , Ds.entid db "block/uuid" (Ds.Uuid value.page_uuid)
       , Ds.entid db "block/uuid" (Ds.Uuid value.parent_uuid) )
     with
     | Some moving_eid, Some _, Some parent_eid ->
       if would_create_cycle db moving_eid parent_eid then
         Error "move would create an outliner cycle"
       else
         Ok
           [
             Ds.Add
               ( lookup value.uuid
               , "block/page"
               , Ds.Ref_to (lookup value.page_uuid) )
           ; Ds.Add
               ( lookup value.uuid
               , "block/parent"
               , Ds.Ref_to (lookup value.parent_uuid) )
           ; Ds.Add
               (lookup value.uuid, "block/order", Ds.String value.order)
           ]
     | _ -> Error "move target no longer exists")
  | Ops.Move_blocks value ->
    if value.moves = [] then Error "move batch must not be empty"
    else
      let rec loop projected tx (moves : Ops.pending_move list) =
        match moves with
        | [] -> Ok tx
        | move :: rest ->
          (match compile_with_literals literal_blocks projected (Ops.Move_block move) with
           | Ok step ->
             loop (Ds.db_with step projected) (tx @ step) rest
           | Error _ as error -> error)
      in
      loop db [] value.moves
  | Ops.Split_block value ->
    compile_outliner db
      (Outliner.Split
         {
           Outliner.source_uuid = value.uuid;
           expected_title = value.expected_title;
           before = value.before;
           after = value.after;
           new_uuid = value.new_uuid;
           new_order = value.new_order;
           created_at = value.created_at;
         })
  | Ops.Merge_backward value ->
    compile_outliner db
      (Outliner.Merge_backward
         {
           Outliner.source_uuid = value.uuid;
           expected_source_title = value.expected_title;
           source_title = value.title;
           previous_uuid = value.previous_uuid;
           expected_previous_title = value.expected_previous_title;
           merged_title = value.merged_title;
         })
  | Ops.Delete_blocks value ->
    let roots =
      List.filter_map
        (fun uuid -> Ds.entid db "block/uuid" (Ds.Uuid uuid))
        value.uuids
    in
    if roots = [] then Error "block no longer exists"
    else if List.exists (fun eid -> page_entity db eid) roots then
      Error "ordinary block delete cannot delete a page"
    else
      Ok
        (List.map
           (fun eid -> Ds.RetractEntity (Ds.Entity_id eid))
           (subtree db roots))
  | Ops.Create_page value ->
    if Ds.entid db "block/uuid" (Ds.Uuid value.uuid) <> None then Ok []
    else
      Ok
        [
          entity_tx
            (Ds.Temp_id ("pending/" ^ value.uuid))
            (create_attrs db value.uuid value.title value.created_at);
        ]
  | Ops.Create_tag value ->
    if Ds.entid db "block/uuid" (Ds.Uuid value.uuid) <> None then Ok []
    else if
      Ds.entid db "db/ident" (Ds.Keyword "logseq.class/Tag") = None
    then Error "the graph does not define logseq.class/Tag"
    else if
      Ds.entid db "db/ident" (Ds.Keyword "logseq.class/Root") = None
    then Error "the graph does not define logseq.class/Root"
    else
      Ok
        [
          entity_tx
            (Ds.Temp_id ("pending/" ^ value.uuid))
            [
              ("block/uuid", Ds.One_value (Ds.Uuid value.uuid))
            ; ( "db/ident"
              , Ds.One_value
                  (Ds.Keyword ("user.class/tag-" ^ value.uuid)) )
            ; ( "block/name"
              , Ds.One_value
                  (Ds.String (String.lowercase_ascii value.title)) )
            ; ("block/title", Ds.One_value (Ds.String value.title))
            ; ( "block/tags"
              , Ds.Many_values
                  [
                    Ds.Ref_to
                      (Ds.Lookup_ref
                         ("db/ident", Ds.Keyword "logseq.class/Tag"))
                  ] )
            ; ( "logseq.property.class/extends"
              , Ds.Many_values
                  [
                    Ds.Ref_to
                      (Ds.Lookup_ref
                         ("db/ident", Ds.Keyword "logseq.class/Root"))
                  ] )
            ; ( "block/created-at"
              , Ds.One_value (Ds.Int64 (Int64.of_int value.created_at)) )
            ; ( "block/updated-at"
              , Ds.One_value (Ds.Int64 (Int64.of_int value.created_at)) )
            ];
        ]
  | Ops.Create_journal value ->
    let existing_page = journal_page_eid db value.journal_day in
    let page_ref, page_tx =
      match existing_page with
      | Some eid -> (Ds.Entity_id eid, [])
      | None ->
        let reference = Ds.Temp_id ("pending/" ^ value.page_uuid) in
        let attrs =
          [
            ("block/uuid", Ds.One_value (Ds.Uuid value.page_uuid))
          ; ( "block/name"
            , Ds.One_value
                (Ds.String (String.lowercase_ascii value.title)) )
          ; ("block/title", Ds.One_value (Ds.String value.title))
          ; ( "block/journal-day"
            , Ds.One_value (Ds.Int64 (Int64.of_int value.journal_day)) )
          ; ( "block/created-at"
            , Ds.One_value (Ds.Int64 (Int64.of_int value.created_at)) )
          ; ( "block/updated-at"
            , Ds.One_value (Ds.Int64 (Int64.of_int value.created_at)) )
          ]
        in
        let attrs =
          if
            Ds.entid db "db/ident" (Ds.Keyword "logseq.class/Journal")
            <> None
          then
            attrs
            @ [
                ( "block/tags"
                , Ds.Many_values
                    [
                      Ds.Ref_to
                        (Ds.Lookup_ref
                           ("db/ident", Ds.Keyword "logseq.class/Journal"))
                    ] )
              ]
          else attrs
        in
        (reference, [ entity_tx reference attrs ])
    in
    (match Ds.entid db "block/uuid" (Ds.Uuid value.block_uuid) with
     | Some block_eid ->
       let belongs attr =
         match (existing_page, one_value db (Ds.Entity_id block_eid) attr) with
         | Some page_eid, Some value ->
           Datascript_value.ref_eid db attr value = Some page_eid
         | _ -> false
       in
       if belongs "block/page" && belongs "block/parent" then
         Ok page_tx
       else
         Error "journal block UUID already exists outside the journal"
     | None ->
       Ok
         (page_tx
          @ [
              entity_tx
                (Ds.Temp_id ("pending/" ^ value.block_uuid))
                ([
                  ("block/uuid", Ds.One_value (Ds.Uuid value.block_uuid))
                ; ("block/title", Ds.One_value (Ds.String value.block_title))
                ; ("block/page", Ds.One_value (Ds.Ref_to page_ref))
                ; ("block/parent", Ds.One_value (Ds.Ref_to page_ref))
                ; ("block/order", Ds.One_value (Ds.String "a0"))
                ; ( "block/created-at"
                  , Ds.One_value (Ds.Int64 (Int64.of_int value.created_at)) )
                ; ( "block/updated-at"
                  , Ds.One_value (Ds.Int64 (Int64.of_int value.created_at)) )
                ] @ many_refs "block/refs" (refs_for_title db value.block_title)
                  @ many_refs "block/tags" (tag_eids_for_title db value.block_title));
            ] @ List.concat_map (tag_behavior_tx db value.block_uuid) (tag_eids_for_title db value.block_title)))
  | Ops.Add_tag value ->
    (match
       ( Ds.entid db "block/uuid" (Ds.Uuid value.uuid)
       , Ds.entid db "block/uuid" (Ds.Uuid value.tag_uuid) )
     with
     | Some block_eid, Some tag_eid ->
       Ok
         ((if has_ref db block_eid "block/tags" tag_eid then []
           else [ Ds.Add (lookup value.uuid, "block/tags", Ds.Ref tag_eid) ])
          @ tag_behavior_tx db value.uuid tag_eid)
     | None, _ -> Error "block no longer exists"
     | _ -> Error "tag no longer exists")
  | Ops.Set_favorite value ->
    (match
       ( favorite_page_eid db
       , Ds.entid db "block/uuid" (Ds.Uuid value.page_uuid) )
     with
     | None, _ -> Error "favorites page is missing"
     | _, None -> Error "page no longer exists"
     | Some favorites_eid, Some page_eid ->
       (match (value.favorite, favorite_block_eid db value.page_uuid) with
        | true, Some _ -> Ok []
        | false, None -> Ok []
        | false, Some favorite_eid ->
          Ok [ Ds.RetractEntity (Ds.Entity_id favorite_eid) ]
        | true, None ->
          if
            Ds.entid db "block/uuid" (Ds.Uuid value.favorite_uuid)
            <> None
          then Error "favorite block UUID already exists"
          else
            Ok
              [
                entity_tx
                  (Ds.Temp_id ("pending/" ^ value.favorite_uuid))
                  [
                    ( "block/uuid"
                    , Ds.One_value (Ds.Uuid value.favorite_uuid) )
                  ; ("block/title", Ds.One_value (Ds.String ""))
                  ; ("block/page", Ds.One_value (Ds.Ref favorites_eid))
                  ; ( "block/parent"
                    , Ds.One_value (Ds.Ref favorites_eid) )
                  ; ("block/link", Ds.One_value (Ds.Ref page_eid))
                  ; ( "block/order"
                    , Ds.One_value (Ds.String value.order) )
                  ; ( "block/created-at"
                    , Ds.One_value (Ds.Int64 (Int64.of_int value.created_at)) )
                  ; ( "block/updated-at"
                    , Ds.One_value (Ds.Int64 (Int64.of_int value.created_at)) )
                  ];
              ]))
  | Ops.Delete_page value ->
    (match
       ( Ds.entid db "block/uuid" (Ds.Uuid value.page_uuid)
       , recycle_page_eid db )
     with
     | None, _ -> Error "page no longer exists"
     | _, None -> Error "Recycle page is missing"
     | Some page_eid, Some recycle_eid ->
       let reference = Ds.Entity_id page_eid in
       if
         one_value db reference "logseq.property/deleted-at" <> None
         && Datascript_value.optional_ref_eid db "block/parent"
              (one_value db reference "block/parent")
            = Some recycle_eid
       then Ok []
       else if
         not (Node_title.can_delete db page_eid)
       then Error "Built-in page cannot be deleted"
       else
         let parent =
           match one_value db reference "block/parent" with
           | Some (Ds.Ref eid) ->
             [
               ( "logseq.property.recycle/original-parent"
               , Ds.One_value (Ds.Ref eid) )
             ]
           | Some (Ds.Int64 eid) ->
             [
               ( "logseq.property.recycle/original-parent"
               , Ds.One_value (Ds.Ref (Int64.to_int eid)) )
             ]
           | _ -> []
         in
         let order =
           match one_value db reference "block/order" with
           | Some (Ds.String order) ->
             [
               ( "logseq.property.recycle/original-order"
               , Ds.One_value (Ds.String order) )
             ]
           | _ -> []
         in
         Ok
           [
             entity_tx
               (lookup value.page_uuid)
               ([
                  ("block/parent", Ds.One_value (Ds.Ref recycle_eid))
                ; ( "block/order"
                  , Ds.One_value (Ds.String value.order) )
                ; ( "logseq.property/deleted-at"
                  , Ds.One_value (Ds.Int64 (Int64.of_int value.deleted_at)) )
                ; ( "logseq.property.recycle/original-page"
                  , Ds.One_value (Ds.Ref page_eid) )
                ]
                @ parent
                @ order);
           ])

let compile db intent =
  let literal_blocks = Hashtbl.create 8 in
  let display_type uuid attr value =
    if attr = "logseq.property.node/display-type" then
      Hashtbl.replace literal_blocks uuid (match value with
        | Some (Ops.Keyword_value ("code" | "math")) -> true | _ -> false) in
  let rec scan = function
    | Ops.Atomic intents -> List.iter scan intents
    | Ops.Set_property value -> display_type value.uuid value.attr value.value
    | Ops.Set_properties value -> List.iter (fun (change : Ops.property_change) ->
        display_type value.uuid change.attr change.value) value.changes
    | _ -> () in
  scan intent;
  compile_with_literals literal_blocks db intent

let block_location_matches db uuid page_uuid parent_uuid order =
  Ds.entid db "block/uuid" (Ds.Uuid uuid) <> None
  && semantic_value_equal db
       (one_value db (lookup uuid) "block/page")
       (Some (Ops.Ref_uuid page_uuid))
  && semantic_value_equal db
       (one_value db (lookup uuid) "block/parent")
       (Some (Ops.Ref_uuid parent_uuid))
  && string_value (one_value db (lookup uuid) "block/order")
     = Some order

let rec satisfied db (intent : Ops.pending_intent) =
  match intent with
  | Ops.Atomic intents -> intents <> [] && List.for_all (satisfied db) intents
  | Ops.Create_property_value value ->
    let content_attr = match value.content with Ops.String_value _ -> "block/title" | _ -> "logseq.property/value" in
    semantic_value_equal db (one_value db (lookup value.uuid) content_attr) (Some value.content)
    && semantic_value_equal db (one_value db (lookup value.uuid) "block/parent") (Some (Ops.Ref_uuid value.owner_uuid))
    && semantic_value_equal db (one_value db (lookup value.uuid) "logseq.property/created-from-property")
         (Some (Ops.Ref_ident value.property_ident))
  | Ops.Save_title value ->
    string_value (one_value db (lookup value.uuid) "block/title")
    = Some value.title
  | Ops.Set_property value ->
    semantic_value_equal db
      (property_value db (lookup value.uuid) value.attr)
      value.value
  | Ops.Set_properties value ->
    value.changes <> []
    && List.for_all
         (fun (change : Ops.property_change) ->
           semantic_value_equal db
             (property_value db (lookup value.uuid) change.attr)
             change.value)
         value.changes
  | Ops.Insert_block value ->
    block_location_matches db value.uuid value.page_uuid
      value.parent_uuid value.order
    && string_value (one_value db (lookup value.uuid) "block/title")
       = Some value.title
  | Ops.Create_asset value ->
    let reference = lookup value.uuid in
    block_location_matches db value.uuid value.page_uuid
      value.parent_uuid value.order
    && string_value (one_value db reference "block/title")
       = Some value.title
    && string_value
         (one_value db reference "logseq.property.asset/type")
       = Some value.asset_type
    && one_value db reference "logseq.property.asset/size"
       = Some (Ds.Int64 (Int64.of_int value.asset_size))
    && string_value
         (one_value db reference "logseq.property.asset/checksum")
       = Some value.asset_checksum
    && semantic_value_equal db
         (one_value db reference "logseq.property.asset/remote-metadata")
         (Some
            (Ops.Map_value
               [
                 ("checksum", Ops.String_value value.asset_checksum)
               ; ("type", Ops.String_value value.asset_type)
               ]))
    && (match value.transcript with None -> true | Some child -> satisfied db (Ops.Insert_block child))
  | Ops.Move_block value ->
    block_location_matches db value.uuid value.page_uuid
      value.parent_uuid value.order
  | Ops.Move_blocks value ->
    value.moves <> []
    && List.for_all
         (fun move -> satisfied db (Ops.Move_block move))
         value.moves
  | Ops.Split_block value ->
    string_value (one_value db (lookup value.uuid) "block/title")
    = Some value.before
    && string_value (one_value db (lookup value.new_uuid) "block/title")
       = Some value.after
    && string_value (one_value db (lookup value.new_uuid) "block/order")
       = Some value.new_order
  | Ops.Merge_backward value ->
    Ds.entid db "block/uuid" (Ds.Uuid value.uuid) = None
    && string_value
         (one_value db (lookup value.previous_uuid) "block/title")
       = Some
           (match value.merged_title with
            | Some title -> title
            | None -> value.expected_previous_title ^ value.title)
  | Ops.Delete_blocks value ->
    List.for_all
      (fun uuid -> Ds.entid db "block/uuid" (Ds.Uuid uuid) = None)
      value.uuids
  | Ops.Create_tag value | Ops.Create_page value ->
    Ds.entid db "block/uuid" (Ds.Uuid value.uuid) <> None
  | Ops.Create_journal value ->
    (match
       ( journal_page_eid db value.journal_day
       , Ds.entid db "block/uuid" (Ds.Uuid value.block_uuid) )
     with
     | Some page_eid, Some block_eid ->
       List.for_all
         (fun attr ->
           Datascript_value.optional_ref_eid db attr
             (one_value db (Ds.Entity_id block_eid) attr)
           = Some page_eid)
         [ "block/page"; "block/parent" ]
     | _ -> false)
  | Ops.Add_tag value ->
    (match
       ( Ds.entid db "block/uuid" (Ds.Uuid value.uuid)
       , Ds.entid db "block/uuid" (Ds.Uuid value.tag_uuid) )
     with
     | Some block_eid, Some tag_eid ->
       has_ref db block_eid "block/tags" tag_eid
     | _ -> false)
  | Ops.Set_favorite value ->
    (favorite_block_eid db value.page_uuid <> None) = value.favorite
  | Ops.Delete_page value ->
    (match
       ( Ds.entid db "block/uuid" (Ds.Uuid value.page_uuid)
       , recycle_page_eid db )
     with
     | Some page_eid, Some recycle_eid ->
       one_value db (Ds.Entity_id page_eid) "logseq.property/deleted-at"
       <> None
       && Datascript_value.optional_ref_eid db "block/parent"
            (one_value db (Ds.Entity_id page_eid) "block/parent")
          = Some recycle_eid
     | _ -> false)

let build server_t authoritative operations =
  List.fold_left
    (fun snapshot (operation : Ops.pending_operation) ->
      let db, state =
        match operation.state with
        | Ops.Conflicted message ->
          (snapshot.db, Ops.Conflicted message)
        | _ ->
          (match compile snapshot.db operation.intent with
           | Ok tx -> (Ds.db_with tx snapshot.db, Ops.Applied)
           | Error message -> (snapshot.db, Ops.Conflicted message))
      in
      {
        snapshot with
        db;
        statuses =
          snapshot.statuses @ [ (operation.operation_id, state) ];
      })
    { db = authoritative; server_t; statuses = [] }
    operations
