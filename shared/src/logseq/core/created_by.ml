module Ds = Datascript

type identity = { uuid : string; username : string; email : string }

let property = "logseq.property/created-by-ref"

let decode_payload text =
  let buffer = Buffer.create (String.length text * 3 / 4) in
  let bits = ref 0 and count = ref 0 in
  String.iter (fun character ->
    let value = match character with
      | 'A'..'Z' -> Char.code character - Char.code 'A'
      | 'a'..'z' -> Char.code character - Char.code 'a' + 26
      | '0'..'9' -> Char.code character - Char.code '0' + 52
      | '-' -> 62 | '_' -> 63 | '=' -> -1
      | _ -> invalid_arg "invalid JWT payload encoding" in
    if value >= 0 then begin
      bits := (!bits lsl 6) lor value;
      count := !count + 6;
      if !count >= 8 then begin
        count := !count - 8;
        Buffer.add_char buffer (Char.chr ((!bits lsr !count) land 255));
        bits := !bits land ((1 lsl !count) - 1)
      end
    end) text;
  Buffer.contents buffer

let of_token token =
  (* Authentication validates the token; this only reads the local actor claims. *)
  try
    match String.split_on_char '.' token with
    | [_; payload; _] ->
      let json = Yojson.Basic.from_string (decode_payload payload) in
      let string name = match Yojson.Basic.Util.member name json with
        | `String value -> value | _ -> "" in
      let uuid = String.lowercase_ascii (string "sub") in
      let valid = Ref_text.is_uuid uuid in
      if valid then Some { uuid; username = string "cognito:username"; email = string "email" }
      else None
    | _ -> None
  with Yojson.Json_error _ | Yojson.Basic.Util.Type_error _ | Invalid_argument _ -> None

let value db eid attr =
  Option.bind (Ds.entity db (Ds.Entity_id eid)) (fun entity ->
    match Ds.Entity.entity_attr_raw entity attr with
    | Some (Ds.One_value value) -> Some value | _ -> None)

let additions identity (report : Ds.tx_report) =
  let targets = Hashtbl.create 8 in
  List.iter (fun (datom : Ds.datom) ->
    if datom.added then begin
      let newly_created = datom.a = "block/uuid" && value report.db_before datom.e "block/uuid" = None
        && value report.db_after datom.e property = None in
      let first_text = datom.a = "block/title" && (match datom.v with
        | Ds.String title when not (String_kit.is_blank title) ->
          (match value report.db_before datom.e "block/title" with
           | None -> true | Some (Ds.String old) -> String_kit.is_blank old | _ -> false)
        | _ -> false) in
      if newly_created || first_text then Hashtbl.replace targets datom.e ()
    end) report.tx_data;
  if Hashtbl.length targets = 0 then [] else
  let actor, create = match Ds.entid report.db_after "block/uuid" (Ds.Uuid identity.uuid) with
    | Some eid -> Ds.Entity_id eid, []
    | None ->
      let actor = Ds.Temp_id "created-by" in
      let now = Int64.of_float (Unix.gettimeofday () *. 1000.) in
      let attributes = ["block/uuid", Ds.One_value (Ds.Uuid identity.uuid);
        "block/name", Ds.One_value (Ds.String identity.username);
        "block/title", Ds.One_value (Ds.String identity.username);
        "block/created-at", Ds.One_value (Ds.Int64 now);
        "block/updated-at", Ds.One_value (Ds.Int64 now);
        "logseq.property.user/name", Ds.One_value (Ds.String identity.username);
        "logseq.property.user/email", Ds.One_value (Ds.String identity.email)] in
      let attributes = match Ds.entid report.db_after "db/ident" (Ds.Keyword "logseq.class/Page") with
        | Some page -> ("block/tags", Ds.Many_values [Ds.Ref page]) :: attributes
        | None -> attributes in
      actor, [Ds.Entity { db_id = Some actor; attrs = attributes }] in
  Hashtbl.fold (fun eid () tx -> Ds.Add (Ds.Entity_id eid, property, Ds.Ref_to actor) :: tx) targets create
