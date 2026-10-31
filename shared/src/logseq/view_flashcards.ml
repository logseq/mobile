open Lui_elements

let flashcard_answer_row answer_source : t =
  let answer = Signal.sample answer_source in
  text
    ~value_signal:(reactive View_base.flashcard_answer_text answer_source)
    ~accessibility_identifier:
      (View_base.flashcard_answer_identifier answer)
    []

(* Flashcard controls use shared button typography and alignment semantics. *)

let flashcard_rating_button rating title foreground background send : t =
  button ~variant:`ghost ~style_class:"semibold" ~grow:1.0 ~min_height:50
    ~text_alignment:`center ~foreground ~background ~corner_radius:14
    ~accessibility_identifier:("button.flashcard.rating." ^ rating)
    ~on_press:(press send (Model.ReviewFlashcard rating))
    ~text:title []

let flashcard_review_content model_source send : t =
  column ~accessibility_identifier:"layout.flashcards.review" ~grow:1.0
    ~gap:0 ~padding_horizontal:20
    [
      box ~height:18 ~accessibility_identifier:"spacer.flashcards.top" [];
      column ~accessibility_identifier:"layout.flashcards.review-content"
        ~grow:1.0 ~gap:18
        [
          row ~accessibility_identifier:"row.flashcards.status"
            [
              text ~style_class:"footnote" ~foreground:"muted-foreground"
                ~value:(View_base.tr (Signal.sample model_source) "Due now") [];
              spacer ~grow:1.0 [];
              text ~style_class:"footnote" ~foreground:"muted-foreground"
                ~value_signal:
                  (Signal.map View_base.flashcard_remaining_label
                     model_source)
                [];
            ];
          scroll ~grow:1.0
            [
              column ~accessibility_identifier:"card.flashcard.question"
                ~gap:18 ~padding:22 ~background:"surface" ~corner_radius:18
                [
                  text ~style_class:"title2 semibold"
                    ~value_signal:
                      (Signal.map View_base.flashcard_question model_source)
                    ~accessibility_identifier:"flashcard.question" [];
                  if_
                    ~test:
                      (Signal.map View_base.flashcard_answer_rows_visible_
                         model_source)
                    (column ~gap:18
                       [
                         separator
                           ~accessibility_identifier:
                             "flashcard.answer-divider" [];
                         column ~gap:12
                           [
                             keyed
                               ~source:
                                 (Signal.map
                                    View_base
                                    .visible_flashcard_answer_rows
                                    model_source)
                               ~key:View_base.flashcard_answer_identifier
                               ~cmp:compare
                               ~mount:flashcard_answer_row;
                           ];
                       ]);
                ];
            ];
          if_
            ~test:(Signal.map View_base.flashcard_show_cloze_ model_source)
            (row
               [
                 button ~variant:`ghost ~style_class:"semibold" ~grow:1.0
                   ~min_height:50 ~text_alignment:`center
                   ~foreground:"white" ~background:"primary"
                   ~corner_radius:14
                   ~accessibility_identifier:"button.flashcard.show-cloze"
                   ~on_press:(press send Model.RevealFlashcardCloze)
                   ~text:(View_base.tr (Signal.sample model_source) "Show cloze") [];
               ]);
          if_
            ~test:(Signal.map View_base.flashcard_show_answer_ model_source)
            (row
               [
                 button ~variant:`ghost ~style_class:"semibold" ~grow:1.0
                   ~min_height:50 ~text_alignment:`center
                   ~foreground:"white" ~background:"primary"
                   ~corner_radius:14
                   ~accessibility_identifier:"button.flashcard.show-answer"
                   ~on_press:(press send Model.RevealFlashcardAnswer)
                   ~text:(View_base.tr (Signal.sample model_source) "Show answer") [];
               ]);
          if_
            ~test:(Signal.map View_base.flashcard_show_ratings_ model_source)
            (column ~gap:10
               [
                 row ~gap:10
                   [
                     flashcard_rating_button "again" "Again" "red"
                       "flashcard-again-background" send;
                     flashcard_rating_button "hard" "Hard"
                       "warning-foreground" "flashcard-hard-background" send;
                   ];
                 row ~gap:10
                   [
                     flashcard_rating_button "good" "Good" "blue"
                       "flashcard-good-background" send;
                     flashcard_rating_button "easy" "Easy" "green"
                       "flashcard-easy-background" send;
                   ];
               ]);
        ];
      box ~height:24 ~accessibility_identifier:"spacer.flashcards.bottom"
        [];
    ]

let json_field key = function
  | `Assoc fields -> Option.value ~default:`Null (List.assoc_opt key fields)
  | _ -> `Null
let json_text = function `String value -> value | _ -> ""
let json_items = function `List values -> values | _ -> []
let deck_metadata (model : Model.logseq_model) =
  try Yojson.Basic.from_string model.flashcard_decks_json with _ -> `Null
