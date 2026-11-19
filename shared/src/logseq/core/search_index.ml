module Ds = Datascript
module Graph = Graph_read
module Sql = Graph_sqlite
module Ref_text = Ref_text

let search_open = Sql.search_open
let search_upsert = Sql.search_upsert
let search_delete = Sql.search_delete
let search_query = Sql.search_query

type search_index =
  { path : string
  }

type search_result =
  { uuid : string
  ; title : string
  ; page_uuid : string
  ; is_page : bool
  }

type indexed_search_hit =
  { uuid : string
  ; title : string
  ; is_page : bool
  ; page : Cache_model.entity_summary option
  ; breadcrumbs : Cache_model.entity_summary list
  }

(* Count UTF-8 code points for search thresholds and editor matching. *)
let utf8_length value =
  let rec loop index length =
    if index = String.length value then length
    else
      loop (index + 1)
        (if Char.code value.[index] land 192 = 128 then length else length + 1)
  in
  loop 0 0

let utf8_chars value =
  let rec loop index start result =
    if index = String.length value then
      if start < index then
        result @ [ String.sub value start (index - start) ]
      else result
    else if index > start && Char.code value.[index] land 192 <> 128 then
      loop (index + 1) index (result @ [ String.sub value start (index - start) ])
    else loop (index + 1) start result
  in
  loop 0 0 []

let clean_str value =
  List.fold_left
    (fun value part -> String_kit.replace value ~match_:part ~replacement:"")
    (String.lowercase_ascii value)
    [ "["; " "; "\\"; "/"; "_"; "]"; "("; ")" ]

let str_len_distance left right =
  let left = float_of_int (utf8_length left) in
  let right = float_of_int (utf8_length right) in
  let longest = max left right in
  let shortest = min left right in
  if longest = 0.0 then 1.0 else 1.0 -. ((longest -. shortest) /. longest)

let fuzzy_score_cleaned query target =
  let rec loop query_index target_index mult acc =
    if query_index >= String.length query then
      acc
      +. str_len_distance query target
      +. (if String_kit.starts_with ~prefix:query target then 1010.0
          else if String_kit.includes ~sub:query target then 1000.0
          else 0.0)
      +. (if target_index >= String.length target then 1.0 else 0.0)
    else if target_index >= String.length target then 0.0
    else if query.[query_index] = target.[target_index] then
      loop (query_index + 1) (target_index + 1) (mult + 1)
        (acc +. float_of_int mult)
    else loop query_index (target_index + 1) 1 (acc -. 0.1)
  in
  loop 0 0 1 0.0

let fuzzy_score query target = fuzzy_score_cleaned (clean_str query) (clean_str target)

(* remove-accents 0.5.0, also used by frontend.common.search-fuzzy. *)
(* The MIT License (MIT)
   Copyright (c) 2015 Marin Atanasov

   Permission is hereby granted, free of charge, to any person obtaining a copy
   of this software and associated documentation files (the "Software"), to deal
   in the Software without restriction, including without limitation the rights
   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
   copies of the Software, and to permit persons to whom the Software is
   furnished to do so, subject to the following conditions:

   The above copyright notice and this permission notice shall be included in all
   copies or substantial portions of the Software.

   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
   SOFTWARE. *)
