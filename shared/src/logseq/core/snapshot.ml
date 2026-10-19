module Value = Transit_core.Json
module Codec = Transit_native.Transit.Json

type snapshot_row =
  { addr : int
  ; content : string
  ; addresses : string option
  }

type snapshot_parser =
  { max_frame_bytes : int
  ; buffer : string ref
  }

type snapshot_progress =
  { accepted_rows : int
  ; last_addr : int option
  ; has_root : bool
  ; has_tail : bool
  }

type snapshot_import =
  { graph_id : string
  ; schema_version : string
  ; baseline_t : int
  ; expected_rows : int option
  ; progress : snapshot_progress ref
  }

type snapshot_completed_import =
  { graph_id : string
  ; schema_version : string
  ; applied_server_t : int
  ; row_count : int
  }

let create_parser max_frame_bytes =
  if max_frame_bytes <= 0 then invalid_arg "max_frame_bytes must be positive"
  else { max_frame_bytes; buffer = ref "" }

let uint32_be source offset =
  let rec loop index length =
    if index = 4 then length
    else
      loop (index + 1)
        (Int64.logor (Int64.shift_left length 8)
           (Int64.of_int (Char.code source.[offset + index])))
  in
  loop 0 0L

let int_of_value input =
  match input with
  | Value.Int number -> Ok number
  | Value.Int64 number ->
    if
      Int64.compare number 0L >= 0
      && Int64.compare number (Int64.of_int max_int) <= 0
    then Ok (Int64.to_int number)
    else Error "snapshot row address must be a non-negative Transit integer"
  | _ -> Error "snapshot row address must be a non-negative Transit integer"

let optional_string input =
  match input with
  | Value.Null -> Ok None
  | Value.String text -> Ok (Some text)
  | _ -> Error "snapshot row addresses must be JSON text or nil"

let decode_row input =
  let ( let* ) = Result.bind in
  match input with
  | Value.Array [ addr; Value.String content; addresses ] ->
    let* addr = int_of_value addr in
    let* addresses = optional_string addresses in
    Ok { addr; content; addresses }
  | _ -> Error "snapshot row must be [addr, content, addresses]"

let decode_rows payload =
  try
    match Codec.of_string payload with
    | Value.Array values ->
      let rec loop rows remaining =
        match remaining with
        | [] -> Ok (List.rev rows)
        | input :: rest ->
          (match decode_row input with
           | Ok row -> loop (row :: rows) rest
           | Error _ as error -> error)
      in
      loop [] values
    | _ -> Error "snapshot frame payload must be a Transit row array"
  with
  | Value.Decode_error message -> Error message
  | Yojson.Json_error message -> Error message
  | Failure message -> Error message
  | Invalid_argument message -> Error message

let consume source max_frame_bytes =
  let ( let* ) = Result.bind in
  let rec loop offset rows =
    let remaining = String.length source - offset in
    if remaining < 4 then Ok (offset, rows)
    else
      let length64 = uint32_be source offset in
      if Int64.compare length64 (Int64.of_int max_frame_bytes) > 0 then
        Error "snapshot frame exceeds configured size limit"
      else
        let length = Int64.to_int length64 in
        let stop = offset + 4 + length in
        if remaining - 4 < length then Ok (offset, rows)
        else
          let* decoded = decode_rows (String.sub source (offset + 4) length) in
          loop stop (rows @ decoded)
  in
  loop 0 []

let feed parser chunk =
  let ( let* ) = Result.bind in
  let source = !(parser.buffer) ^ chunk in
  parser.buffer := source;
  let* consumed, rows = consume source parser.max_frame_bytes in
  parser.buffer := String.sub source consumed (String.length source - consumed);
  Ok rows

let finish_parser parser =
  if !(parser.buffer) = "" then Ok ()
  else Error "incomplete framed snapshot stream"

let create_stream_import graph_id schema_version baseline_t expected_rows =
  {
    graph_id;
    schema_version;
    baseline_t;
    expected_rows;
    progress =
      ref { accepted_rows = 0; last_addr = None; has_root = false; has_tail = false };
  }

let create_import graph_id schema_version baseline_t expected_rows =
  create_stream_import graph_id schema_version baseline_t (Some expected_rows)

let validate_rows state rows =
  let rec loop progress remaining =
    match remaining with
    | [] -> Ok progress
    | (row : snapshot_row) :: rest ->
      let addr = row.addr in
      let ordered =
        match progress.last_addr with
        | Some previous -> addr > previous
        | None -> true
      in
      if ordered then
        loop
          {
            accepted_rows = progress.accepted_rows + 1;
            last_addr = Some addr;
            has_root = progress.has_root || addr = 0;
            has_tail = progress.has_tail || addr = 1;
          }
          rest
      else Error "snapshot row addresses must be strictly increasing"
  in
  loop !(state.progress) rows

let accept_rows state rows =
  let ( let* ) = Result.bind in
  let* progress = validate_rows state rows in
  if Option.fold ~none:false ~some:(fun expected -> progress.accepted_rows > expected) state.expected_rows then
    Error "snapshot contains more rows than advertised"
  else begin
    state.progress := progress;
    Ok ()
  end

let finish_import state =
  let progress = !(state.progress) in
  if state.baseline_t < 0 then Error "snapshot baseline cursor must be non-negative"
  else if Option.fold ~none:false ~some:(fun expected -> expected < 0) state.expected_rows then
    Error "snapshot expected row count must be non-negative"
  else if Option.fold ~none:false ~some:(fun expected -> progress.accepted_rows <> expected) state.expected_rows then
    Error "snapshot row count does not match server metadata"
  else if not progress.has_root then
    Error "snapshot is missing DataScript root row 0"
  else if not progress.has_tail then
    Error "snapshot is missing DataScript tail row 1"
  else
    Ok
      {
        graph_id = state.graph_id;
        schema_version = state.schema_version;
        applied_server_t = state.baseline_t;
        row_count = progress.accepted_rows;
      }