let deck_request model_source send fields =
  let graph = Option.value ~default:"" (Signal.sample model_source).Model.selected_graph_id in
  ignore (send (Model.FlashcardDeckAction
    (Yojson.Basic.to_string (`Assoc (("graphId", `String graph) :: fields)))))

let flashcard_group_controls model_source send : t = fun context parent ->
  let own source = Signal.own_signal context.ui_scope source in
  let graphs = own (Signal.map (fun (model : Model.logseq_model) -> [model.selected_graph_id]) model_source) in
  (keyed ~source:graphs ~key:Fun.id ~cmp:compare ~mount:(fun _ -> fun context parent ->
    let own source = Signal.own_signal context.ui_scope source in
    let metadata = own (Signal.map deck_metadata model_source) in
    let selected = own (Signal.map (json_field "selectedUuid") metadata) in
    let choices = own (Signal.map (fun json -> json_items (json_field "items" json)) metadata) in
    let emit fields = deck_request model_source send fields in
    let adding = Signal.state context.ui_scheduler false in
    let controls = row ~cross:`center ~padding_horizontal:20 ~height:48 [
      View_base.with_string_prop TextAlignment "start"
        (menu ~text_signal:(own (Signal.map (fun json ->
          let selected = json_field "selectedUuid" json in
          if selected = `Null then "All cards" else
          match List.find_opt (fun item -> json_field "uuid" item = selected)
            (json_items (json_field "items" json)) with
          | Some item -> json_text (json_field "title" item)
          | None -> "Unavailable group") metadata))
          ~label:(View_base.tr (Signal.sample model_source) "Card group") ~accessibility_identifier:"menu.flashcards.deck" [
          menu_item ~text:(View_base.tr (Signal.sample model_source) "All cards") ~selected_signal:(own (Signal.map ((=) `Null) selected))
            ~accessibility_identifier:"flashcards.deck.select.all"
            ~on_press:(fun _ -> emit ["action", `String "select"; "uuid", `Null]) [];
          keyed ~source:choices ~key:(fun item -> json_text (json_field "uuid" item)) ~cmp:String.compare
            ~mount:(fun source ->
              let uuid = json_field "uuid" (Signal.sample source) in
              menu_item ~text_signal:(own (Signal.map (fun item -> json_text (json_field "title" item)) source))
                ~selected_signal:(own (Signal.map ((=) uuid) selected))
                ~accessibility_identifier:("flashcards.deck.select." ^ json_text uuid)
                ~on_press:(fun _ -> emit ["action", `String "select"; "uuid", uuid]) []);
        ]);
      spacer ~grow:1.0 [];
      button ~icon:(`app "add") ~variant:`ghost ~width:44 ~height:44 ~label:(View_base.tr (Signal.sample model_source) "New card group")
        ~accessibility_identifier:"button.flashcards.deck.add"
        ~on_press:(fun _ -> Signal.set adding true) [];
    ] in
    let picker = if_ ~test:(Signal.value adding) (fun context parent ->
      let own source = Signal.own_signal context.ui_scope source in
      let name = Signal.state context.ui_scheduler "" in
      let custom_name = ref false in
      let kind = Signal.state context.ui_scheduler "page" in
      let query = Signal.state context.ui_scheduler "" in
      let target = Signal.state context.ui_scheduler None in
      let submitting = Signal.state context.ui_scheduler false in
      let created_before = json_field "createdUuid" (Signal.sample metadata) in
      let request_search kind query = emit ["action", `String "search";
        "kind", `String kind; "query", `String query] in
      ignore (Signal.own context.ui_scope (Signal.observe model_source (fun model ->
        if json_field "createdUuid" (deck_metadata model) <> created_before then Signal.set adding false
        else if Signal.sample (Signal.value submitting) && not
          (List.exists (function Model.FlashcardDeckEffect _ -> true | _ -> false)
            (model.pending_effects @ model.in_flight_effects))
        then Signal.set submitting false)));
      let targets = own (Signal.map2 (fun metadata (kind, query) ->
        let search = json_field "targetSearch" metadata in
        if json_field "kind" search = `String kind && json_field "query" search = `String query
        then json_items (json_field "items" search) else []) metadata
          (own (Signal.map2 (fun kind query -> kind, query) (Signal.value kind) (Signal.value query)))) in
      let invalid = own (Signal.map2 (fun (name, target) submitting ->
        String.trim name = "" || target = None || submitting)
        (own (Signal.map2 (fun name target -> name, target) (Signal.value name) (Signal.value target)))
        (Signal.value submitting)) in
      let cancel = button ~text:(View_base.tr (Signal.sample model_source) "Cancel") ~variant:`ghost ~style_class:"cancellation-action"
        ~accessibility_identifier:"button.flashcards.deck.cancel"
        ~disabled_signal:(Signal.value submitting) ~on_press:(fun _ -> Signal.set adding false) [] in
      let create = button ~text:(View_base.tr (Signal.sample model_source) "Create") ~variant:`ghost ~style_class:"confirmation-action"
        ~accessibility_identifier:"button.flashcards.deck.create" ~disabled_signal:invalid
        ~on_press:(fun _ ->
          if not (Signal.sample invalid) then match Signal.sample (Signal.value target) with
          | None -> ()
          | Some uuid ->
            Signal.set submitting true;
            emit ["action", `String "create"; "kind", `String (Signal.sample (Signal.value kind));
              "targetUuid", `String uuid; "title", `String (Signal.sample (Signal.value name))]) [] in
      request_search "page" "";
      (sheet ~text:(View_base.tr (Signal.sample model_source) "New card group") ~detents:"medium,large" ~style_class:"navigation-list navigation-inline-title"
        ~accessibility_identifier:"sheet.flashcards.deck.create" ~on_dismiss:(fun _ -> Signal.set adding false) [
        list ~grow:1.0 ~style:`inset_grouped [
          list_section [
            list_item [text_field ~label:(View_base.tr (Signal.sample model_source) "Name") ~placeholder:(View_base.tr (Signal.sample model_source) "Card group name") ~text_signal:(Signal.value name)
              ~accessibility_identifier:"field.flashcards.deck.name"
              ~disabled_signal:(Signal.value submitting)
              ~on_input:(function TextChanged (_, value) -> custom_name := true; Signal.set name value | _ -> ()) []];
            list_item [tabs ~label:(View_base.tr (Signal.sample model_source) "Filter by") ~grow:1.0 ~accessibility_identifier:"picker.flashcards.deck.kind"
              (List.map (fun (value, label) ->
                View_base.with_selected_signal (own (Signal.map ((=) value) (Signal.value kind)))
                  (button ~text:label ~grow:1.0 ~disabled_signal:(Signal.value submitting)
                    ~accessibility_identifier:("flashcards.deck.kind." ^ value)
                    ~on_press:(fun _ ->
                      Signal.set kind value; Signal.set query ""; Signal.set target None;
                      request_search value "") [])) ["page", "Page reference"; "tag", "Tag"])];
          ];
          list_section [
            list_item [search_field ~label:(View_base.tr (Signal.sample model_source) "Find a page or tag") ~placeholder:(View_base.tr (Signal.sample model_source) "Search pages or tags")
              ~text_signal:(Signal.value query) ~accessibility_identifier:"field.flashcards.deck.search"
              ~disabled_signal:(Signal.value submitting)
              ~on_input:(function TextChanged (_, value) -> Signal.set query value;
                request_search (Signal.sample (Signal.value kind)) value | _ -> ()) []];
            keyed ~source:targets ~key:(fun item -> json_text (json_field "uuid" item)) ~cmp:String.compare
              ~mount:(fun source ->
                let uuid = json_text (json_field "uuid" (Signal.sample source)) in
                list_item ~height:44 ~padding_vertical:0 [menu_item ~height:44 ~padding_vertical:0
                  ~text_signal:(own (Signal.map (fun item -> json_text (json_field "title" item)) source))
                  ~selected_signal:(own (Signal.map ((=) (Some uuid)) (Signal.value target)))
                  ~disabled_signal:(Signal.value submitting)
                  ~accessibility_identifier:("flashcards.deck.target." ^ uuid)
                  ~on_press:(fun _ -> Signal.set target (Some uuid);
                    if not !custom_name then Signal.set name (json_text (json_field "title" (Signal.sample source)))) []]);
            if_ ~test:(own (Signal.map ((=) []) targets))
              (list_item [text ~value:(View_base.tr (Signal.sample model_source) "No matching pages or tags") ~foreground:"muted-foreground" []]);
          ];

        ];
        (if Lui_ui.host context = KotlinHost then row ~main:`space_between ~padding:12 [cancel; create]
         else toolbar ~label:(View_base.tr (Signal.sample model_source) "Card group actions") ~style_class:"navigation-actions" [cancel; create]);
      ]) context parent) in
    (column ~gap:0 [controls;

      picker]) context parent)) context parent

let flashcard_screen model_source send : t =
  column ~accessibility_identifier:"screen.flashcards" ~grow:1.0 ~gap:0
    ~background:"background"
    [
      flashcard_group_controls model_source send;
      if_
        ~test:(Signal.map View_base.flashcards_empty_ model_source)
        (column ~accessibility_identifier:"layout.flashcards.empty"
           ~grow:1.0 ~main:`center ~cross:`center ~gap:10 ~padding:32
           [
             icon ~name:(`app "flashcards") ~width:48 ~height:48
               ~foreground:"muted-foreground" [];
             heading ~level:3 ~value:(View_base.tr (Signal.sample model_source) "No cards due")
               ~accessibility_identifier:"flashcards.empty" [];
             text ~text_alignment:`center ~foreground:"muted-foreground"
               ~value:(View_base.tr (Signal.sample model_source) "Tag any block with #Card to review it here.") [];
           ]);
      if_
        ~test:(Signal.map View_base.flashcards_present_ model_source)
        (flashcard_review_content model_source send);
    ]
