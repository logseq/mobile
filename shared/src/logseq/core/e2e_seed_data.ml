module Model = Cache_model
module Journal = Journal
module Ds = Datascript

let tag_uuid = "e2e00000-0000-4000-8000-000000000001"
let source_uuid = "e2e00000-0000-4000-8000-000000000002"
let older_block_uuid = "e2e00000-0000-4000-8000-000000000003"
let trailing_tag_uuid = "e2e00000-0000-4000-8000-000000000004"
let child_tag_uuid = "e2e00000-0000-4000-8000-000000000005"
let flashcard_uuid = "e2e00000-0000-4000-8000-000000000020"
let flashcard_answer_uuid = "e2e00000-0000-4000-8000-000000000021"
let header_navigation_page_uuid = "e2e00000-0000-4000-8000-000000000030"
let header_navigation_block_uuid = "e2e00000-0000-4000-8000-000000000031"
let composer_page_uuid = "e2e30000-0000-4000-8000-000000000001"
let composer_block_uuid = "e2e30000-0000-4000-8000-000000000002"
let outliner_page_uuid = "e2e30000-0000-4000-8000-000000000003"
let outliner_block_uuid = "e2e30000-0000-4000-8000-000000000004"
let outliner_tag_uuid = "e2e30000-0000-4000-8000-000000000005"

let entity_has_attr db eid attr =
  not (Seq.is_empty (Ds.Db.datoms db Ds.Eavt ~e:eid ~a:attr ()))

let entity_built_in db eid =
  Ds.Db.datoms db Ds.Eavt ~e:eid ~a:"logseq.property/built-in?" ()
  |> Seq.exists (fun (datom : Ds.datom) -> datom.v = Ds.Bool true)

let transact conn operations =
  ignore (Ds.transact_conn conn operations : Ds.tx_report)

let reset_user_page_entities conn =
  let db = Ds.conn_db conn in
  let operations =
    Ds.Db.datoms db Ds.Aevt ~a:"block/uuid" ()
    |> List.of_seq
    |> List.filter_map (fun (datom : Ds.datom) ->
           if
             (entity_has_attr db datom.e "block/journal-day"
              || entity_has_attr db datom.e "block/page")
             && not (entity_built_in db datom.e)
           then Some (Ds.RetractEntity (Ds.Entity_id datom.e))
           else None)
  in
  if operations <> [] then transact conn operations

let uuid_attr value = Ds.One_value (Ds.Uuid value)
let string_attr value = Ds.One_value (Ds.String value)
let int_attr value = Ds.One_value (Ds.Int64 (Int64.of_int value))
let ref_attr id = Ds.One_value (Ds.Ref_to (Ds.Temp_id id))

let many_refs ids =
  Ds.Many_values (List.map (fun id -> Ds.Ref_to (Ds.Temp_id id)) ids)

let entity id attrs =
  Ds.Entity
    {
      Ds.db_id = Option.map (fun id -> Ds.Temp_id id) id;
      attrs;
    }

let assoc_attr name value attrs =
  (name, value)
  :: List.filter (fun (attr, _) -> attr <> name) attrs

let page_attrs uuid name title day now =
  [
    ("block/uuid", uuid_attr uuid);
    ("block/name", string_attr name);
    ("block/title", string_attr title);
    ("block/journal-day", int_attr day);
    ("block/created-at", int_attr now);
    ("block/updated-at", int_attr now);
  ]

let block_attrs uuid title parent order now =
  [
    ("block/uuid", uuid_attr uuid);
    ("block/title", string_attr title);
    ("block/page", ref_attr parent);
    ("block/parent", ref_attr parent);
    ("block/order", string_attr order);
    ("block/created-at", int_attr now);
    ("block/updated-at", int_attr now);
  ]

let seed_current_journal conn now page_uuid block_uuid title =
  let day = Model.journal_day_for_ms now in
  let page_title = Journal.day_title day in
  transact conn
    [
      entity (Some "e2e-current-page")
        (page_attrs page_uuid
           (String.lowercase_ascii page_title)
           page_title day now);
      entity None
        (block_attrs block_uuid title "e2e-current-page" "a0" now);
    ]

let attempt label f =
  try
    f ();
    Ok ()
  with error -> Error (label ^ Printexc.to_string error)

let seed_composer conn now =
  attempt "Seed iOS composer graph: " (fun () ->
      reset_user_page_entities conn;
      seed_current_journal conn now composer_page_uuid composer_block_uuid
        "E2E Composer Fixture")

