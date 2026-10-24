module Ds = Datascript
module Graph = Graph_read

type flashcard_rating = Again | Hard | Good | Easy

type flashcard_state = New | Learning | Review | Relearning

type fsrs_card =
  { due : int
  ; stability : float
  ; difficulty : float
  ; elapsed_days : int
  ; scheduled_days : int
  ; reps : int
  ; lapses : int
  ; state : flashcard_state
  ; last_repeat : int
  ; last_rating : flashcard_rating option
  }

type due_card =
  { block : Cache_model.block
  ; children : Cache_model.block list
  ; card : fsrs_card
  }

let rating_name rating =
  match rating with
  | Again -> "again"
  | Hard -> "hard"
  | Good -> "good"
  | Easy -> "easy"

let rating_of_keyword value =
  match value with
  | "again" -> Some Again
  | "hard" -> Some Hard
  | "good" -> Some Good
  | "easy" -> Some Easy
  | _ -> None

let state_name state =
  match state with
  | New -> "new"
  | Learning -> "learning"
  | Review -> "review"
  | Relearning -> "relearning"

let state_of_keyword value =
  match value with
  | "new" -> Some New
  | "learning" -> Some Learning
  | "review" -> Some Review
  | "relearning" -> Some Relearning
  | _ -> None

let new_card now =
  {
    due = now;
    stability = 0.0;
    difficulty = 0.0;
    elapsed_days = 0;
    scheduled_days = 0;
    reps = 0;
    lapses = 0;
    state = New;
    last_repeat = now;
    last_rating = None;
  }

let timestamp milliseconds =
  Timedesc.Timestamp.of_float_s (float_of_int milliseconds /. 1000.0)

let milliseconds value =
  int_of_float (Float.round (Timedesc.Timestamp.to_float_s value *. 1000.0))

let upstream_state state =
  match state with
  | New -> Models.New
  | Learning -> Models.Learning
  | Review -> Models.Review
  | Relearning -> Models.Relearning

let upstream_rating rating =
  match rating with
  | Again -> Models.Again
  | Hard -> Models.Hard
  | Good -> Models.Good
  | Easy -> Models.Easy

let state_of_upstream (state : Models.state) =
  match state with
  | Models.New -> New
  | Models.Learning -> Learning
  | Models.Review -> Review
  | Models.Relearning -> Relearning

let scheduler = Fsrs.create (Parameters.default ())

let upstream_card card : Models.card =
  {
    due = timestamp card.due;
    stability = card.stability;
    difficulty = card.difficulty;
    elapsed_days = card.elapsed_days;
    scheduled_days = card.scheduled_days;
    reps = card.reps;
    lapses = card.lapses;
    state = upstream_state card.state;
    last_review = timestamp card.last_repeat;
  }

let repeat now card rating =
  let scheduled =
    Fsrs.next scheduler (upstream_card card) (timestamp now)
      (upstream_rating rating)
  in
  let next = scheduled.Models.card in
  {
    due = milliseconds next.due;
    stability = next.stability;
    difficulty = next.difficulty;
    elapsed_days = next.elapsed_days;
    scheduled_days = next.scheduled_days;
    reps = next.reps;
    lapses = card.lapses + (if rating = Again then 1 else 0);
    state = state_of_upstream next.state;
    last_repeat = milliseconds next.last_review;
    last_rating = Some rating;
  }

let state_value card =
  let entries =
    [
      (Ds.Keyword "stability", Ds.Float card.stability);
      (Ds.Keyword "difficulty", Ds.Float card.difficulty);
      (Ds.Keyword "elapsed-days", Ds.Int64 (Int64.of_int card.elapsed_days));
      (Ds.Keyword "scheduled-days", Ds.Int64 (Int64.of_int card.scheduled_days));
      (Ds.Keyword "reps", Ds.Int64 (Int64.of_int card.reps));
      (Ds.Keyword "lapses", Ds.Int64 (Int64.of_int card.lapses));
      (Ds.Keyword "state", Ds.Keyword (state_name card.state));
      (Ds.Keyword "last-repeat", Ds.Int64 (Int64.of_int card.last_repeat));
    ]
  in
  let entries =
    match card.last_rating with
    | None -> entries
    | Some rating ->
      entries
      @ [
          ( Ds.Keyword "logseq/last-rating"
          , Ds.Keyword (rating_name rating) );
        ]
  in
  Ds.Map entries

let map_value key entries =
  List.find_map
    (fun (entry_key, entry_value) ->
      if entry_key = Ds.Keyword key then Some entry_value else None)
    entries

let float_value value =
  match value with
  | Some (Ds.Float value) -> Some value
  | Some (Ds.Int64 value) -> Some (Int64.to_float value)
  | _ -> None

