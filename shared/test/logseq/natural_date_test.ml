open Test_util
let reference year month day hour minute =
  fst (Unix.mktime {Unix.tm_year=year-1900; tm_mon=month-1; tm_mday=day; tm_hour=hour;
    tm_min=minute; tm_sec=0; tm_wday=0; tm_yday=0; tm_isdst=false}) *. 1000.
let now = reference 2026 10 27 10 30

let calendar_inputs_do_not_start_the_engine () =
  let before = Natural_date.initialization_count () in
  List.iter (fun (input, expected) -> check_eq ~msg:input (Natural_date.day ~now_ms:now input) expected)
    ["2026-10-31", Some 20261031; "0044-03-15", Some 440315; "20261031", Some 20261031;
     "2026-02-30", None; "", None; String.make 4097 'x', None];
  check_eq ~msg:"canonical dates and rejected input never initialize JavaScript"
    (Natural_date.initialization_count ()) before

let english_inputs_match_chrono () =
  List.iter (fun (input, expected) ->
    check_eq ~msg:input (Natural_date.day ~now_ms:now input) expected)
    ["today", Some 20261027; "tomorrow", Some 20261028; "yesterday", Some 20261026;
     "next week", Some 20261103; "this week", Some 20261025; "last week", Some 20261020;
     "next month", Some 20261127; "last month", Some 20260927; "next year", Some 20271027;
     "next Friday", Some 20261106; "this Friday", Some 20261030; "last Friday", Some 20261023;
     "in 3 days", Some 20261030; "2 weeks from now", Some 20261110; "5 days ago", Some 20261022;
     "in two months", Some 20261227; "tomorrow at 3pm", Some 20261028;
     "January 1, 2000", Some 20000101; "not a date", None];
  check_eq ~msg:"the parser is initialized once and reused" (Natural_date.initialization_count ()) 1

let timestamp_inputs_keep_local_time () =
  List.iter (fun (input, expected) -> check_eq ~msg:input
    (Natural_date.timestamp ~now_ms:now input) (Some (int_of_float expected)))
    ["tomorrow at 3pm", reference 2026 10 28 15 0;
     "in 3 hours", now +. 10800000.;
     "2026-10-31 09:45", reference 2026 10 31 9 45;
     "1792719000000", 1792719000000.];
  check_eq (Natural_date.timestamp ~now_ms:now "not a date") None

let parallel_references_remain_independent () =
  let answers = Array.make 8 None in
  Array.init 8 (fun index -> Thread.create (fun () ->
    answers.(index) <- Natural_date.day ~now_ms:(reference 2026 10 (10+index) 12 0) "tomorrow") ())
  |> Array.iter Thread.join;
  Array.iteri (fun index answer -> check_eq answer (Some (20261011+index))) answers

let task_day_start () =
  let midnight = reference 2026 1 10 0 0 in
  List.iter (fun attr ->
    check ~msg:(attr ^ " local day start") (Natural_date.is_task_date_only attr midnight);
    check ~msg:(attr ^ " time remains visible") (not (Natural_date.is_task_date_only attr (midnight +. 3600000.)));
    check ~msg:(attr ^ " fractional milliseconds are not date-only") (not (Natural_date.is_task_date_only attr (midnight +. 1.))))
    ["logseq.property/scheduled"; "logseq.property/deadline"];
  check ~msg:"custom datetime midnight retains its time"
    (not (Natural_date.is_task_date_only "user.property/Appointment" midnight));
  ()

let timezone_case zone =
  let local millis =
    let t = Unix.localtime (millis /. 1000.) in
    t.Unix.tm_year + 1900, t.tm_mon + 1, t.tm_mday, t.tm_hour, t.tm_min, t.tm_sec in
  let expect_time label millis expected = check_eq ~msg:label (local millis) expected in
  let date_only millis = Natural_date.is_task_date_only "logseq.property/deadline" millis in
  match zone with
  | "America/Sao_Paulo" ->
    let gap = 1541300400000. in
    expect_time "gap previous second" (gap -. 1000.) (2018, 11, 3, 23, 59, 59);
    expect_time "gap first second" gap (2018, 11, 4, 1, 0, 0);
    check ~msg:"midnight DST gap starts at 01:00" (date_only gap);
    check ~msg:"later time on gap day is timed" (not (date_only (gap +. 3600000.)))
  | "America/Havana" ->
    let overlap = 1604203200000. in
    expect_time "first midnight" overlap (2020, 11, 1, 0, 0, 0);
    expect_time "repeated midnight" (overlap +. 3600000.) (2020, 11, 1, 0, 0, 0);
    check ~msg:"first midnight is date-only" (date_only overlap);
    check ~msg:"repeated midnight is date-only as on desktop" (date_only (overlap +. 3600000.))
  | "America/St_Johns" ->
    let rollback = 1257042660000. in
    expect_time "rollback previous second" (rollback -. 1000.) (2009, 11, 1, 0, 0, 59);
    expect_time "rollback instant" rollback (2009, 10, 31, 23, 1, 0);
    check ~msg:"backward date crossing remains timed" (not (date_only rollback))
  | _ -> failwith ("Unknown timezone test: " ^ zone)

let task_timezone_transitions () =
  List.iter (fun zone ->
    let env = Unix.environment () |> Array.to_list |> List.filter (fun entry ->
      not (String.starts_with ~prefix:"TZ=" entry || String.starts_with ~prefix:"LOGSEQ_TEST_TIMEZONE=" entry)) in
    let env = Array.of_list (("TZ=" ^ zone) :: ("LOGSEQ_TEST_TIMEZONE=" ^ zone) :: env) in
    let executable = Sys.executable_name in
    let pid = Unix.create_process_env executable [|executable|] env Unix.stdin Unix.stdout Unix.stderr in
    let _, status = Unix.waitpid [] pid in
    check_eq ~msg:("timezone subprocess: " ^ zone) status (Unix.WEXITED 0))
    ["America/Sao_Paulo"; "America/Havana"; "America/St_Johns"]

let cases = [
  case "task day starts" task_day_start;
  case "task timezone transitions" task_timezone_transitions;
  case "calendar input leaves the engine lazy" calendar_inputs_do_not_start_the_engine;
  case "English expressions match master" english_inputs_match_chrono;
  case "date-time expressions keep local time" timestamp_inputs_keep_local_time;
  case "concurrent reference dates remain independent" parallel_references_remain_independent;
]
