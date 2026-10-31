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

let cases = [
  case "calendar input leaves the engine lazy" calendar_inputs_do_not_start_the_engine;
  case "English expressions match master" english_inputs_match_chrono;
  case "date-time expressions keep local time" timestamp_inputs_keep_local_time;
  case "concurrent reference dates remain independent" parallel_references_remain_independent;
]
