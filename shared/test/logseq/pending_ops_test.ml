open Test_util

module Ops = Pending_ops
module Ds = Datascript
module Json = Yojson.Basic

let move_value uuid : Ops.pending_move =
  { uuid; page_uuid = "page"; parent_uuid = "parent"; order = "a0" }

let move uuid = Ops.Move_block (move_value uuid)

let intents : Ops.pending_intent list =
  [
    Ops.Save_title
      { uuid = "block"; expected_title = "Old"; title = "New" };
    Ops.Set_property
      {
        uuid = "block";
        attr = "user.property/effort";
        expected = Some (Ops.Int_value 1);
        value = Some (Ops.Int_value 2);
      };
    Ops.Set_property
      {
        uuid = "block";
        attr = "user.property/flag";
        expected = None;
        value = None;
      };
    Ops.Set_properties
      {
        uuid = "block";
        changes =
          [
            {
              Ops.attr = "logseq.property.fsrs/due";
              expected = None;
              value = Some (Ops.Int_value 86400000);
            };
            {
              Ops.attr = "logseq.property.fsrs/state";
              expected = None;
              value =
                Some
                  (Ops.Map_value
                     [
                       ("state", Ops.Keyword_value "learning");
                       ("stability", Ops.Float_value 0.4);
                       ("reps", Ops.Int_value 1);
                     ]);
            };
          ];
      };
    Ops.Insert_block
      {
        uuid = "new";
        title = "New";
        page_uuid = "page";
        parent_uuid = "parent";
        order = "a1";
        created_at = 42;
      };
    Ops.Create_asset
      {
        uuid = "asset";
        title = "photo.png";
        page_uuid = "page";
        parent_uuid = "parent";
        order = "a2";
        created_at = 43;
        asset_type = "png";
        asset_size = 2048;
        asset_checksum = "abc123";
        transcript = None;
      };
    move "block";
    Ops.Move_blocks { moves = [ move_value "first"; move_value "second" ] };
    Ops.Split_block
      {
        uuid = "block";
        expected_title = "Old";
        before = "O";
        after = "ld";
        new_uuid = "new";
        new_order = "a1";
        created_at = 42;
      };
    Ops.Merge_backward
      {
        uuid = "source";
        expected_title = "Source";
        title = "Source";
        previous_uuid = "previous";
        expected_previous_title = "Previous";
        merged_title = Some "PreviousSource";
      };
    Ops.Merge_backward
      {
        uuid = "source";
        expected_title = "Source";
        title = "Source";
        previous_uuid = "previous";
        expected_previous_title = "Previous";
        merged_title = None;
      };
    Ops.Delete_blocks { uuids = [ "first"; "second" ] };
    Ops.Create_tag { uuid = "tag"; title = "Project"; created_at = 42 };
  ]

let page_intents : Ops.pending_intent list =
  [
    Ops.Create_page { uuid = "page"; title = "Page"; created_at = 42 };
    Ops.Create_journal
      {
        page_uuid = "page";
        block_uuid = "block"; block_title = "";
        title = "Journal";
        journal_day = 20260915;
        created_at = 43;
      };
    Ops.Add_tag { uuid = "block"; tag_uuid = "tag" };
    Ops.Set_favorite
      {
        page_uuid = "page";
        favorite_uuid = "favorite";
        favorite = true;
        order = "a0";
        created_at = 44;
      };
    Ops.Set_favorite
      {
        page_uuid = "page";
        favorite_uuid = "favorite";
        favorite = false;
        order = "a0";
        created_at = 44;
      };
    Ops.Delete_page
      { page_uuid = "page"; order = "a0"; deleted_at = 45 };
  ]

let all_intents = intents @ page_intents

