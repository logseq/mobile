external initialization_count : unit -> int = "logseq_nlp_init_count"
external parse_native : string -> float -> string option = "logseq_nlp_parse"

let is_uuid text =
  String.length text = 36
  && List.for_all (fun index -> text.[index] = '-') [8; 13; 18; 23]
  && String.for_all (function '0'..'9' | 'a'..'f' | 'A'..'F' | '-' -> true | _ -> false) text

let parse ?now_ms text =
  let text = String.trim text in
  if text = "" || String.length text > 4096 || is_uuid text then None
  else
    let now = Option.value ~default:(Unix.gettimeofday () *. 1000.) now_ms in
    if not (Float.is_finite now) then None
    else Option.map Yojson.Basic.from_string (parse_native text now)

let iso_shape text =
  String.length text = 10 && text.[4] = '-' && text.[7] = '-'

let day ?now_ms text =
  let text = String.trim text in
  match Journal.day_of_string text with
  | Some _ as day -> day
  | None when iso_shape text || String.for_all (function '0'..'9' -> true | _ -> false) text -> None
  | None ->
    Option.bind (parse ?now_ms text) (fun json ->
      match Yojson.Basic.Util.member "day" json with
      | `Int day when Journal.valid_day day -> Some day
      | _ -> None)

let timestamp ?now_ms text =
  match float_of_string_opt (String.trim text) with
  | Some value ->
    if Float.is_finite value && value > float_of_int min_int && value < float_of_int max_int
    then Some (int_of_float value) else None
  | None ->
    Option.bind (parse ?now_ms text) (fun json ->
      match Yojson.Basic.Util.member "timestamp" json with
      | `Int value -> Some value
      | `Float value when Float.is_finite value -> Some (int_of_float value)
      | _ -> None)