let completion_accents = lazy (
  let pairs = [
    ("À", "A"); ("Á", "A"); ("Â", "A"); ("Ã", "A"); ("Ä", "A");
    ("Å", "A"); ("Ấ", "A"); ("Ắ", "A"); ("Ẳ", "A"); ("Ẵ", "A");
    ("Ặ", "A"); ("Æ", "AE"); ("Ầ", "A"); ("Ằ", "A"); ("Ȃ", "A");
    ("Ả", "A"); ("Ạ", "A"); ("Ẩ", "A"); ("Ẫ", "A"); ("Ậ", "A");
    ("Ç", "C"); ("Ḉ", "C"); ("È", "E"); ("É", "E"); ("Ê", "E");
    ("Ë", "E"); ("Ế", "E"); ("Ḗ", "E"); ("Ề", "E"); ("Ḕ", "E");
    ("Ḝ", "E"); ("Ȇ", "E"); ("Ẻ", "E"); ("Ẽ", "E"); ("Ẹ", "E");
    ("Ể", "E"); ("Ễ", "E"); ("Ệ", "E"); ("Ì", "I"); ("Í", "I");
    ("Î", "I"); ("Ï", "I"); ("Ḯ", "I"); ("Ȋ", "I"); ("Ỉ", "I");
    ("Ị", "I"); ("Ð", "D"); ("Ñ", "N"); ("Ò", "O"); ("Ó", "O");
    ("Ô", "O"); ("Õ", "O"); ("Ö", "O"); ("Ø", "O"); ("Ố", "O");
    ("Ṍ", "O"); ("Ṓ", "O"); ("Ȏ", "O"); ("Ỏ", "O"); ("Ọ", "O");
    ("Ổ", "O"); ("Ỗ", "O"); ("Ộ", "O"); ("Ờ", "O"); ("Ở", "O");
    ("Ỡ", "O"); ("Ớ", "O"); ("Ợ", "O"); ("Ù", "U"); ("Ú", "U");
    ("Û", "U"); ("Ü", "U"); ("Ủ", "U"); ("Ụ", "U"); ("Ử", "U");
    ("Ữ", "U"); ("Ự", "U"); ("Ý", "Y"); ("à", "a"); ("á", "a");
    ("â", "a"); ("ã", "a"); ("ä", "a"); ("å", "a"); ("ấ", "a");
    ("ắ", "a"); ("ẳ", "a"); ("ẵ", "a"); ("ặ", "a"); ("æ", "ae");
    ("ầ", "a"); ("ằ", "a"); ("ȃ", "a"); ("ả", "a"); ("ạ", "a");
    ("ẩ", "a"); ("ẫ", "a"); ("ậ", "a"); ("ç", "c"); ("ḉ", "c");
    ("è", "e"); ("é", "e"); ("ê", "e"); ("ë", "e"); ("ế", "e");
    ("ḗ", "e"); ("ề", "e"); ("ḕ", "e"); ("ḝ", "e"); ("ȇ", "e");
    ("ẻ", "e"); ("ẽ", "e"); ("ẹ", "e"); ("ể", "e"); ("ễ", "e");
    ("ệ", "e"); ("ì", "i"); ("í", "i"); ("î", "i"); ("ï", "i");
    ("ḯ", "i"); ("ȋ", "i"); ("ỉ", "i"); ("ị", "i"); ("ð", "d");
    ("ñ", "n"); ("ò", "o"); ("ó", "o"); ("ô", "o"); ("õ", "o");
    ("ö", "o"); ("ø", "o"); ("ố", "o"); ("ṍ", "o"); ("ṓ", "o");
    ("ȏ", "o"); ("ỏ", "o"); ("ọ", "o"); ("ổ", "o"); ("ỗ", "o");
    ("ộ", "o"); ("ờ", "o"); ("ở", "o"); ("ỡ", "o"); ("ớ", "o");
    ("ợ", "o"); ("ù", "u"); ("ú", "u"); ("û", "u"); ("ü", "u");
    ("ủ", "u"); ("ụ", "u"); ("ử", "u"); ("ữ", "u"); ("ự", "u");
    ("ý", "y"); ("ÿ", "y"); ("Ā", "A"); ("ā", "a"); ("Ă", "A");
    ("ă", "a"); ("Ą", "A"); ("ą", "a"); ("Ć", "C"); ("ć", "c");
    ("Ĉ", "C"); ("ĉ", "c"); ("Ċ", "C"); ("ċ", "c"); ("Č", "C");
    ("č", "c"); ("C̆", "C"); ("c̆", "c"); ("Ď", "D"); ("ď", "d");
    ("Đ", "D"); ("đ", "d"); ("Ē", "E"); ("ē", "e"); ("Ĕ", "E");
    ("ĕ", "e"); ("Ė", "E"); ("ė", "e"); ("Ę", "E"); ("ę", "e");
    ("Ě", "E"); ("ě", "e"); ("Ĝ", "G"); ("Ǵ", "G"); ("ĝ", "g");
    ("ǵ", "g"); ("Ğ", "G"); ("ğ", "g"); ("Ġ", "G"); ("ġ", "g");
    ("Ģ", "G"); ("ģ", "g"); ("Ĥ", "H"); ("ĥ", "h"); ("Ħ", "H");
    ("ħ", "h"); ("Ḫ", "H"); ("ḫ", "h"); ("Ĩ", "I"); ("ĩ", "i");
    ("Ī", "I"); ("ī", "i"); ("Ĭ", "I"); ("ĭ", "i"); ("Į", "I");
    ("į", "i"); ("İ", "I"); ("ı", "i"); ("Ĳ", "IJ"); ("ĳ", "ij");
    ("Ĵ", "J"); ("ĵ", "j"); ("Ķ", "K"); ("ķ", "k"); ("Ḱ", "K");
    ("ḱ", "k"); ("K̆", "K"); ("k̆", "k"); ("Ĺ", "L"); ("ĺ", "l");
    ("Ļ", "L"); ("ļ", "l"); ("Ľ", "L"); ("ľ", "l"); ("Ŀ", "L");
    ("ŀ", "l"); ("Ł", "l"); ("ł", "l"); ("Ḿ", "M"); ("ḿ", "m");
    ("M̆", "M"); ("m̆", "m"); ("Ń", "N"); ("ń", "n"); ("Ņ", "N");
    ("ņ", "n"); ("Ň", "N"); ("ň", "n"); ("ŉ", "n"); ("N̆", "N");
    ("n̆", "n"); ("Ō", "O"); ("ō", "o"); ("Ŏ", "O"); ("ŏ", "o");
    ("Ő", "O"); ("ő", "o"); ("Œ", "OE"); ("œ", "oe"); ("P̆", "P");
    ("p̆", "p"); ("Ŕ", "R"); ("ŕ", "r"); ("Ŗ", "R"); ("ŗ", "r");
    ("Ř", "R"); ("ř", "r"); ("R̆", "R"); ("r̆", "r"); ("Ȓ", "R");
    ("ȓ", "r"); ("Ś", "S"); ("ś", "s"); ("Ŝ", "S"); ("ŝ", "s");
    ("Ş", "S"); ("Ș", "S"); ("ș", "s"); ("ş", "s"); ("Š", "S");
    ("š", "s"); ("Ţ", "T"); ("ţ", "t"); ("ț", "t"); ("Ț", "T");
    ("Ť", "T"); ("ť", "t"); ("Ŧ", "T"); ("ŧ", "t"); ("T̆", "T");
    ("t̆", "t"); ("Ũ", "U"); ("ũ", "u"); ("Ū", "U"); ("ū", "u");
    ("Ŭ", "U"); ("ŭ", "u"); ("Ů", "U"); ("ů", "u"); ("Ű", "U");
    ("ű", "u"); ("Ų", "U"); ("ų", "u"); ("Ȗ", "U"); ("ȗ", "u");
    ("V̆", "V"); ("v̆", "v"); ("Ŵ", "W"); ("ŵ", "w"); ("Ẃ", "W");
    ("ẃ", "w"); ("X̆", "X"); ("x̆", "x"); ("Ŷ", "Y"); ("ŷ", "y");
    ("Ÿ", "Y"); ("Y̆", "Y"); ("y̆", "y"); ("Ź", "Z"); ("ź", "z");
    ("Ż", "Z"); ("ż", "z"); ("Ž", "Z"); ("ž", "z"); ("ſ", "s");
    ("ƒ", "f"); ("Ơ", "O"); ("ơ", "o"); ("Ư", "U"); ("ư", "u");
    ("Ǎ", "A"); ("ǎ", "a"); ("Ǐ", "I"); ("ǐ", "i"); ("Ǒ", "O");
    ("ǒ", "o"); ("Ǔ", "U"); ("ǔ", "u"); ("Ǖ", "U"); ("ǖ", "u");
    ("Ǘ", "U"); ("ǘ", "u"); ("Ǚ", "U"); ("ǚ", "u"); ("Ǜ", "U");
    ("ǜ", "u"); ("Ứ", "U"); ("ứ", "u"); ("Ṹ", "U"); ("ṹ", "u");
    ("Ǻ", "A"); ("ǻ", "a"); ("Ǽ", "AE"); ("ǽ", "ae"); ("Ǿ", "O");
    ("ǿ", "o"); ("Þ", "TH"); ("þ", "th"); ("Ṕ", "P"); ("ṕ", "p");
    ("Ṥ", "S"); ("ṥ", "s"); ("X́", "X"); ("x́", "x"); ("Ѓ", "Г");
    ("ѓ", "г"); ("Ќ", "К"); ("ќ", "к"); ("A̋", "A"); ("a̋", "a");
    ("E̋", "E"); ("e̋", "e"); ("I̋", "I"); ("i̋", "i"); ("Ǹ", "N");
    ("ǹ", "n"); ("Ồ", "O"); ("ồ", "o"); ("Ṑ", "O"); ("ṑ", "o");
    ("Ừ", "U"); ("ừ", "u"); ("Ẁ", "W"); ("ẁ", "w"); ("Ỳ", "Y");
    ("ỳ", "y"); ("Ȁ", "A"); ("ȁ", "a"); ("Ȅ", "E"); ("ȅ", "e");
    ("Ȉ", "I"); ("ȉ", "i"); ("Ȍ", "O"); ("ȍ", "o"); ("Ȑ", "R");
    ("ȑ", "r"); ("Ȕ", "U"); ("ȕ", "u"); ("B̌", "B"); ("b̌", "b");
    ("Č̣", "C"); ("č̣", "c"); ("Ê̌", "E"); ("ê̌", "e"); ("F̌", "F");
    ("f̌", "f"); ("Ǧ", "G"); ("ǧ", "g"); ("Ȟ", "H"); ("ȟ", "h");
    ("J̌", "J"); ("ǰ", "j"); ("Ǩ", "K"); ("ǩ", "k"); ("M̌", "M");
    ("m̌", "m"); ("P̌", "P"); ("p̌", "p"); ("Q̌", "Q"); ("q̌", "q");
    ("Ř̩", "R"); ("ř̩", "r"); ("Ṧ", "S"); ("ṧ", "s"); ("V̌", "V");
    ("v̌", "v"); ("W̌", "W"); ("w̌", "w"); ("X̌", "X"); ("x̌", "x");
    ("Y̌", "Y"); ("y̌", "y"); ("A̧", "A"); ("a̧", "a"); ("B̧", "B");
    ("b̧", "b"); ("Ḑ", "D"); ("ḑ", "d"); ("Ȩ", "E"); ("ȩ", "e");
    ("Ɛ̧", "E"); ("ɛ̧", "e"); ("Ḩ", "H"); ("ḩ", "h"); ("I̧", "I");
    ("i̧", "i"); ("Ɨ̧", "I"); ("ɨ̧", "i"); ("M̧", "M"); ("m̧", "m");
    ("O̧", "O"); ("o̧", "o"); ("Q̧", "Q"); ("q̧", "q"); ("U̧", "U");
    ("u̧", "u"); ("X̧", "X"); ("x̧", "x"); ("Z̧", "Z"); ("z̧", "z");
    ("й", "и"); ("Й", "И"); ("ё", "е"); ("Ё", "Е");
  ] in
  let replacements = Hashtbl.create (List.length pairs) in
  List.iter (fun (from, to_) -> Hashtbl.add replacements from to_) pairs;
  Str.regexp (String.concat "\\|" (List.map (fun (from, _) -> Str.quote from) pairs)), replacements)

