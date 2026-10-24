(** FSRS flashcard scheduling over the DataScript model. *)

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

val rating_name : flashcard_rating -> string
val rating_of_keyword : string -> flashcard_rating option
val state_name : flashcard_state -> string
val state_of_keyword : string -> flashcard_state option
val new_card : int -> fsrs_card
val timestamp : int -> Timedesc.Timestamp.t
val milliseconds : Timedesc.Timestamp.t -> int
val upstream_card : fsrs_card -> Models.card
val repeat : int -> fsrs_card -> flashcard_rating -> fsrs_card
val state_value : fsrs_card -> Datascript.value
val decoded_card : int -> (Datascript.value * Datascript.value) list -> fsrs_card option
val card_of_values : int -> int option -> Datascript.value option -> fsrs_card
val card_eid : Datascript.db -> int -> bool
val descendants : Cache_model.block list -> string -> Cache_model.block list
val card_for_uuid : Datascript.db -> int -> string -> due_card option
val due_cards : ?include_eid:(int -> bool) -> Datascript.db -> int -> due_card list
val map_value : string -> (Datascript.value * Datascript.value) list -> Datascript.value option