let search_refresh_targets_cover_every_intent () =
  let db = Ds.empty_db ~schema:[] () in
  let expected =
    [
      [ "block" ];
      [];
      [];
      [];
      [ "new" ];
      [ "asset" ];
      [ "block" ];
      [ "first"; "second" ];
      [ "block"; "new" ];
      [ "source"; "previous" ];
      [ "source"; "previous" ];
      [ "first"; "second" ];
      [ "tag" ];
      [ "page" ];
      [ "page"; "block" ];
      [ "block" ];
      [ "page"; "favorite" ];
      [ "page"; "favorite" ];
      [ "page" ];
    ]
  in
  List.iter2
    (fun intent targets ->
      check_eq (Ops.affected_uuids db intent) targets)
    all_intents expected

let search_refresh_ignores_unrelated_properties () =
  let db = Ds.empty_db ~schema:[] () in
  let change : Ops.pending_property =
    {
      uuid = "block";
      attr = "logseq.property/status";
      expected = None;
      value = None;
    }
  in
  check_eq (Ops.affected_uuids db (Ops.Set_property change)) [];
  List.iter
    (fun attr ->
      check_eq
        (Ops.affected_uuids db
           (Ops.Set_property { change with Ops.attr }))
        [ "block" ])
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
    ];
  check_eq
    (Ops.affected_uuids db
       (Ops.Set_properties
          {
            uuid = "block";
            changes =
              [
                { Ops.attr = "custom"; expected = None; value = None };
                { Ops.attr = "block/title"; expected = None; value = None };
              ];
          }))
    [ "block" ]

let uuid_attr : Ds.schema_attr =
  {
    cardinality = Ds.One;
    unique = Some Ds.Identity;
    indexed = true;
    is_component = false;
    no_history = false;
    doc = None;
    value_type = Some Ds.UuidType;
    tuple_attrs = None;
    tuple_types = None;
  }

let deleted_search_targets_include_descendants_and_missing_roots () =
  let db =
    Ds.db_with
      [
        Ds.Add (Ds.Entity_id 1, "block/uuid", Ds.Uuid "root");
        Ds.Add (Ds.Entity_id 2, "block/uuid", Ds.Uuid "child");
        Ds.Add (Ds.Entity_id 2, "block/parent", Ds.Ref 1);
        Ds.Add (Ds.Entity_id 3, "block/uuid", Ds.Uuid "grandchild");
        Ds.Add (Ds.Entity_id 3, "block/parent", Ds.Ref 2);
        Ds.Add (Ds.Entity_id 4, "block/parent", Ds.Ref 1);
      ]
      (Ds.empty_db ~schema:[ ("block/uuid", uuid_attr) ] ())
  in
  check_eq
    (Ops.affected_uuids db
       (Ops.Delete_blocks { uuids = [ "root"; "missing" ] }))
    [ "root"; "child"; "grandchild"; "missing" ];
  check_eq
    (Ops.affected_uuids db (Ops.Delete_blocks { uuids = [] }))
    []

let normalization_db () =
  Ds.db_with
    [
      Ds.Add (Ds.Entity_id 1, "block/uuid", Ds.Uuid "block");
      Ds.Add (Ds.Entity_id 1, "block/title", Ds.String "Old");
      Ds.Add (Ds.Entity_id 2, "block/uuid", Ds.Uuid "previous");
      Ds.Add (Ds.Entity_id 2, "block/title", Ds.String "Before ");
      Ds.Add (Ds.Entity_id 3, "block/uuid", Ds.Uuid "without-title");
    ]
    (Ds.empty_db ~schema:[ ("block/uuid", uuid_attr) ] ())

let normalization_operation intent : Ops.pending_operation =
  { operation_id = "normalize"; base_t = 42; state = Ops.Accepted 43; intent }

