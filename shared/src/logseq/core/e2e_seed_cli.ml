module Seed = E2e_seed_data
module Store = Graph_store
module Graph = Graph_read
module Cards = Flashcards
module Ops = Pending_ops
module Projection = Pending_projection

let usage =
  "usage: logseq_e2e_seed <graph.sqlite> \
   [--inspect|--header-navigation|--composer|--outliner|--fixture|\
--performance|--performance=<journals>x<blocks>]"

type seed_mode =
  | Inspect
  | Header_navigation
  | Composer
  | Outliner
  | Fixture
  | Performance
  | PerformanceSized of int * int
  | Default

let parse_performance_size flag =
  match String.split_on_char 'x' flag with
  | [ journals; blocks ] ->
    (match int_of_string_opt journals, int_of_string_opt blocks with
     | Some journals, Some blocks when journals > 0 && blocks > 0 ->
       Some (PerformanceSized (journals, blocks))
     | _ -> None)
  | _ -> None

let parse_args args =
  let count = List.length args in
  if not (2 <= count && count <= 3) then Error (2, usage)
  else if count = 2 then Ok (List.nth args 1, Default)
  else
    let flag = List.nth args 2 in
    let mode =
      match flag with
      | "--inspect" -> Some Inspect
      | "--header-navigation" -> Some Header_navigation
      | "--composer" -> Some Composer
      | "--outliner" -> Some Outliner
      | "--fixture" -> Some Fixture
      | "--performance" -> Some Performance
      | _ ->
        (match String.split_on_char '=' flag with
         | [ "--performance"; size ] -> parse_performance_size size
         | _ -> None)
    in
    match mode with
    | Some mode -> Ok (List.nth args 1, mode)
    | None -> Error (2, "unknown seed mode: " ^ flag)

let now_ms () = int_of_float (Unix.gettimeofday () *. 1000.0)

let seed_mode conn mode =
  match mode with
  | Inspect -> Ok ()
  | Header_navigation -> Seed.seed_header_navigation conn
  | Composer -> Seed.seed_composer conn (now_ms ())
  | Outliner -> Seed.seed_outliner conn (now_ms ())
  | Fixture -> Seed.seed_fixture conn
  | Performance -> Seed.seed_performance conn (now_ms ())
  | PerformanceSized (journals, blocks) ->
    Seed.seed_performance_sized conn (now_ms ()) journals blocks
  | Default -> Seed.seed conn

let execute path mode =
  let ( let* ) = Result.bind in
  let* conn = Store.restore_conn path in
  let* () = seed_mode conn mode in
  let* () =
    match mode with
    | Inspect -> Ok ()
    | _ ->
      (* seeding replaces local entities; queued ops referencing entities
         that no longer exist can never complete, so drop them *)
      Ok
        (List.iter
           (fun (operation : Ops.pending_operation) ->
             Ops.remove path operation.operation_id)
           (Ops.list path))
  in
  let* db = Store.restore_db path in
  let plain value = Ok value in
  let blocks = Graph.blocks plain 7 db in
  let tag_pages = Graph.tag_pages plain db in
  let favorites = (Graph.sidebar_pages plain db).favorites in
  let due = Cards.due_cards db (now_ms ()) in
  let projected_due =
    if mode = Inspect then
      let snapshot = Projection.build 1 db (Ops.list path) in
      Cards.due_cards snapshot.db (now_ms ())
    else due
  in
  Ok
    (Printf.sprintf
       "Seeded iOS E2E graph: %s journals=%d visible-blocks=%d tags=%d \
        favorites=%d due-flashcards=%d projected-due-flashcards=%d"
       path (Graph.journal_page_count db) (List.length blocks)
       (List.length tag_pages) (List.length favorites)
       (List.length due) (List.length projected_due))

let run args =
  match parse_args args with
  | Error failure -> failure
  | Ok (path, mode) ->
    (match execute path mode with
     | Ok message -> (0, message)
     | Error message -> (1, message))
