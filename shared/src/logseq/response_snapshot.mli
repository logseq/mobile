val decode_json_response : Yojson.Basic.t -> (Model.core_projection, string) result

val decode_response : string -> (Model.core_projection, string) result

val related_row : Yojson.Basic.t -> Model.outline_row option