let page_uuid index =
  Printf.sprintf "e2e10000-0000-4000-8000-%012d" index

let block_uuid index =
  Printf.sprintf "e2e20000-0000-4000-8000-%012d" index

let seed_header_navigation conn =
  attempt "Seed iOS header-navigation graph: " (fun () ->
      transact conn
        [
          entity (Some "e2e-header-navigation-page")
            (page_attrs header_navigation_page_uuid "aug 24th, 2026"
               "Aug 24th, 2026" 20260824 50000);
          entity None
            (block_attrs header_navigation_block_uuid
               "E2E Header Navigation" "e2e-header-navigation-page" "a0"
               50001);
        ])

let journal_entities =
  List.concat_map
    (fun number ->
      let parent = "e2e-journal-" ^ string_of_int number in
      let page_title =
        if number = 7 then "E2E Page Target"
        else Printf.sprintf "E2E Journal %02d" number
      in
      let title =
        match number with
        | 7 -> "E2E Block Target"
        | 1 -> "E2E Earlier Journal Block"
        | 6 -> "E2E Child Tag Object"
        | _ -> Printf.sprintf "E2E Journal Block %02d" number
      in
      let attrs =
        block_attrs
          (if number = 1 then older_block_uuid else block_uuid number)
          title parent "a0" (20000 + number)
      in
      [
        entity (Some parent)
          (assoc_attr "block/updated-at"
             (int_attr (if number = 8 then 2000000000001 else 10000 + number))
             (page_attrs (page_uuid number) parent page_title
                (20260809 + number) (10000 + number)));
        entity (Some ("e2e-block-" ^ string_of_int number))
          (if number = 6 then
             assoc_attr "block/tags" (many_refs [ "e2e-child-tag" ]) attrs
           else attrs);
      ])
    (List.init 8 (fun i -> i + 1))

let rich_block_titles =
  [
    "> E2E Rich Quote";
    "$$E = mc^2$$";
    "```swift\nlet answer = 42\n```";
    "{{video https://www.youtube.com/watch?v=dQw4w9WgXcQ}}";
    "{{iframe https://example.com}}";
    "E2E before {{video https://www.youtube.com/watch?v=dQw4w9WgXcQ}} E2E after";
    "{{youtube-timestamp 01:23}}";
  ]

let rich_block_entities =
  List.mapi
    (fun index title ->
      entity (Some ("e2e-rich-block-" ^ string_of_int index))
        (block_attrs (block_uuid (100 + index)) title "e2e-journal-8"
           (Printf.sprintf "a%d" (index + 2))
           (30000 + index)))
    rich_block_titles

let tag_attrs uuid name title =
  [
    ("block/uuid", uuid_attr uuid);
    ("block/name", string_attr name);
    ("block/title", string_attr title);
    ("block/tags", many_refs [ "e2e-tag-class" ]);
  ]