let normalization_checks_raw_titles_without_changing_operation_metadata () =
  let db = normalization_db () in
  let title : Ops.pending_title =
    { uuid = "block"; expected_title = "Old"; title = "New" }
  in
  let op = normalization_operation (Ops.Save_title title) in
  check_eq (Ops.normalize_operation db op) (Ok op);
  check_eq (Ops.raw_title db "missing") (Error "block no longer exists");
  check_eq (Ops.raw_title db "without-title")
    (Error "block title is missing");
  check_eq
    (Ops.normalize_operation db
       {
         op with
         intent = Ops.Save_title { title with expected_title = "Wrong" };
       })
    (Error "title changed on the server");
  let split = normalization_operation (List.nth intents 8) in
  check_eq (Ops.normalize_operation db split) (Ok split)

let normalization_merges_check_both_titles_and_recompute_the_result () =
  let db = normalization_db () in
  let merge : Ops.pending_merge =
    {
      uuid = "block";
      expected_title = "Old";
      title = "Payload";
      previous_uuid = "previous";
      expected_previous_title = "Before ";
      merged_title = Some "stale";
    }
  in
  let op = normalization_operation (Ops.Merge_backward merge) in
  check_eq
    (Ops.normalize_operation db op)
    (Ok
       {
         op with
         intent =
           Ops.Merge_backward
             { merge with merged_title = Some "Before Payload" };
       });
  List.iter
    (fun invalid ->
      check_eq
        (Ops.normalize_operation db
           { op with intent = Ops.Merge_backward invalid })
        (Error "title changed on the server"))
    [
      { merge with expected_title = "Wrong" };
      { merge with expected_previous_title = "Wrong" };
    ]

let normalization_preserves_non_title_intents () =
  let db = normalization_db () in
  List.iter
    (fun intent ->
      let op = normalization_operation intent in
      check_eq (Ops.normalize_operation db op) (Ok op))
    (List.map (fun index -> List.nth intents index)
       [ 1; 2; 3; 4; 5; 6; 7; 11; 12 ]
    @ page_intents)

let normalization_converts_only_fsrs_time_fields () =
  let db = normalization_db () in
  let state =
    Ops.Map_value
      [
        ("last-repeat", Ops.Instant_value 9);
        ("other", Ops.Instant_value 10);
      ]
  in
  let normalized =
    Ops.Map_value
      [ ("last-repeat", Ops.Int_value 9); ("other", Ops.Instant_value 10) ]
  in
  List.iter
    (fun (attr, input, expected) ->
      let property : Ops.pending_property =
        {
          uuid = "block";
          attr;
          expected = Some input;
          value = Some input;
        }
      in
      let op = normalization_operation (Ops.Set_property property) in
      let change : Ops.property_change =
        { attr; expected = Some input; value = Some input }
      in
      let batch =
        normalization_operation
          (Ops.Set_properties { uuid = "block"; changes = [ change ] })
      in
      check_eq
        (Ops.normalize_operation db op)
        (Ok
           {
             op with
             intent =
               Ops.Set_property
                 {
                   property with
                   expected = Some expected;
                   value = Some expected;
                 };
           });
      check_eq
        (Ops.normalize_operation db batch)
        (Ok
           {
             batch with
             intent =
               Ops.Set_properties
                 {
                   uuid = "block";
                   changes =
                     [
                       {
                         change with
                         expected = Some expected;
                         value = Some expected;
                       };
                     ];
                 };
           }))
    [
      ("logseq.property.fsrs/due", Ops.Instant_value 7, Ops.Int_value 7);
      ("logseq.property.fsrs/state", state, normalized);
      ("custom", state, state);
      ("custom", Ops.Instant_value 7, Ops.Instant_value 7);
    ]

let read_all_lines path =
  let channel = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () ->
      let rec loop acc =
        match input_line channel with
        | line -> loop (line :: acc)
        | exception End_of_file -> List.rev acc
      in
      loop [])

