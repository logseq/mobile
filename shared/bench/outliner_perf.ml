module Workload = Outliner_workload
module Json = Yojson.Basic

let measure f =
  let started = Unix.gettimeofday () in
  let allocated = Gc.allocated_bytes () in
  let response = f () in
  let bytes = Gc.allocated_bytes () -. allocated in
  let ms = (Unix.gettimeofday () -. started) *. 1000. in
  response, (ms, bytes, String.length response)

let median values = List.nth (List.sort compare values) (List.length values / 2)

let benchmark db iterations =
  Printf.printf "%-20s %12s %14s %14s\n" "Operation" "Median ms" "Allocated B" "Response B";
  List.iter (fun (name, setup, run) ->
    let samples = List.init (iterations + 1) (fun _ ->
      Workload.with_session db (fun session ->
        setup session;
        let response, sample = measure (fun () -> run session) in
        ignore (Workload.result response);
        sample)) |> List.tl in
    let ms = median (List.map (fun (x, _, _) -> x) samples) in
    let allocated = median (List.map (fun (_, x, _) -> x) samples) in
    let size = median (List.map (fun (_, _, x) -> x) samples) in
    Printf.printf "%-20s %12.3f %14.0f %14d\n%!" name ms allocated size
  ) Workload.scenarios

let check db =
  Workload.with_session db (fun session ->
    let today = Workload.result (Workload.open_today session) in
    let agenda = Workload.member "journalTasks" today in
    let count bucket = List.length (Json.Util.to_list (Workload.member bucket agenda)) in
    assert (count "today" > 100 && count "upcoming" > 100);
    let within_budget name allocation_limit run =
      let response, (_, allocated, size) = measure (fun () -> run session) in
      if size >= 8_192 || allocated >= allocation_limit then
        failwith (Printf.sprintf "Today %s allocated %.0f bytes and returned %d bytes" name allocated size);
      let result = Workload.result response in
      assert (Workload.member "journalTasks" result = `Null);
      result in
    Workload.tap session 2;
    let result = within_budget "typing" 1_000_000. Workload.type_text in
    let editing = Workload.member "editing" (Workload.member "outlinerState" result) in
    assert (Workload.member "title" editing = `String "Updated text");
    let saved = within_budget "saving a draft" 50_000_000. Workload.save in
    assert (Json.Util.to_list (Workload.member "blocks" saved) |> List.exists (fun block ->
      Workload.member "uuid" block = `String (Workload.block 2)
      && Workload.member "title" block = `String "Updated text"));
    Workload.tap session 2;
    Workload.move_caret_to_start session;
    let merged = within_budget "backspace merge" 50_000_000. Workload.backspace in
    let editing = Workload.member "editing" (Workload.member "outlinerState" merged) in
    assert (Workload.member "uuid" editing = `String (Workload.block 1));
    print_endline "Today typing, saving and backspace merge allocation and response sizes are within budget";
    let older_journal = Workload.uuid (Workload.journal + 1) in
    let done_task = `String (Workload.uuid (Workload.row 1 2)) in
    ignore (Workload.result (Workload.dispatch session "selectPage" older_journal));
    ignore (Workload.result (Workload.event session "tapBlock" ["uuid", done_task]));
    ignore (Workload.result (Workload.event session "textChanged"
      ["uuid", done_task; "title", `String "Updated completed task"; "caretUTF16Offset", `Int 22]));
    let saved = Workload.result (Workload.save session) in
    assert (Json.Util.to_list (Workload.member "blocks" saved) |> List.exists (fun block ->
      Workload.member "uuid" block = done_task
      && Workload.member "title" block = `String "Updated completed task"));
    if Workload.member "journalTasks" saved <> `Null then
      failwith "Saving a completed task resent an unchanged Today agenda";
    print_endline "Saving a completed task does not resend an unchanged Today agenda");
  (* Measure enter in a fresh session: pending operations from the checks above
     dominate allocation otherwise and hide the patch-encoding regression this
     budget guards. *)
  Workload.with_session db (fun session ->
    ignore (Workload.result (Workload.open_today session));
    Workload.tap session 2;
    let response, (_, enter_allocated, _) = measure (fun () -> Workload.enter session) in
    let result = Workload.result response in
    (* Guard against a no-op returnPressed: without an active edit the keystroke
       inserts nothing and the budget would pass without encoding any patch. *)
    let editing = Workload.member "editing" (Workload.member "outlinerState" result) in
    assert (Workload.member "uuid" editing <> `Null);
    assert (Workload.member "uuid" editing <> `String (Workload.block 2));
    if enter_allocated >= 2_000_000. then
      failwith (Printf.sprintf "Enter allocated %.0f bytes" enter_allocated);
    Printf.printf "Enter allocation %.0f bytes is within budget\n%!" enter_allocated)

let () =
  let db = Workload.fixture () in
  match Array.to_list Sys.argv with
  | [_] -> check db
  | [_; "--bench"; count] when int_of_string count > 0 -> benchmark db (int_of_string count)
  | _ -> failwith "usage: outliner_perf [--bench ITERATIONS]"
