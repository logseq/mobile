module Ds = Datascript
module Dev = Dev_sync
module Wire = Dev.Wire

type entry = { t : int; tx_id : string option; tx : Wire.t list }
type journal =
  { t : int; t_before : int option; entries : entry list; graph_id : string option }

let non_negative name fields =
  match List.assoc_opt name fields with
  | Some (`Int n) when n >= 0 -> n
  | _ -> invalid_arg ("journal requires non-negative integer " ^ name)

let decode body =
  try
    match Yojson.Basic.from_string body with
    | `Assoc fields ->
      let typ = List.assoc_opt "type" fields in
      if typ <> Some (`String "pull/ok") && typ <> Some (`String "tx/batch/ok") then
        invalid_arg "expected pull/ok or tx/batch/ok journal";
      let t = non_negative "t" fields in
      (* Local routing context supplied by the host, not a server field. *)
      let graph_id = match List.assoc_opt "graphId" fields with
        | None -> None
        | Some (`String id) when id <> "" -> Some id
        | _ -> invalid_arg "invalid local graphId for journal"
      in
      let t_before =
        if typ = Some (`String "tx/batch/ok") then Some (non_negative "t-before" fields)
        else None
      in
      if Option.fold ~none:false ~some:(fun before -> before > t) t_before then
        invalid_arg "journal t-before exceeds watermark";
      let previous = ref (-1) in
      let entries =
        match List.assoc_opt "txs" fields with
        | Some (`List rows) ->
          List.map
            (function
              | `Assoc fields ->
                let row_t = non_negative "t" fields in
                if row_t <= !previous || row_t > t then
                  invalid_arg "journal rows must be ordered within the watermark";
                previous := row_t;
                let tx =
                  match List.assoc_opt "tx" fields with
                  | Some (`String text) ->
                    (match Dev.Transit_codec.of_string text with
                     | Wire.Array items | Wire.List items -> items
                     | _ -> invalid_arg "journal tx must be a Transit sequence")
                  | _ -> invalid_arg "journal row requires Transit tx"
                in
                let tx_id =
                  match List.assoc_opt "tx-id" fields with
                  | None | Some `Null -> None
                  | Some (`String id) when id <> "" -> Some id
                  | _ -> invalid_arg "journal row has invalid tx-id"
                in
                { t = row_t; tx_id; tx }
              | _ -> invalid_arg "journal row must be an object")
            rows
        | _ -> invalid_arg "journal requires txs"
      in
      Ok { t; t_before; entries; graph_id }
    | _ -> Error "journal must be an object"
  with error -> Error (Printexc.to_string error)

let map_protected transform items =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest ->
      let ( let* ) = Result.bind in
      let* item =
        match item with
        | Wire.Array (op :: e :: Wire.Keyword attr :: Wire.String text :: tail)
        | Wire.List (op :: e :: Wire.Keyword attr :: Wire.String text :: tail)
          when Dev.Sync_const.is_encrypt_attr attr ->
          let* text = transform text in
          Ok (Wire.Array (op :: e :: Wire.Keyword attr :: Wire.String text :: tail))
        | _ -> Ok item
      in
      loop (item :: acc) rest
  in
  loop [] items

let capture ?creator db tx =
  let report = Ds.with_tx (Dev.Sync_replay.display_db_from_server db) tx in
  let report = match creator with
    | None -> report
    | Some identity ->
      match Created_by.additions identity report with
      | [] -> report
      | additions ->
        let authored = Ds.with_tx report.db_after additions in
        { report with db_after = authored.db_after;
          tx_data = List.rev_append (List.rev report.tx_data) authored.tx_data }
  in
  let forward = Dev.Sync_apply.normalize_tx_data report.db_after report.db_before report.tx_data in
  let reversed = Dev.Sync_apply.reverse_tx_data report.db_before report.db_after report.tx_data in
  report.db_after, Dev.Transit_codec.to_string (Wire.Array forward),
  Dev.Transit_codec.to_string (Wire.Array reversed)

let replay db operation_id outliner_op tx =
  let conn = Ds.conn_from_db (Dev.Sync_replay.display_db_from_server db) in
  let entry =
    { Dev.Sync_client_op.tx_id = operation_id; tx = Dev.Transit_codec.of_string tx;
      outliner_op = Some outliner_op }
  in
  Dev.Sync_replay.replay_pending_entry "mobile" conn entry;
  Ds.conn_db conn

let encode encrypt tx =
  try
    let items = Dev.Sync_apply.normalize_tx_data_for_rebase (Dev.Transit_codec.of_string tx) in
    Result.map (fun items -> Dev.Transit_codec.to_string (Wire.Array items))
      (map_protected encrypt items)
  with error -> Error (Printexc.to_string error)

let changed_uuids before after datoms =
  let seen = Hashtbl.create 16 in
  List.iter
    (fun (d : Ds.datom) ->
      List.iter
        (fun db ->
          match Ds.entity db (Ds.Entity_id d.e) with
          | Some e ->
            (match Ds.Entity.entity_attr_raw e "block/uuid" with
             | Some (Ds.One_value (Ds.Uuid uuid)) -> Hashtbl.replace seen uuid ()
             | _ -> ())
          | None -> ())
        [ before; after ])
    datoms;
  Hashtbl.fold (fun uuid () acc -> uuid :: acc) seen []

let apply decrypt conn local_t journal =
  try
    let ( let* ) = Result.bind in
    if journal.t <= local_t then Ok ([], [])
    else if Option.fold ~none:false ~some:(fun before -> local_t < before) journal.t_before then
      Error "journal prefix is missing; pull before applying ACK"
    else
      let before = Ds.conn_db conn in
      let temp = Ds.conn_from_db (Dev.Sync_replay.display_db_from_server before) in
      let rec loop reports ids = function
        | [] -> Ok (List.rev reports, List.rev ids)
        | (entry : entry) :: rest when entry.t <= local_t -> loop reports ids rest
        | entry :: rest ->
          let* tx = map_protected decrypt entry.tx in
          let tx =
            List.map (Dev.Sync_replay.resolve_temp_id (Ds.conn_db temp)) tx
            |> List.map Dev.Ds_wire.value_of_transit
            |> Dev.Db_sync_tx_sanitize.drop_conflicted_encrypted_retracts
            |> List.map Dev.Ds_wire.transit_of_value
          in
          let reports =
            match Dev.Db_transact.transact temp tx [] with
            | Some report -> List.rev_append report.tx_data reports
            | None -> reports
          in
          let ids = match entry.tx_id with None -> ids | Some id -> id :: ids in
          loop reports ids rest
      in
      let* datoms, ids = loop [] [] journal.entries in
      let after = Ds.conn_db temp in
      if datoms <> [] then
        ignore (Ds.apply_report conn
                  { Ds.db_before = before; db_after = after; tx_data = datoms;
                    tempids = []; tx_meta = [] });
      Ok (ids, changed_uuids before after datoms)
  with error -> Error (Printexc.to_string error)
