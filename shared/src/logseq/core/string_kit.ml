(* Small string helpers matching the clojure.string / seq operations the
   ported code relies on. *)

let starts_with ~prefix s =
  let plen = String.length prefix in
  String.length s >= plen && String.sub s 0 plen = prefix

let ends_with ~suffix s =
  let slen = String.length suffix in
  let len = String.length s in
  len >= slen && String.sub s (len - slen) slen = suffix

let includes ~sub s =
  let n = String.length s and m = String.length sub in
  let rec go i =
    if m = 0 then true
    else if i + m > n then false
    else if String.sub s i m = sub then true
    else go (i + 1)
  in
  go 0

let index_of ~sub ?(start = 0) s =
  let n = String.length s and m = String.length sub in
  let rec go i =
    if m = 0 then Some start
    else if i + m > n then None
    else if String.sub s i m = sub then Some i
    else go (i + 1)
  in
  go start

let last_index_of ~sub s =
  let n = String.length s and m = String.length sub in
  let rec go i =
    if m = 0 then Some n
    else if i < 0 then None
    else if i + m <= n && String.sub s i m = sub then Some i
    else go (i - 1)
  in
  go (n - m)

let is_blank s =
  String.for_all
    (fun c -> c = ' ' || c = '\t' || c = '\n' || c = '\r' || c = '\012' || c = '\011')
    s

let trim s = String.trim s
let lower s = String.lowercase_ascii s
let upper s = String.uppercase_ascii s

let split ~on s =
  let sep_len = String.length on in
  if sep_len = 0 then [ s ]
  else
    let rec go start acc =
      match index_of ~sub:on ~start s with
      | None -> List.rev (String.sub s start (String.length s - start) :: acc)
      | Some i ->
        go (i + sep_len) (String.sub s start (i - start) :: acc)
    in
    go 0 []

let split_lines s = split ~on:"\n" s

let replace s ~match_ ~replacement =
  String.concat replacement (split ~on:match_ s)

let replace_first s ~match_ ~replacement =
  match index_of ~sub:match_ s with
  | None -> s
  | Some i ->
    String.sub s 0 i ^ replacement
    ^ String.sub s (i + String.length match_)
        (String.length s - i - String.length match_)

let sub s i len = String.sub s i len
let drop s n = if n >= String.length s then "" else String.sub s n (String.length s - n)
let take s n = if n >= String.length s then s else String.sub s 0 n
let char_at s i = String.make 1 s.[i]
let join = String.concat

let hex_of_char c = Printf.sprintf "%02x" (Char.code c)

let of_bytes b = Bytes.to_string b
let to_bytes s = Bytes.of_string s

let is_ascii_whitespace c =
  c = ' ' || c = '\t' || c = '\n' || c = '\r' || c = '\011' || c = '\012'

let utf8_sequence_length byte =
  if byte land 128 = 0 then 1
  else if byte land 224 = 192 then 2
  else if byte land 240 = 224 then 3
  else if byte land 248 = 240 then 4
  else 1

let utf16_units byte = if utf8_sequence_length byte = 4 then 2 else 1

let byte_index_of_utf16 value offset =
  let rec loop index units =
    if index >= String.length value || units >= max 0 offset then index
    else
      let byte = Char.code value.[index] in
      loop
        (min (String.length value) (index + utf8_sequence_length byte))
        (units + utf16_units byte)
  in
  loop 0 0

let utf16_length value =
  let rec loop index units =
    if index >= String.length value then units
    else
      let byte = Char.code value.[index] in
      loop
        (min (String.length value) (index + utf8_sequence_length byte))
        (units + utf16_units byte)
  in
  loop 0 0
