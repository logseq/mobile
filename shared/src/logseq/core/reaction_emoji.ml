type emoji = { id : string; glyph : string; name : string; terms : string }

let catalog = lazy (
  let open Yojson.Basic.Util in
  let data = Yojson.Basic.from_string Reaction_emoji_data.json in
  let groups = member "groups" data |> to_assoc |> List.map (fun (category, group) ->
    category, (to_list group |> List.filter_map (function
      | `List [`String id; `String glyph; `String name; `String keywords] ->
        Some { id; glyph; name; terms = String.lowercase_ascii (id ^ " " ^ name ^ " " ^ keywords) }
      | _ -> None))) in
  let entries = List.concat_map snd groups in
  let by_id = Hashtbl.create (List.length entries) in
  List.iter (fun entry -> Hashtbl.replace by_id entry.id entry) entries;
  List.iter (function
    | alias, `String id ->
      Option.iter (Hashtbl.replace by_id alias) (Hashtbl.find_opt by_id id)
    | _ -> ()) (member "aliases" data |> to_assoc);
  entries, by_id)

let find id =
  let id = match String.lowercase_ascii id with
    | "thumbs_up" -> "+1"
    | "thumbs_down" -> "-1"
    | id -> id in
  let _, by_id = Lazy.force catalog in
  Hashtbl.find_opt by_id id

let all () = fst (Lazy.force catalog)

let search query =
  let query = String.lowercase_ascii (String.trim query) in
  let words = String.split_on_char ' ' query |> List.filter ((<>) "")
    |> List.map (fun word -> Re.compile (Re.str word)) in
  let matching = List.filter (fun entry ->
    List.for_all (fun word -> Re.execp word entry.terms || Re.execp word entry.glyph) words) (all ()) in
  let exact, others = List.partition (fun entry ->
    query = entry.id || query = String.lowercase_ascii entry.name || query = entry.glyph) matching in
  let prefix, keywords = List.partition (fun entry ->
    String.starts_with ~prefix:query entry.id
    || String.starts_with ~prefix:query (String.lowercase_ascii entry.name)) others in
  exact @ prefix @ keywords

let suggested = ["+1"; "heart"; "tada"; "joy"; "eyes"; "thinking_face"]

let recent_limit = List.length suggested

let quick ~limit recent =
  List.fold_left (fun (seen, choices) id ->
    match find id with
    | Some emoji when not (List.mem emoji.id seen) -> emoji.id :: seen, emoji :: choices
    | _ -> seen, choices) ([], []) (recent @ suggested)
  |> snd |> List.rev |> List.take limit