let persisted_intents_preserve_independent_legacy_golden_fixtures () =
  let all =
    intents
    @ [
        Ops.Save_title
          { uuid = "duplicate"; expected_title = ""; title = "first" };
      ]
    @ page_intents
  in
  let expected = read_all_lines "../native/pending_ops_golden.jsonl" in
  check_eq (List.length all) (List.length expected);
  check_eq
    (List.map (fun intent -> Json.to_string (Ops.intent_json intent)) all)
    expected;
  List.iter
    (fun intent ->
      check_eq (Ops.intent_of_json (Ops.intent_json intent)) intent)
    all;
  check_eq
    (List.map Ops.outliner_op intents)
    [
      "save-block";
      "save-block";
      "save-block";
      "save-block";
      "insert-blocks";
      "insert-blocks";
      "move-blocks";
      "move-blocks";
      "split-block";
      "merge-blocks";
      "merge-blocks";
      "delete-blocks";
      "save-block";
    ];
  check_eq
    (List.map Ops.outliner_op page_intents)
    [
      "save-block";
      "insert-blocks";
      "save-block";
      "insert-blocks";
      "delete-blocks";
      "delete-page";
    ]

let invalid_value input =
  match Ops.semantic_value_of_json input with
  | exception Invalid_argument _ -> true
  | _ -> false

let invalid_intent input =
  match Ops.intent_of_json input with
  | exception Invalid_argument _ -> true
  | _ -> false

let semantic_values_round_trip_with_order_and_duplicates () =
  List.iter
    (fun value ->
      check_eq (Ops.semantic_value_of_json (Ops.semantic_value_json value)) value)
    [
      Ops.String_value "text";
      Ops.Int_value 42;
      Ops.Instant_value 1776000000000;
      Ops.Bool_value true;
      Ops.Ref_uuid "uuid";
      Ops.Ref_ident "db/ident";
      Ops.Float_value 0.4;
      Ops.Keyword_value "learning";
      Ops.Map_value
        [
          ("state", Ops.Keyword_value "learning");
          ("stability", Ops.Float_value 0.4);
          ("nested", Ops.Map_value [ ("reps", Ops.Int_value 1) ]);
          ("last-repeat", Ops.Instant_value 1776000000000);
        ];
      Ops.Map_value
        [ ("duplicate", Ops.Int_value 1); ("duplicate", Ops.Int_value 2) ];
    ];
  List.iter
    (fun raw -> check (invalid_value (Json.from_string raw)))
    [
      "\"invalid\"";
      "{\"value\":1,\"type\":\"int\"}";
      "{\"type\":\"int\",\"value\":1,\"extra\":null}";
      "{\"type\":\"map\",\"value\":[null]}";
    ];
  check_eq
    (Ops.semantic_value_of_json
       (Json.from_string "{\"type\":\"float\",\"value\":1}"))
    (Ops.Float_value 1.0);
  check_eq
    (Ops.option_value Ops.semantic_value_of_json
       (Ops.option_json Ops.semantic_value_json None))
    None;
  check_eq
    (Ops.option_value Ops.semantic_value_of_json
       (Ops.option_json Ops.semantic_value_json
          (Some (Ops.String_value "value"))))
    (Some (Ops.String_value "value"))

let persisted_state_normalization_and_legacy_cursors () =
  List.iter
    (fun state -> check_eq (Ops.state_of_string (Ops.state_string state)) state)
    [
      Ops.Queued;
      Ops.Submitted;
      Ops.Accepted 42;
      Ops.Retryable;
      Ops.Applied;
      Ops.Conflicted "changed";
    ];
  List.iter
    (fun (value, expected) ->
      check_eq (Ops.state_of_string value) expected)
    [
      ("accepted", Ops.Submitted);
      ("accepted:nope", Ops.Retryable);
      ("unknown", Ops.Retryable);
      ("", Ops.Retryable);
      ("accepted:", Ops.Retryable);
      ("accepted:-1", Ops.Accepted (-1));
      ("accepted:0x2a", Ops.Accepted 42);
      ("accepted:1_000", Ops.Accepted 1000);
      ("accepted:99999999999999999999999", Ops.Retryable);
      ("conflicted:", Ops.Conflicted "");
      ("conflicted:one:two", Ops.Conflicted "one:two");
    ]