let seed conn =
  attempt "Seed iOS E2E graph: " (fun () ->
      let existing =
        Ds.Db.datoms (Ds.conn_db conn) Ds.Aevt ~a:"block/name"
          ~v:(Ds.String "$$$favorites") ()
        |> Seq.uncons
      in
      let favorites =
        match existing with
        | Some _ -> []
        | None ->
          [
            entity (Some "e2e-favorites-page")
              [
                ( "block/uuid"
                , uuid_attr "e2e00000-0000-4000-8000-000000000010" );
                ("block/name", string_attr "$$$favorites");
                ("block/title", string_attr "Favorites");
              ];
          ]
      in
      let favorite_ref =
        match existing with
        | Some (datom, _) -> Ds.One_value (Ds.Ref datom.Ds.e)
        | None -> ref_attr "e2e-favorites-page"
      in
      let title =
        Printf.sprintf "E2E links [[%s]] [[%s]] #[[%s]] and ((plain text))"
          (page_uuid 7) (block_uuid 7) tag_uuid
      in
      transact conn
        (journal_entities @ rich_block_entities @ favorites
        @ [
            entity (Some "e2e-favorite-page-target")
              [
                ( "block/uuid"
                , uuid_attr "e2e00000-0000-4000-8000-000000000011" );
                ("block/title", string_attr "");
                ("block/page", favorite_ref);
                ("block/link", ref_attr "e2e-journal-7");
                ("block/order", string_attr "a0");
              ];
            entity (Some "e2e-tag-class")
              [
                ( "db/ident"
                , Ds.One_value (Ds.Keyword "logseq.class/Tag") );
              ];
            entity (Some "e2e-tag")
              (tag_attrs tag_uuid "e2e-project" "E2E Project");
            entity (Some "e2e-trailing-tag")
              (tag_attrs trailing_tag_uuid "e2e-trailing" "E2E Trailing");
            entity (Some "e2e-child-tag")
              (assoc_attr "logseq.property.class/extends"
                 (many_refs [ "e2e-tag" ])
                 (tag_attrs child_tag_uuid "e2e-child-project"
                    "E2E Child Project"));
            entity None
              (assoc_attr "block/tags"
                 (many_refs [ "e2e-tag"; "e2e-trailing-tag" ])
                 (assoc_attr "block/refs"
                    (many_refs [ "e2e-journal-7"; "e2e-block-7" ])
                    (block_attrs source_uuid title "e2e-journal-8" "a1"
                       2000000000000)));
            entity None
              (assoc_attr "block/refs"
                 (many_refs [ "e2e-tag" ])
                 (block_attrs "e2e00000-0000-4000-8000-000000000006"
                    "E2E explicit tag page reference" "e2e-journal-8" "a8"
                    2000000000002));
            entity (Some "e2e-card-class")
              [
                ( "db/ident"
                , Ds.One_value (Ds.Keyword "logseq.class/Card") );
              ];
            entity (Some "e2e-flashcard")
              (assoc_attr "block/tags"
                 (many_refs [ "e2e-card-class" ])
                 (block_attrs flashcard_uuid
                    "The capital of France is {{cloze Paris}}"
                    "e2e-journal-8" "a9" 40000));
            entity None
              (assoc_attr "block/parent" (ref_attr "e2e-flashcard")
                 (block_attrs flashcard_answer_uuid "Paris is the answer"
                    "e2e-journal-8" "a0" 40001));
          ]))

let seed_outliner conn now =
  attempt "Seed iOS outliner graph: " (fun () ->
      reset_user_page_entities conn;
      seed_current_journal conn now outliner_page_uuid outliner_block_uuid
        "E2E Outliner Fixture";
      transact conn
        [
          entity (Some "e2e-outliner-tag-class")
            [
              ( "db/ident"
              , Ds.One_value (Ds.Keyword "logseq.class/Tag") );
            ];
          entity None
            [
              ("block/uuid", uuid_attr outliner_tag_uuid);
              ("block/name", string_attr "e2e-outliner-tag");
              ("block/title", string_attr "E2E Outliner Tag");
              ("block/tags", many_refs [ "e2e-outliner-tag-class" ]);
            ];
        ])

let seed_fixture conn =
  reset_user_page_entities conn;
  seed conn

let performance_page_uuid index =
  Printf.sprintf "e2f10000-0000-4000-8000-%012x" (index + 1)

let performance_block_uuid page_index block_index =
  Printf.sprintf "e2f20000-0000-4000-8000-%012x"
    (((page_index + 1) * 100) + block_index + 1)

let performance_block_title page_index block_index =
  let row = Printf.sprintf "%03d-%02d" (page_index + 1) (block_index + 1) in
  match block_index mod 4 with
  | 0 ->
    Printf.sprintf "Performance row %s with **bold text** and `inline code`"
      row
  | 1 ->
    Printf.sprintf
      "> Performance quote %s with enough text to exercise wrapping" row
  | 2 ->
    Printf.sprintf "$$x_%d + y_%d = z_%d$$" page_index block_index
      (page_index + block_index)
  | _ -> Printf.sprintf "```swift\nlet performanceRow = \"%s\"\n```" row

let seed_performance_sized conn now journal_count block_count =
  attempt "Seed iOS performance graph: " (fun () ->
      let orders =
        match Fractional_order.n_between None None block_count with
        | Ok values -> Array.of_list values
        | Error message -> failwith message
      in
      reset_user_page_entities conn;
      transact conn
        (List.concat_map
           (fun page_index ->
             let parent = "performance-page-" ^ string_of_int page_index in
             let time = now - (page_index * 86400000) in
             let day = Model.journal_day_for_ms time in
             let title = Journal.day_title day in
             entity (Some parent)
               (page_attrs (performance_page_uuid page_index)
                  (String.lowercase_ascii title)
                  title day time)
             :: List.init block_count (fun block_index ->
                    entity None
                      (block_attrs
                         (performance_block_uuid page_index block_index)
                         (performance_block_title page_index block_index)
                         parent
                         orders.(block_index)
                         (time + block_index + 1))))
           (List.init journal_count Fun.id)))

let seed_performance conn now = seed_performance_sized conn now 100 8
