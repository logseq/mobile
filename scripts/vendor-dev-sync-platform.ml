(* Mobile platform adapters for the vendored dev sync code. This file is an
   input to scripts/vendor-dev-sync.py, not a standalone compilation unit. *)
module Schema = Datascript.Schema

module Worker_log = struct
  let info event fields =
    Metric_log.line
      (event ^ " " ^ String.concat " " (List.map (fun (k, v) -> k ^ "=" ^ v) fields))
  let warn = info
end

module Sync_state = struct
  let uuid_string s =
    String.length s = 36
    && String.for_all
         (fun c -> match c with '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' | '-' -> true | _ -> false) s
    && List.for_all (fun i -> s.[i] = '-') [ 8; 13; 18; 23 ]
    && String.fold_left (fun n c -> if c = '-' then n + 1 else n) 0 s = 4
end

module Ldb = struct
  let ref_ent entity attr =
    match Datascript.entity_attr entity attr with
    | Some (Datascript.One_value (Datascript.Ref eid)) ->
      Datascript.entity entity.Datascript.db (Datascript.Entity_id eid)
    | _ -> None
end

module Block_map = struct
  let of_transit value = value
  let to_tx_op _db value =
    match Datascript.parse_tx_data_string ("[" ^ Ds_wire.edn_of_transit value ^ "]") with
    | [ op ] -> op
    | _ -> invalid_arg "journal entity map must produce one operation"
end

(* TRANSact *)
let transact conn items meta =
  match items with
  | [] -> None
  | _ -> Some (Datascript.transact_conn ~tx_meta:meta conn
                 (tx_ops_of_tx_data (Datascript.conn_db conn) items))
(* APPLY *)
module Outliner_op = struct
  let entity_of_uuid db uuid =
    Datascript.entity db (Datascript.Lookup_ref ("block/uuid", Datascript.Uuid uuid))
end

module Sync_client_op = struct
  type pending_tx_row =
    { tx_id : string
    ; tx : Wire.t
    ; outliner_op : string option
    }
end
(* REPLAY *)
