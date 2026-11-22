let style ~ident ~icon_id ~title =
  let value =
    String.lowercase_ascii
      (match ident with
       | Some ident -> ident
       | None ->
         (match icon_id with
          | Some icon_id -> icon_id
          | None -> title))
  in
  if String_kit.includes value ~sub:"backlog" then "backlog"
  else if
    String_kit.includes value ~sub:"in-review"
    || String_kit.includes value ~sub:"inreview"
  then "in-review"
  else if
    String_kit.includes value ~sub:"doing"
    || String_kit.includes value ~sub:"inprogress"
    || String_kit.includes value ~sub:"progress"
  then "doing"
  else if
    String_kit.includes value ~sub:"done"
    || String_kit.includes value ~sub:"circle-check"
  then "done"
  else if
    String_kit.includes value ~sub:"cancel"
    || String_kit.includes value ~sub:"circle-x"
  then "canceled"
  else "todo"

let icon = function
  | "backlog" -> "app:task-backlog"
  | "doing" -> "app:task-doing"
  | "in-review" -> "app:task-review"
  | "done" -> "app:task-done"
  | "canceled" -> "app:task-canceled"
  | _ -> "app:task-todo"

let palette =
  [ "backlog", ("#E8E8E8", "#92979E");
    "todo", ("#858585", "#7E7E7E");
    "doing", ("#EBBC00", "#D9B94C");
    "in-review", ("#0090FF", "#0090FF");
    "done", ("#5BB98C", "#6BC394");
    "canceled", ("#EB9091", "#EF9298") ]

let colors style ~custom =
  match custom with
  | Some color when String.starts_with ~prefix:"#" color -> color, color
  | Some token ->
    let name = if String.starts_with ~prefix:"task-" token
      then String.sub token 5 (String.length token - 5) else token in
    Option.value ~default:(List.assoc style palette) (List.assoc_opt name palette)
  | None -> List.assoc style palette
