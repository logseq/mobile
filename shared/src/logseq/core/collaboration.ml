module Ds = Datascript
module Read = Graph_read

type comment_write =
  { target : string
  ; thread : string
  ; uuid : string
  ; text : string
  ; created_at : int
  }

type reaction_write =
  { target : string
  ; actor : string
  ; uuid : string
  ; emoji : string
  ; active : bool
  ; created_at : int
  }

let thread_class = "logseq.class/Comments"
let comment_class = "logseq.class/Comment"
let thread_targets = "logseq.property.comments/blocks"
let reaction_target = "logseq.property.reaction/target"
let reaction_emoji = "logseq.property.reaction/emoji-id"
let creator = "logseq.property/created-by-ref"

let entity db uuid = Ds.entid db "block/uuid" (Ds.Uuid uuid)
let live db eid = Read.value db eid "logseq.property/deleted-at" = None && not (Read.recycled db eid)
let text db eid attr = Read.string_value (Read.value db eid attr)
let title db eid = Option.value ~default:"" (text db eid "block/title")
let refs db eid attr = Read.ref_eids db eid attr
let referring db attr target =
  Datascript_value.datoms_by_ref db Ds.Aevt attr target
  |> Seq.map (fun (d : Ds.datom) -> d.e) |> List.of_seq

let tagged db eid ident =
  Option.fold ~none:false ~some:(Read.has_ref db eid "block/tags")
    (Ds.entid db "db/ident" (Ds.Keyword ident))

let is_thread db eid = tagged db eid thread_class
let thread_of_comment db eid = List.find_opt (is_thread db) (refs db eid "block/parent")
let targets db thread =
  match refs db thread thread_targets with [] -> refs db thread "block/parent" | values -> values

let order db eid = text db eid "block/order", Read.uuid_for_eid db eid

let threads db target =
  referring db thread_targets target @ referring db "block/parent" target
  |> List.filter (fun thread -> is_thread db thread && live db thread && List.mem target (targets db thread))
  |> List.sort_uniq (fun a b -> compare (order db a) (order db b))

let comments db thread =
  referring db "block/parent" thread
  |> List.filter (fun eid -> live db eid && not (is_thread db eid))
  |> List.sort (fun a b -> compare (order db a) (order db b))

let existing_thread db target =
  List.find_opt (fun thread -> targets db thread = [target]) (threads db target)

let reactions db target =
  referring db reaction_target target |> List.filter (live db)

let owns db actor eid = Read.has_ref db eid creator actor

let own_reactions db ~target ~actor ~emoji =
  match entity db target, entity db actor with
  | Some target, Some actor ->
    List.filter (fun eid -> owns db actor eid && text db eid reaction_emoji = Some emoji)
      (reactions db target)
  | _ -> []

let emoji_choices =
  ["+1", "👍"; "heart", "❤️"; "tada", "🎉"; "joy", "😂"; "eyes", "👀"; "thinking_face", "🤔"]

let valid_emoji emoji =
  String.length emoji > 0 && String.length emoji <= 80
  && String.for_all (function
    | 'A'..'Z' | 'a'..'z' | '0'..'9' | '+' | '-' | '_' -> true | _ -> false) emoji

let author db eid = List.find_map (Read.uuid_for_eid db) (refs db eid creator)
let actor_name db eid =
  List.find_map (fun actor -> Option.bind (text db actor "block/title") (fun name ->
    if String_kit.is_blank name then None else Some name)) (refs db eid creator)

let created_at db eid = Option.value ~default:0 (Read.int_value (Read.value db eid "block/created-at"))

let write_target db target =
  match entity db target with
  | Some eid when live db eid && not (is_thread db eid) && text db eid "block/title" <> None -> Some eid
  | _ -> None

let inbox db ~actor =
  match entity db actor with
  | None -> []
  | Some actor ->
    let authored = referring db creator actor |> List.filter (live db) in
    let thread_targets = Hashtbl.create 32 in
    List.iter (fun eid ->
      let discussions = match thread_of_comment db eid with Some thread -> [thread] | None -> threads db eid in
      List.iter (fun thread ->
        List.find_opt (live db) (targets db thread)
        |> Option.iter (fun target -> Hashtbl.replace thread_targets thread target)) discussions) authored;
    let events = Hashtbl.create 32 in
    let add target event kind =
      if live db target && author db event <> None && not (owns db actor event) then
        match Read.uuid_for_eid db event, Read.uuid_for_eid db target with
        | Some uuid, Some target_uuid ->
          let time = created_at db event in
          Hashtbl.replace events uuid (time, uuid, `Assoc [
            "id", `String uuid; "target", `String target_uuid; "kind", `String kind;
            "title", `String (title db target);
            "actor", (match actor_name db event with Some name -> `String name | None -> `Null);
            "createdAt", `Int time])
        | _ -> () in
    Hashtbl.iter (fun thread target ->
      if live db thread then List.iter (fun event -> add target event "comment") (comments db thread))
      thread_targets;
    List.iter (fun target -> List.iter (fun event -> add target event "reaction") (reactions db target)) authored;
    Hashtbl.to_seq_values events |> List.of_seq
    |> List.sort (fun (a, x, _) (b, y, _) -> compare (b, y) (a, x))
    |> List.take 100 |> List.map (fun (_, _, event) -> event)

let discussion db ~actor ~target =
  let ( let* ) = Option.bind in
  let* target = write_target db target in
  let encode eid =
    let* uuid = Read.uuid_for_eid db eid in
    let reaction_ids = reactions db eid |> List.filter_map (fun reaction -> text db reaction reaction_emoji)
      |> List.sort_uniq String.compare in
    Some (`Assoc [
      "id", `String uuid; "text", `String (title db eid);
      "actor", (match actor_name db eid with Some name -> `String name | None -> `Null);
      "createdAt", `Int (created_at db eid);
      "isComment", `Bool (thread_of_comment db eid <> None);
      "reactions", `List (List.map (fun emoji ->
        let matching = reactions db eid |> List.filter (fun reaction -> text db reaction reaction_emoji = Some emoji) in
        `Assoc ["id", `String emoji; "count", `Int (List.length matching);
          "selected", `Bool (List.exists (fun reaction -> author db reaction = Some actor) matching)]) reaction_ids)
    ]) in
  let* subject = encode target in
  let related = threads db target |> List.concat_map (comments db) |> List.filter_map encode in
  Some (`Assoc ["subject", subject; "comments", `List related])
