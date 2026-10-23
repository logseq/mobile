module D = Datascript

let default_format = "MMM do, yyyy"
let format_attr = "logseq.property.journal/title-format"

let month_short =
  [| "Jan"; "Feb"; "Mar"; "Apr"; "May"; "Jun"; "Jul"; "Aug"; "Sep"; "Oct";
     "Nov"; "Dec" |]

let month_long =
  [| "January"; "February"; "March"; "April"; "May"; "June"; "July";
     "August"; "September"; "October"; "November"; "December" |]

let weekday_names =
  [| "mon"; "tue"; "wed"; "thu"; "fri"; "sat"; "sun"; "monday"; "tuesday";
     "wednesday"; "thursday"; "friday"; "saturday"; "sunday" |]

(* common-date/built-in-journal-title-formatters *)
let built_in_journal_title_formatters =
  [ "do MMM yyyy"; "do MMMM yyyy"; "MMM do, yyyy"; "MMMM do, yyyy";
    "E, dd-MM-yyyy"; "E, dd.MM.yyyy"; "E, MM/dd/yyyy"; "E, yyyy/MM/dd";
    "EEE, dd-MM-yyyy"; "EEE, dd.MM.yyyy"; "EEE, MM/dd/yyyy";
    "EEE, yyyy/MM/dd"; "EEEE, dd-MM-yyyy"; "EEEE, dd.MM.yyyy";
    "EEEE, MM/dd/yyyy"; "EEEE, yyyy/MM/dd"; "dd-MM-yyyy"; "MM/dd/yyyy";
    "MM-dd-yyyy"; "MM_dd_yyyy"; "yyyy/MM/dd"; "yyyy-MM-dd";
    "yyyy-MM-dd EEE"; "yyyy-MM-dd EEEE"; "yyyy_MM_dd"; "yyyyMMdd";
    "yyyy\xE5\xB9\xB4MM\xE6\x9C\x88dd\xE6\x97\xA5" (* yyyy年MM月dd日 *) ]

(* common-date/journal-title-formatters — cljs (distinct (cons f
   built-in)) keeps the first occurrence, so f always leads even when it
   duplicates a built-in. *)
let journal_title_formatters (date_formatter : string option) : string list =
  match date_formatter with
  | None -> built_in_journal_title_formatters
  | Some f -> f :: List.filter (fun x -> x <> f) built_in_journal_title_formatters

(* ---- formatter lexer ---- *)

(* Token widths recorded for the inverse (format) direction:
   yy vs yyyy, MMM vs MMMM, E/EEE vs EEEE. *)
type tok =
  | TokYear of int
  | TokMonthNum
  | TokMonthName of int
  | TokDay
  | TokDayOrd
  | TokWeekday of int
  | TokLit of char

let tokens_of_formatter (fmt : string) : tok list =
  let n = String.length fmt in
  let try_at i t tok =
    let l = String.length t in
    if i + l <= n && String.sub fmt i l = t then Some (tok, i + l) else None
  in
  let rec lex i acc =
    if i >= n then List.rev acc
    else
      match
        List.find_map Fun.id
          [ try_at i "yyyy" (TokYear 4); try_at i "yy" (TokYear 2);
            try_at i "MMMM" (TokMonthName 4); try_at i "MMM" (TokMonthName 3);
            try_at i "MM" TokMonthNum; try_at i "dd" TokDay;
            try_at i "do" TokDayOrd; try_at i "EEEE" (TokWeekday 4);
            try_at i "EEE" (TokWeekday 3); try_at i "E" (TokWeekday 3) ]
      with
      | Some (t, i') -> lex i' (t :: acc)
      | None -> lex (i + 1) (TokLit fmt.[i] :: acc)
  in
  lex 0 []

let ordinal_suffix d =
  if d >= 11 && d <= 13 then "th"
  else match d mod 10 with
       | 1 -> "st" | 2 -> "nd" | 3 -> "rd" | _ -> "th"

(* Zeller-congruence weekday index aligned with weekday_names:
   0 = Mon .. 6 = Sun. *)
let weekday_index (y, m, d) =
  let y', m' = if m < 3 then (y - 1, m + 12) else (y, m) in
  let k = y' mod 100 and j = y' / 100 in
  (* h: 0 = Saturday *)
  let h =
    (d + ((13 * (m' + 1)) / 5) + k + (k / 4) + (j / 4) + (5 * j)) mod 7
  in
  let h = ((h mod 7) + 7) mod 7 in
  (h + 5) mod 7

(* tf/format inverse of date_of_formatter for the tokenized
   journal-title formatters. *)
let formatter_of_date (fmt : string) (year, month, day : int * int * int)
    : string =
  let pad2 n = Printf.sprintf "%02d" n in
  let b = Buffer.create 32 in
  List.iter
    (fun tok ->
      match tok with
      | TokLit c -> Buffer.add_char b c
      | TokYear w ->
          if w = 2 then Buffer.add_string b (pad2 (year mod 100))
          else Buffer.add_string b (Printf.sprintf "%04d" year)
      | TokMonthNum -> Buffer.add_string b (pad2 month)
      | TokMonthName w ->
          Buffer.add_string
            b
            (if w = 4 then month_long.(month - 1)
             else month_short.(month - 1))
      | TokDay -> Buffer.add_string b (pad2 day)
      | TokDayOrd ->
          Buffer.add_string
            b
            (string_of_int day ^ ordinal_suffix day)
      | TokWeekday w ->
          let i = weekday_index (year, month, day) in
          let name =
            if w = 4 then weekday_names.(i + 7) else weekday_names.(i)
          in
          (* tf/format emits capitalized English weekday names *)
          Buffer.add_string b (String.capitalize_ascii name))
    (tokens_of_formatter fmt);
  Buffer.contents b

(* common-date/int->journal-title *)
let int_to_journal_title (day : int) (date_formatter : string) : string =
  formatter_of_date
    date_formatter
    (day / 10000, (day / 100) mod 100, day mod 100)

let month_names = Array.to_list month_short

let valid_day day =
  let year = day / 10000 and month = day / 100 mod 100 and date = day mod 100 in
  let leap = year mod 4 = 0 && (year mod 100 <> 0 || year mod 400 = 0) in
  let days = match month with 2 -> if leap then 29 else 28 | 4 | 6 | 9 | 11 -> 30 | _ -> 31 in
  year >= 1 && year <= 9999 && month >= 1 && month <= 12 && date >= 1 && date <= days

let format db =
  Option.bind (D.entid db "db/ident" (D.Keyword "logseq.class/Journal")) (fun eid ->
    match Seq.uncons (D.Db.datoms db D.Eavt ~e:eid ~a:format_attr ()) with
    | Some ({D.v = D.String value; _}, _) when String.trim value <> "" -> Some value
    | _ -> None)
  |> Option.value ~default:default_format

let day_title day = int_to_journal_title day default_format
let title db day = int_to_journal_title day (format db)

let page_uuid day =
  Printf.sprintf "00000001-%04d-%04d-0000-000000000000" (day / 10000) (day mod 10000)