let missing_and_duplicate_fields_preserve_legacy_behavior () =
  List.iter
    (fun input ->
      check
        (match Ops.intent_of_json (Json.from_string input) with
         | exception Not_found -> true
         | _ -> false))
    [
      "{\"type\":\"set-property\",\"uuid\":\"block\",\"attr\":\"flag\"}";
      "{\"type\":\"set-property\",\"uuid\":\"block\",\"attr\":\"flag\",\"expected\":null}";
    ];
  check_eq
    (Ops.intent_of_json
       (Json.from_string
          "{\"type\":\"save-title\",\"uuid\":\"duplicate\",\"expectedTitle\":\"\",\"title\":\"first\",\"title\":\"second\"}"))
    (Ops.Save_title
       { uuid = "duplicate"; expected_title = ""; title = "first" })

let replace_field intent field value =
  match Ops.intent_json intent with
  | `Assoc fields ->
    Ops.json_object
      ((field, value)
       :: List.filter (fun (key, _) -> key <> field) fields)
  | _ -> Ops.intent_json intent

let invalid_intent_shapes_are_rejected () =
  List.iter
    (fun raw -> check (invalid_intent (Json.from_string raw)))
    [
      "\"invalid\"";
      "{\"type\":1}";
      "{\"type\":\"unknown\"}";
      "{\"type\":\"insert-block\",\"uuid\":\"new\",\"title\":\"New\",\"pageUuid\":\"page\",\"parentUuid\":\"page\",\"order\":\"a0\",\"createdAt\":\"invalid\"}";
      "{\"type\":\"move-blocks\",\"moves\":null}";
      "{\"type\":\"move-blocks\",\"moves\":[null]}";
      "{\"type\":\"delete-blocks\",\"uuids\":null}";
      "{\"type\":\"delete-blocks\",\"uuids\":[1]}";
    ];
  check
    (invalid_intent (replace_field (List.nth intents 8) "createdAt" (`String "invalid")));
  check
    (invalid_intent (replace_field (List.nth intents 9) "mergedTitle" (`Int 1)));
  check_eq
    (Ops.intent_of_json
       (match Ops.intent_json (List.nth intents 9) with
        | `Assoc fields ->
          Ops.json_object
            (List.filter (fun (key, _) -> key <> "mergedTitle") fields)
        | other -> other))
    (List.nth intents 10)

let cases =
  [
    case "search refresh targets cover every intent"
      search_refresh_targets_cover_every_intent;
    case "search refresh ignores unrelated properties"
      search_refresh_ignores_unrelated_properties;
    case "deleted search targets include descendants and missing roots"
      deleted_search_targets_include_descendants_and_missing_roots;
    case "normalization checks raw titles without changing operation metadata"
      normalization_checks_raw_titles_without_changing_operation_metadata;
    case "normalization merges check both titles and recompute the result"
      normalization_merges_check_both_titles_and_recompute_the_result;
    case "normalization preserves non-title intents"
      normalization_preserves_non_title_intents;
    case "normalization converts only fsrs time fields"
      normalization_converts_only_fsrs_time_fields;
    case "persisted intents preserve independent legacy golden fixtures"
      persisted_intents_preserve_independent_legacy_golden_fixtures;
    case "semantic values round trip with order and duplicates"
      semantic_values_round_trip_with_order_and_duplicates;
    case "persisted state normalization and legacy cursors"
      persisted_state_normalization_and_legacy_cursors;
    case "missing and duplicate fields preserve legacy behavior"
      missing_and_duplicate_fields_preserve_legacy_behavior;
    case "invalid intent shapes are rejected" invalid_intent_shapes_are_rejected;
  ]