let int_value value =
  match value with
  | Some (Ds.Int64 value) -> Some (Int64.to_int value)
  | Some (Ds.Instant value) -> Some (Int64.to_int value)
  | _ -> None

let keyword_value value =
  match value with Some (Ds.Keyword value) -> Some value | _ -> None

let decoded_card due entries =
  match
    ( float_value (map_value "stability" entries)
    , float_value (map_value "difficulty" entries)
    , int_value (map_value "elapsed-days" entries)
    , int_value (map_value "scheduled-days" entries)
    , int_value (map_value "reps" entries)
    , int_value (map_value "lapses" entries)
    , Option.bind (keyword_value (map_value "state" entries)) state_of_keyword
    , int_value (map_value "last-repeat" entries) )
  with
  | ( Some stability
    , Some difficulty
    , Some elapsed_days
    , Some scheduled_days
    , Some reps
    , Some lapses
    , Some state
    , Some last_repeat ) ->
    Some
      {
        due;
        stability;
        difficulty;
        elapsed_days;
        scheduled_days;
        reps;
        lapses;
        state;
        last_repeat;
        last_rating =
          Option.bind
            (keyword_value (map_value "logseq/last-rating" entries))
            rating_of_keyword;
      }
  | _ -> None

let card_of_values created_at due state =
  match (due, state) with
  | Some due, Some (Ds.Map entries) ->
    (match decoded_card due entries with
     | Some card -> card
     | None -> new_card created_at)
  | _ -> new_card created_at

let decrypt_title value = Ok value

let card_eid db eid =
  match Ds.entid db "db/ident" (Ds.Keyword "logseq.class/Card") with
  | None -> false
  | Some card_class_eid ->
    let classes = Graph.class_descendants db card_class_eid in
    List.exists
      (fun class_eid -> List.mem class_eid classes)
      (Graph.ref_eids db eid "block/tags")

let rec descendants page_blocks parent_uuid =
  List.concat_map
    (fun (child : Cache_model.block) ->
      child :: descendants page_blocks child.uuid)
    (List.filter
       (fun (candidate : Cache_model.block) ->
         candidate.parent_id = Some parent_uuid)
       page_blocks)

let page_blocks_for_page page_blocks_cache db page_uuid =
  match Hashtbl.find_opt page_blocks_cache page_uuid with
  | Some blocks -> blocks
  | None ->
    let blocks = Graph.blocks_for_page decrypt_title db page_uuid in
    Hashtbl.replace page_blocks_cache page_uuid blocks;
    blocks

let card_for_eid page_blocks_cache db now uuid eid =
  if card_eid db eid then
    match Graph.block decrypt_title db eid with
    | Some block ->
      let page_blocks = page_blocks_for_page page_blocks_cache db block.page_id in
      let created_at = if block.created_at > 0 then block.created_at else now in
      let due =
        Graph.int_value (Graph.value db eid "logseq.property.fsrs/due")
      in
      let card =
        card_of_values created_at due
          (Graph.value db eid "logseq.property.fsrs/state")
      in
      Some { block; children = descendants page_blocks uuid; card }
    | None -> None
  else None

let card_for_uuid db now uuid =
  match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
  | Some eid -> card_for_eid (Hashtbl.create 8) db now uuid eid
  | None -> None

let due_card_for_eid page_blocks_cache db now eid =
  if Option.fold ~none:false ~some:(fun due -> due > now)
    (Graph.int_value (Graph.value db eid "logseq.property.fsrs/due")) then None
  else match Graph.uuid_for_eid db eid with
  | Some uuid ->
    (match card_for_eid page_blocks_cache db now uuid eid with
     | Some card when card.card.due <= now -> Some card
     | _ -> None)
  | None -> None

let due_cards ?(include_eid = fun _ -> true) db now =
  match Ds.entid db "db/ident" (Ds.Keyword "logseq.class/Card") with
  | None -> []
  | Some card_class_eid ->
    let page_blocks_cache = Hashtbl.create 16 in
    let class_eids = Graph.class_descendants db card_class_eid in
    let tagged_datoms =
      List.concat_map
        (fun class_eid ->
          List.of_seq
            (Datascript_value.datoms_by_ref db Ds.Aevt "block/tags" class_eid))
        class_eids
    in
    let unique_eids =
      List.sort_uniq compare
        (List.map (fun (datom : Ds.datom) -> datom.e) tagged_datoms)
    in
    List.filter include_eid unique_eids
    |> List.filter_map (due_card_for_eid page_blocks_cache db now)
    |> List.sort
         (fun left right ->
           compare
             (left.card.due, left.block.uuid)
             (right.card.due, right.block.uuid))
