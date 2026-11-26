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

let print_samples name samples =
  let ms = median (List.map (fun (x, _, _) -> x) samples) in
  let allocated = median (List.map (fun (_, x, _) -> x) samples) in
  let size = median (List.map (fun (_, _, x) -> x) samples) in
  Printf.printf "%-20s %12.3f %14.0f %14d
%!" name ms allocated size

let benchmark db iterations =
  Printf.printf "%-20s %12s %14s %14s\n" "Operation" "Median ms" "Allocated B" "Response B";
  List.iter (fun (name, setup, run) ->
    let samples = List.init (iterations + 1) (fun _ ->
      Workload.with_session ~show_journal_tasks:(fun () -> String.ends_with ~suffix:"external_task" name)
        db (fun session ->
        setup session;
        let response, sample = measure (fun () -> run session) in
        ignore (Workload.result response);
        sample)) |> List.tl in
    print_samples name samples
  ) Workload.scenarios;
  let rtc name run =
    let samples = List.init iterations (fun _ ->
      Workload.with_session ~show_journal_tasks:(fun () -> false) db (fun session ->
        Workload.editing session;
        run session)) in
    print_samples name samples in
  rtc "rtc_during_edit" (fun session ->
    let receive = Workload.receive_journal session in
    let response, sample = measure receive in
    assert (Workload.member "appliedServerT" (Workload.result response) = `Int 43);
    sample);
  rtc "enter_with_rtc_x8" (fun session ->
    let transport = Workload.connected session in
    let started = Unix.gettimeofday () and before = Gc.allocated_bytes () in
    let responses = Workload.repeat_enter session transport 8 in
    ((Unix.gettimeofday () -. started) *. 1000., Gc.allocated_bytes () -. before,
      List.fold_left (fun size response -> size + String.length response) 0 responses))

let check_rtc_and_tasks db =
  Workload.with_session ~show_journal_tasks:(fun () -> false) db (fun session ->
    Workload.editing session;
    let receive = Workload.receive_journal session in
    let response, (_, allocated, size) = measure receive in
    let result = Workload.result response in
    assert (Workload.member "appliedServerT" result = `Int 43);
    assert (Workload.member "journalTasks" result = `Null);
    if allocated >= 24_000_000. || size >= 100_000 then
      failwith (Printf.sprintf "RTC update during editing allocated %.0f bytes and returned %d bytes" allocated size));
  Workload.with_session ~show_journal_tasks:(fun () -> false) db (fun session ->
    let transport = Workload.connected session in
    Workload.editing session;
    Workload.repeat_enter session transport 8 |> List.iter (fun response ->
      assert (Workload.member "journalTasks" (Workload.result response) = `Null);
      assert (String.length response < 100_000)));
  let visible = ref false in
  Workload.with_session ~show_journal_tasks:(fun () -> !visible) db (fun session ->
    let agenda response = Workload.member "journalTasks" (Workload.result response) in
    assert (agenda (Workload.open_journal session) = `Null);
    visible := true;
    let initial = agenda (Workload.dispatch session "clearSelectedPage" "") in
    let task section agenda = Json.Util.to_list (Workload.member section agenda)
      |> List.find_opt (fun row -> Workload.member "uuid" row = `String Workload.external_task) in
    assert (Option.is_some (task "today" initial));
    Workload.edit_external_task session;
    let response, (_, allocated, size) = measure (fun () -> Workload.type_external_task session) in
    assert (Workload.member "isOutlinerPatch" (Workload.result response) = `Bool true);
    assert (agenda response = `Null && size < 8_192 && allocated < 2_000_000.);
    let transport = Workload.connected session in
    let changed run =
      let response, (_, allocated, _) = measure run in
      if allocated >= 35_000_000. then failwith
        (Printf.sprintf "Task edit allocated %.0f bytes" allocated);
      let updated = agenda response in
      let _, ack = Workload.confirm_pending session transport in
      assert (agenda ack = updated);
      let refreshed = agenda (Workload.dispatch session "nodeProperty" (Json.to_string
        (`Assoc ["action", `String "refreshJournalTasks"; "day", Workload.member "day" updated]))) in
      assert (refreshed = updated);
      updated in
    let saved = changed (fun () -> Workload.save session) in
    let block section updated = Workload.member "block" (Option.get (task section updated)) in
    assert (Workload.member "title" (block "today" saved) = `String "Updated task");
    let status = changed (fun () -> Workload.external_task_status session) in
    assert (Workload.member "ident" (Workload.member "status" (block "today" status))
      = `String "logseq.property/status.doing");
    let date = changed (fun () -> Workload.external_task_date session) in
    assert (task "today" date = None && Option.is_some (task "upcoming" date)));
  print_endline "RTC edits, repeated Enter with confirmations, and Tasks edits are within budget"

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
    Printf.printf "Enter allocation %.0f bytes is within budget\n%!" enter_allocated);
  Workload.with_session db (fun session ->
    let older_journal = Workload.uuid (Workload.journal + 1) in
    ignore (Workload.result (Workload.dispatch session "selectPage" older_journal));
    let target = `String (Workload.uuid (Workload.row 1 2)) in
    ignore (Workload.result (Workload.event session "tapBlock" ["uuid", target]));
    let response, (_, enter_allocated, _) = measure (fun () -> Workload.enter session) in
    let result = Workload.result response in
    let editing = Workload.member "editing" (Workload.member "outlinerState" result) in
    assert (Workload.member "uuid" editing <> `Null);
    assert (Workload.member "uuid" editing <> target);
    if enter_allocated >= 2_000_000. then
      failwith (Printf.sprintf "Cross-journal enter allocated %.0f bytes" enter_allocated);
    Printf.printf "Cross-journal enter allocation %.0f bytes is within budget\n%!" enter_allocated)

let () =
  let db = Workload.fixture () in
  match Array.to_list Sys.argv with
  | [_] -> check db; check_rtc_and_tasks db
  | [_; "--bench"; count] when int_of_string count > 0 -> benchmark db (int_of_string count)
  | _ -> failwith "usage: outliner_perf [--bench ITERATIONS]"