let ascii value = String.for_all (fun ch -> Char.code ch < 128) value

let completion_clean_ascii_str value =
  let stripped = function '[' | ' ' | '\\' | '/' | '_' | ']' | '(' | ')' -> true | _ -> false in
  let rec scan index =
    if index = String.length value then Some value
    else
      let ch = value.[index] in
      if Char.code ch >= 128 then None
      else if stripped ch || ch >= 'A' && ch <= 'Z' then (
        let output = Buffer.create (String.length value) in
        Buffer.add_substring output value 0 index;
        let rec copy index =
          if index = String.length value then Some (Buffer.contents output)
          else
            let ch = value.[index] in
            if Char.code ch >= 128 then None
            else (if not (stripped ch) then Buffer.add_char output (Char.lowercase_ascii ch);
              copy (index + 1)) in
        copy index)
      else scan (index + 1) in
  scan 0

let completion_clean_str value =
  match completion_clean_ascii_str value with
  | Some value -> value
  | None ->
    let value = clean_str (Dev_query.Unicode.lowercase value) in
    let normalizer = Uunf.create `NFKC in
    let output = Buffer.create (String.length value) in
    let rec add input = match Uunf.add normalizer input with
      | `Uchar ch -> Buffer.add_utf_8_uchar output ch; add `Await
      | `Await | `End -> () in
    let rec loop index =
      if index < String.length value then (
        let ch = String.get_utf_8_uchar value index in
        add (`Uchar (Uchar.utf_decode_uchar ch));
        loop (index + Uchar.utf_decode_length ch)) in
    loop 0;
    add `End;
    let value = Buffer.contents output in
    if ascii value then value
    else
      let pattern, replacements = Lazy.force completion_accents in
      Str.global_substitute pattern
        (fun value -> Hashtbl.find replacements (Str.matched_string value)) value

let completion_score_ascii_cleaned query target =
  let qlen = String.length query and slen = String.length target in
  let distance = if max qlen slen = 0 then 1.0 else
    1.0 -. (float_of_int (abs (qlen - slen)) /. float_of_int (max qlen slen)) in
  if String.starts_with ~prefix:query target then
    let length = float_of_int qlen in
    length *. (length +. 1.0) /. 2.0 +. distance +. 1010.0
    +. (if qlen = slen then 1.0 else 0.0)
  else
    let rec contains start index =
      if index = qlen then true
      else if start + qlen > slen then false
      else if target.[start + index] = query.[index] then contains start (index + 1)
      else contains (start + 1) 0 in
    let rec loop qi si mult score =
      if qi = qlen then score +. distance
        +. (if contains 0 0 then 1000.0 else 0.0)
        +. (if si = slen then 1.0 else 0.0)
      else if si = slen then 0.0
      else if query.[qi] = target.[si] then loop (qi + 1) (si + 1) (mult + 1) (score +. float_of_int mult)
      else loop qi (si + 1) 1 (score -. 0.1) in
    loop 0 0 1 0.0

let completion_score_cleaned query target =
  if ascii query && ascii target then completion_score_ascii_cleaned query target
  else
    let units value =
      let rec loop index acc =
        if index = String.length value then Array.of_list (List.rev acc)
        else
          let decoded = String.get_utf_8_uchar value index in
          let cp = Uchar.to_int (Uchar.utf_decode_uchar decoded) in
          let acc = if cp < 0x10000 then cp :: acc
            else let cp = cp - 0x10000 in
              (0xDC00 + (cp land 0x3FF)) :: (0xD800 + (cp lsr 10)) :: acc in
          loop (index + Uchar.utf_decode_length decoded) acc in
      loop 0 [] in
    let q = units query and s = units target in
    let qlen = Array.length q and slen = Array.length s in
    let rec loop qi si mult score =
      if qi = qlen then score
        +. (1.0 -. (float_of_int (abs (qlen - slen)) /. float_of_int (max qlen slen)))
        +. (if String.starts_with ~prefix:query target then 1010.0
            else if String_kit.includes ~sub:query target then 1000.0 else 0.0)
        +. (if si = slen then 1.0 else 0.0)
      else if si = slen then 0.0
      else if q.(qi) = s.(si) then loop (qi + 1) (si + 1) (mult + 1) (score +. float_of_int mult)
      else loop qi (si + 1) 1 (score -. 0.1) in
    loop 0 0 1 0.0

let completion_score query target =
  completion_score_cleaned (completion_clean_str query) (completion_clean_str target)

let fts_phrase_input input =
  "\"" ^ String_kit.replace input ~match_:"\"" ~replacement:"\"\"" ^ "\"*"

let matches_regex pattern input =
  try
    ignore (Str.search_forward (Str.regexp pattern) input 0);
    true
  with Not_found -> false

let whitespace_char value = List.mem value [ ' '; '\t'; '\n'; '\r'; '\011'; '\012' ]

let dangling_boolean_operator input =
  let input = String.map (fun ch -> if whitespace_char ch then ' ' else ch) input in
  matches_regex "\\(^\\| \\)\\(AND\\|OR\\|NOT\\) *$" input

let word_char value =
  let code = Char.code value in
  (code >= 97 && code <= 122)
  || (code >= 65 && code <= 90)
  || (code >= 48 && code <= 57)
  || code = 95

let has_punctuation query =
  String.exists
    (fun ch -> (not (word_char ch)) && not (whitespace_char ch))
    query

let get_match_input query =
  let input =
    List.fold_left
      (fun input (from, to_) -> String_kit.replace input ~match_:from ~replacement:to_)
      query
      [
        (" and ", " AND ");
        (" & ", " AND ");
        (" or ", " OR ");
        (" | ", " OR ");
        (" not ", " NOT ");
      ]
  in
  let boolean_operator =
    List.exists
      (fun operator -> String_kit.includes ~sub:operator input)
      [ "AND"; "OR"; "NOT" ]
  in
  if dangling_boolean_operator input then fts_phrase_input input
  else if
    has_punctuation query
    && (String_kit.includes ~sub:"\"" input || not boolean_operator
        || String_kit.includes ~sub:"/" query)
  then fts_phrase_input input
  else if query <> input then
    String_kit.replace input ~match_:"," ~replacement:""
  else input

let create path =
  let directory = Filename.dirname path in
  (try
     if not (Sys.file_exists directory) then Unix.mkdir directory 0o755
   with Unix.Unix_error _ -> ());
  search_open path;
  { path }

let private_search_node db eid =
  (Graph.value db eid "logseq.property/built-in?" = Some (Ds.Bool true)
   && not (Graph.entity_is_instance_of db eid "logseq.class/Tag"))
  || Option.is_some (Graph.value db eid "block/closed-value-property")

let page_title_matches ~limit db query =
  let query = Dev_query.Unicode.lowercase (String.trim query) in
  let cleaned_query = completion_clean_str query in
  if cleaned_query = "" || limit <= 0
     || Seq.is_empty (Ds.Db.datoms db Ds.Aevt ~a:"block/name" ()) then []
  else
    (* Page names come from the live graph even during an FTS index rebuild. *)
    let compare_rank (exact_a, score_a, eid_a) (exact_b, score_b, eid_b) =
      let order = Bool.compare exact_a exact_b in
      if order <> 0 then order else
        let order = Float.compare score_a score_b in
        if order <> 0 then order else Int.compare eid_b eid_a in
    let module Top = Set.Make (struct
      type t = (bool * float * int) * Cache_model.entity_summary
      let compare (a, _) (b, _) = compare_rank a b
    end) in
    let best = ref Top.empty in
    let count = ref 0 in
    let worst_rank = ref None in
    let seen = Hashtbl.create limit in
    let offer rank (page : Cache_model.entity_summary) =
      let previous = Hashtbl.find_opt seen page.uuid in
      if Option.fold ~none:true ~some:(fun (old_rank, _) -> compare_rank rank old_rank > 0) previous then (
        (match previous with
         | Some old -> best := Top.remove old !best
         | None ->
           if !count = limit then (
             let (_, (removed : Cache_model.entity_summary)) as worst = Top.min_elt !best in
             best := Top.remove worst !best;
             Hashtbl.remove seen removed.uuid)
           else incr count);
        let entry = rank, page in
        best := Top.add entry !best;
        Hashtbl.replace seen page.uuid entry;
        if !count = limit then worst_rank := Some (fst (Top.min_elt !best))) in
    (* Index sequences can be single-pass; retain each head until consumed. *)
    let cursor attr = ref ((Ds.Db.datoms db Ds.Aevt ~a:attr ()) ()) in
    let names = cursor "block/name" and journals = cursor "block/journal-day" in
    let rec at cursor eid =
      match !cursor with
      | Seq.Cons ((datom : Ds.datom), rest) when datom.e < eid -> cursor := rest (); at cursor eid
      | Seq.Cons (datom, _) when datom.e = eid -> Some datom.v
      | _ -> None in
    let subsequence query target =
      let rec loop qi si =
        if qi = String.length query then true
        else if si = String.length target then false
        else loop (if query.[qi] = target.[si] then qi + 1 else qi) (si + 1) in
      loop 0 0 in
    let ascii_query = ascii cleaned_query in
    let score_page eid name title =
      match Graph.string_value name, title with
      | Some name, Some title ->
        let score =
          if ascii_query then match completion_clean_ascii_str title with
            | Some target ->
              if subsequence cleaned_query target then completion_score_ascii_cleaned cleaned_query target else 0.0
            | None -> completion_score_cleaned cleaned_query (completion_clean_str title)
          else completion_score_cleaned cleaned_query (completion_clean_str title) in
        if score > 0.0 then (
          let rank = name = query, score, eid in
          if Option.fold ~none:true ~some:(fun worst -> compare_rank rank worst > 0) !worst_rank
             && not (private_search_node db eid) then
            Option.iter (offer rank) (Graph.page_summary (fun title -> Ok title) db eid))
      | _ -> () in
    Ds.Db.fold_datoms (fun () (datom : Ds.datom) ->
      match at names datom.e with
      | None -> ()
      | Some _ as name ->
        let title = match Graph.int_value (at journals datom.e) with
          | Some day when Journal.valid_day day -> Graph.entity_title (fun title -> Ok title) db datom.e
          | _ -> Graph.string_value (Some datom.v) in
        score_page datom.e name title)
      () db Ds.Aevt ~a:"block/title" ();
    Ds.Db.datoms db Ds.Aevt ~a:"block/journal-day" ()
    |> Seq.iter (fun (datom : Ds.datom) ->
      match Graph.int_value (Some datom.v) with
      | Some day when Journal.valid_day day ->
        score_page datom.e (Graph.value db datom.e "block/name")
          (Graph.entity_title (fun title -> Ok title) db datom.e)
      | _ -> ());
    Top.elements !best |> List.rev_map snd

let row_of_eid db eid =
  let title_for_uuid uuid =
    match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
    | Some eid ->
      (match Graph.entity_title (fun value -> Ok value) db eid with
       | Some title when String.trim title <> "" -> Some title
       | _ -> None)
    | None -> None
  in
  match Graph.uuid_value (Graph.value db eid "block/uuid") with
  | Some uuid ->
    (match Graph.entity_title (fun value -> Ok value) db eid with
     | Some title ->
       let hidden = private_search_node db eid || Graph.page_is_hidden db eid in
       if String.trim title <> "" && (not hidden) && utf8_length title <= 10000
       then
         let is_page =
           Option.is_some
             (Graph.string_value (Graph.value db eid "block/name"))
         in
         let page_uuid =
           if is_page then uuid
           else
             match
               Datascript_value.optional_ref_eid db "block/page"
                 (Graph.value db eid "block/page")
             with
             | Some page_eid ->
               (match
                  Graph.uuid_value (Graph.value db page_eid "block/uuid")
                with
                | Some page_uuid -> page_uuid
                | None -> uuid)
             | None -> uuid
         in
         let title =
           Ref_text.to_text title_for_uuid title_for_uuid title
         in
         let title =
           match Graph.int_value (Graph.value db eid "block/journal-day") with
           | Some day -> title ^ " " ^ string_of_int day
           | None -> title
         in
         Some (uuid, title, page_uuid)
       else None
     | None -> None)
  | None -> None

let row_for_uuid db uuid =
  match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
  | Some eid -> row_of_eid db eid
  | None -> None

let rows_of_db db =
  List.of_seq (Ds.Db.datoms db Ds.Aevt ~a:"block/uuid" ())
  |> List.filter_map (fun (datom : Ds.datom) -> row_of_eid db datom.e)

let referring_uuids db uuid =
  match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
  | Some eid ->
    List.of_seq
      (Ds.Db.datoms db Ds.Aevt ~a:"block/refs" ~v:(Ds.Ref eid) ())
    |> List.filter_map (fun (datom : Ds.datom) ->
      Graph.uuid_value (Graph.value db datom.e "block/uuid"))
  | None -> []

let refresh_uuids index before after uuids =
  let uuids =
    if Journal.format before = Journal.format after then uuids
    else
      Seq.fold_left (fun uuids (datom : Ds.datom) ->
        match Graph.uuid_for_eid after datom.e with Some uuid -> uuid :: uuids | None -> uuids)
        uuids (Ds.Db.datoms after Ds.Aevt ~a:"block/journal-day" ()) in
  let seen = Hashtbl.create 32 in
  let affected =
    List.concat_map
      (fun uuid ->
        uuid :: (referring_uuids before uuid @ referring_uuids after uuid))
      uuids
    |> List.filter (fun uuid ->
      if Hashtbl.mem seen uuid then false
      else begin
        Hashtbl.add seen uuid ();
        true
      end)
  in
  let wanted = List.filter_map (fun uuid -> row_for_uuid after uuid) affected in
  if affected <> [] then search_delete index.path affected;
  ignore (if wanted <> [] then search_upsert index.path wanted)

let refresh index db =
  let wanted = rows_of_db db in
  let stored = search_query index.path "select id, page, title from blocks" [] in
  let stored_by_id =
    List.fold_left
      (fun table (id, page, title) ->
        Hashtbl.replace table id (title, page);
        table)
      (Hashtbl.create 128) stored
  in
  let wanted_ids =
    List.fold_left
      (fun table (id, _, _) ->
        Hashtbl.replace table id ();
        table)
      (Hashtbl.create 128) wanted
  in
  let changed =
    List.filter
      (fun (id, title, page) ->
        match Hashtbl.find_opt stored_by_id id with
        | Some (stored_title, stored_page) ->
          stored_title <> title || stored_page <> page
        | None -> true)
      wanted
  in
  let stale =
    List.filter_map
      (fun (id, _, _) ->
        if Hashtbl.mem wanted_ids id then None else Some id)
      stored
  in
  if stale <> [] then search_delete index.path stale;
  ignore (if changed <> [] then search_upsert index.path changed)

let query_rows index sql binds =
  try search_query index.path sql binds with Failure _ -> []

let full_text_rows ?(prioritize_pages = false) ~offset ~limit index query =
  let query = String.trim query in
  let query = if String.starts_with ~prefix:"#" query && not (String.exists whitespace_char query)
    then String.sub query 1 (String.length query - 1) else query in
  if query = "" || limit <= 0 then [] else
    (* Trigram MATCH cannot find one or two characters. Search the same indexed
       content literally, keeping the result window bounded before hydration. *)
    let predicate, input =
      if utf8_length query < 3 then
        let escaped = List.fold_left (fun value symbol ->
          String_kit.replace value ~match_:symbol ~replacement:("\\" ^ symbol))
          query ["\\"; "%"; "_"] in
        "title LIKE ? ESCAPE '\\'", "%" ^ escaped ^ "%"
      else "title MATCH ?", get_match_input query in
    let order, rank_binds =
      if prioritize_pages then
        (* Rank page titles before LIMIT/OFFSET. Preserve the existing FTS
           order within each group so later pages continue where earlier ones ended. *)
        " ORDER BY CASE WHEN id <> page THEN 3 \
         WHEN title = ? COLLATE NOCASE THEN 0 \
         WHEN instr(lower(title), lower(?)) = 1 THEN 1 ELSE 2 END, rowid",
        [Sqlite3.Data.TEXT query; Sqlite3.Data.TEXT query]
      else "", [] in
    try Sql.with_search_db index.path (fun connection ->
      Sql.query connection
        ("SELECT id, page, title FROM blocks_fts WHERE " ^ predicate ^ order ^ " LIMIT ? OFFSET ?")
        (Sqlite3.Data.TEXT input :: rank_binds @ [Sqlite3.Data.INT (Int64.of_int limit);
         Sqlite3.Data.INT (Int64.of_int (max 0 offset))])
        (fun row ->
          let uuid = Sqlite3.column_text row 0 and page_uuid = Sqlite3.column_text row 1 in
          {uuid; page_uuid; title = Sqlite3.column_text row 2; is_page = uuid = page_uuid}))
    with Failure _ -> []

let search limit index query = full_text_rows ~offset:0 ~limit index query

let hydrate_hits db results =
  let entity_eid uuid = Ds.entid db "block/uuid" (Ds.Uuid uuid) in
  let plain uuid = Ok uuid in
  List.map
    (fun (result : search_result) ->
      let page =
        if result.is_page then None
        else
          match entity_eid result.page_uuid with
          | Some eid -> Graph.page_summary plain db eid
          | None -> None
      in
      let breadcrumbs =
        if result.is_page then []
        else
          match entity_eid result.uuid with
          | Some eid -> Graph.breadcrumbs plain db eid
          | None -> []
      in
      {
        uuid = result.uuid;
        title = (match entity_eid result.uuid with
          | Some eid when Option.fold ~none:false ~some:Journal.valid_day
              (Graph.int_value (Graph.value db eid "block/journal-day")) ->
            Option.value ~default:result.title (Graph.entity_title plain db eid)
          | _ -> result.title);
        is_page = result.is_page;
        page;
        breadcrumbs;
      })
    results

let search_hits limit index db query =
  let query = String.trim query in
  if limit <= 0 || query = "" then []
  else if utf8_length query < 3 then
    let query = Dev_query.Unicode.lowercase query in
    Ds.Db.datoms db Ds.Aevt ~a:"block/name" ()
    |> Seq.filter_map (fun (datom : Ds.datom) ->
      if Graph.page_is_hidden db datom.e then None else
      Option.bind (Graph.page_summary (fun value -> Ok value) db datom.e) (fun page ->
        if String_kit.includes ~sub:query (Dev_query.Unicode.lowercase page.title) then
          Some {uuid = page.uuid; title = page.title; is_page = true; page = None; breadcrumbs = []}
        else None))
    |> Seq.take limit |> List.of_seq
  else hydrate_hits db (search limit index query)

(* Rank before slicing and only hydrate the requested window. *)
let search_hits_page ~offset ~limit index db query =
  if limit <= 0 then [], false else
    let limit = min 100 limit in
    let results = full_text_rows ~prioritize_pages:true ~offset ~limit:(limit + 1) index query in
    let rec take n acc = function
      | [] -> List.rev acc, false
      | _ when n = 0 -> List.rev acc, true
      | hit :: rest -> take (n - 1) (hit :: acc) rest in
    let page, more = take limit [] results in
    hydrate_hits db page, more
