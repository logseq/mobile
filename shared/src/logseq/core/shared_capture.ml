let optional fields key = match List.assoc_opt key fields with
  | None | Some `Null -> Ok None
  | Some (`String value) -> let value = String.trim value in Ok (if value = "" then None else Some value)
  | _ -> Error ("Shared capture requires string " ^ key)

let web_url value =
  let lower = String.lowercase_ascii value in
  List.exists (fun prefix -> String_kit.starts_with ~prefix lower && String.length value > String.length prefix)
    ["https://"; "http://"]

let text fields =
  let ( let* ) = Result.bind in
  let* text = optional fields "text" in
  let* title = optional fields "title" in
  let* url = optional fields "url" in
  let text, url = match text, url with Some text, None when web_url text -> None, Some text | _ -> text, url in
  let title = match text, title, url with
    | Some text, Some title, None when String_kit.includes ~sub:title text -> None
    | _ -> title in
  let link = match url, title with
    | Some url, Some title when title <> url -> Some ("[" ^ title ^ "](" ^ url ^ ")")
    | Some url, _ -> Some url
    | None, title -> title in
  match List.filter_map Fun.id [text; link] with
  | [] -> Error "Shared capture is empty"
  | values -> Ok (String.concat "\n" values)

let deep_link fields =
  let ( let* ) = Result.bind in
  let* scheme = optional fields "scheme" in
  let* host = optional fields "host" in
  let query = match List.assoc_opt "query" fields with Some (`List values) -> values | _ -> [] in
  let values = List.fold_left (fun values -> function
    | `Assoc fields -> (match optional fields "name", optional fields "value" with
        | Ok (Some name), Ok (Some value) -> (name, `String value) :: List.remove_assoc name values
        | _ -> values)
    | _ -> values) [] query in
  if Option.map String.lowercase_ascii scheme <> Some "logseq" then Ok (`Ignore)
  else match Option.map String.lowercase_ascii host with
    | Some "graph" ->
      let* path = optional fields "path" in
      let graph = Option.map (fun path -> if String.starts_with ~prefix:"/" path then
        String.sub path 1 (String.length path - 1) else path) path in
      (match graph with
       | None | Some "" -> Error "A graph name or identifier is required"
       | Some graph ->
         let* page = optional values "page" in
         let* block = optional values "block-id" in
         Ok (`Graph (graph, page, block)))
    | Some "capture" -> (match text values with Ok value -> Ok (`Capture value) | Error _ -> Ok (`Quick_action "capture"))
    | Some ("audio" | "journal" as action) -> Ok (`Quick_action action)
    | _ -> Ok (`Ignore)
