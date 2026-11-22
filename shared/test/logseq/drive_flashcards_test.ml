(* Flashcard review and decks. Scripts live in logseq/drive/flashcards/. *)

let snapshot (host : Drive_host.host) model =
  Drive_host.current_graph_projection host model ~extra:(fun projection ->
      projection)

let handle (host : Drive_host.host) model = function
  | Model.LoadFlashcardsEffect id ->
    Some
      (Model.DequeueEffect id
      :: Drive_host.current_graph_projection host model ~extra:(fun projection ->
             { projection with Model.flashcards = host.Drive_host.flashcards })
      :: Drive_host.resolved id)
  | Model.ReviewFlashcardEffect (id, uuid, _rating) ->
    host.flashcards <-
      List.filter
        (fun (card : Model.flashcard) -> card.flashcard_uuid <> uuid)
        host.flashcards;
    host.deck_completed <- host.flashcards = [];
    Some (Model.DequeueEffect id :: snapshot host model :: Drive_host.resolved id)
  | Model.FlashcardDeckEffect (id, payload) ->
    let fields = Drive_host.json_fields payload in
    (match Drive_host.json_string fields "action" with
    | Some "select" -> host.deck_selected <- Drive_host.json_string fields "uuid"
    | Some "search" -> host.deck_targets <- [ ("page-1", "Alpha Doc") ]
    | Some "create" -> host.deck_created <- Some "deck-created"
    | Some "practice" ->
      host.deck_completed <- false;
      host.flashcards <- [ Drive_host.flashcard_seed ]
    | _ -> ());
    Some (Model.DequeueEffect id :: snapshot host model :: Drive_host.resolved id)
  | _ -> None

let () = Drive_host.register handle

let cases = Drive_host.cases "logseq/drive/flashcards"
