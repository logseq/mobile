module S = String_kit
module Inline = Mldoc.Inline

type markup_node =
  | Markup_text of string
  | Markup_emphasis of string * markup_node list
  | Markup_code of string
  | Markup_code_block of string option * string
  | Markup_quote of markup_node list
  | Markup_math of string * bool
  | Markup_video of string
  | Markup_iframe of string
  | Markup_html of string
  | Markup_image of string * string
  | Markup_youtube_timestamp of int * string
  | Markup_cloze of string
  | Markup_link of string * markup_node list
  | Markup_node_ref of string * string
  | Markup_tag_ref of string * string

let emphasis_string = function
  | "bold" -> "bold"
  | "italic" -> "italic"
  | "underline" -> "underline"
  | "strike-through" -> "strikeThrough"
  | "highlight" -> "highlight"
  | style -> style

let rec debug_string node =
  match node with
  | Markup_text value -> "Text(" ^ Printf.sprintf "%S" value ^ ")"
  | Markup_code value -> "Code(" ^ Printf.sprintf "%S" value ^ ")"
  | Markup_code_block (language, code) ->
    "CodeBlock(" ^ Printf.sprintf "%S" (Option.value ~default:"" language) ^ ","
    ^ Printf.sprintf "%S" code ^ ")"
  | Markup_quote children ->
    "Quote([" ^ String.concat ";" (List.map debug_string children) ^ "])"
  | Markup_math (expression, display) ->
    "Math(" ^ string_of_bool display ^ "," ^ Printf.sprintf "%S" expression ^ ")"
  | Markup_video url -> "Video(" ^ Printf.sprintf "%S" url ^ ")"
  | Markup_html html -> "Html(" ^ Printf.sprintf "%S" html ^ ")"
  | Markup_image (url, _) -> "Image(" ^ Printf.sprintf "%S" url ^ ")"
  | Markup_iframe url -> "Iframe(" ^ Printf.sprintf "%S" url ^ ")"
  | Markup_youtube_timestamp (seconds, label) ->
    "YoutubeTimestamp(" ^ string_of_int seconds ^ "," ^ Printf.sprintf "%S" label
    ^ ")"
  | Markup_cloze value -> "Cloze(" ^ Printf.sprintf "%S" value ^ ")"
  | Markup_node_ref (uuid, title) ->
    "Node(" ^ Printf.sprintf "%S" uuid ^ "," ^ Printf.sprintf "%S" title ^ ")"
  | Markup_tag_ref (uuid, title) ->
    "Tag(" ^ Printf.sprintf "%S" uuid ^ "," ^ Printf.sprintf "%S" title ^ ")"
  | Markup_emphasis (_, children) ->
    "Emphasis([" ^ String.concat ";" (List.map debug_string children) ^ "])"
  | Markup_link (url, children) ->
    "Link(" ^ Printf.sprintf "%S" url ^ ",["
    ^ String.concat ";" (List.map debug_string children)
    ^ "])"

let rec node_to_yojson node =
  let fields =
    match node with
    | Markup_text text ->
      [ ("type", `String "text"); ("text", `String text) ]
    | Markup_code text ->
      [ ("type", `String "code"); ("text", `String text) ]
    | Markup_code_block (language, code) ->
      [
        ("type", `String "codeBlock");
        ("text", `String code);
        ("style", `String (Option.value ~default:"" language));
      ]
    | Markup_quote children ->
      [
        ("type", `String "quote");
        ("children", `List (List.map node_to_yojson children));
      ]
    | Markup_math (expression, display) ->
      [
        ("type", `String "math");
        ("text", `String expression);
        ("style", `String (if display then "display" else "inline"));
      ]
    | Markup_video url ->
      [ ("type", `String "video"); ("url", `String url) ]
    | Markup_html html -> ["type", `String "html"; "text", `String html]
    | Markup_image (url, alt) -> ["type", `String "image"; "url", `String url; "text", `String alt]
    | Markup_iframe url ->
      [ ("type", `String "iframe"); ("url", `String url) ]
    | Markup_youtube_timestamp (seconds, label) ->
      [
        ("type", `String "youtubeTimestamp");
        ("text", `String label);
        ("style", `String (string_of_int seconds));
      ]
    | Markup_cloze text ->
      [ ("type", `String "cloze"); ("text", `String text) ]
    | Markup_emphasis (style, children) ->
      [
        ("type", `String "emphasis");
        ("style", `String (emphasis_string style));
        ("children", `List (List.map node_to_yojson children));
      ]
    | Markup_link (url, children) ->
      [
        ("type", `String "link");
        ("url", `String url);
        ("children", `List (List.map node_to_yojson children));
      ]
    | Markup_node_ref (uuid, title) ->
      [
        ("type", `String "nodeReference");
        ("uuid", `String uuid);
        ("title", `String title);
      ]
    | Markup_tag_ref (uuid, title) ->
      [
        ("type", `String "tagReference");
        ("uuid", `String uuid);
        ("title", `String title);
      ]
  in
  `Assoc fields

let to_yojson nodes = fst (Media.resolve_markup (`List (List.map node_to_yojson nodes)))

let config = Ref_text.config

let strip_wrapped left right value =
  if
    String.length value >= String.length left + String.length right
    && S.starts_with ~prefix:left value
    && S.ends_with ~suffix:right value
  then
    String.sub value (String.length left)
      (String.length value - String.length left - String.length right)
  else value

let find_summary summaries value =
  List.find_map
    (fun (summary : Cache_model.entity_summary) ->
      if
        value = summary.uuid
        || String.lowercase_ascii value
           = String.lowercase_ascii summary.Cache_model.title
      then Some summary
      else None)
    summaries

let append_node nodes node =
  match node with
  | Markup_text text ->
    if text = "" then nodes
    else
      (match List.rev nodes with
       | [] -> [ node ]
       | Markup_text previous :: rest ->
         List.rev (Markup_text (previous ^ text) :: rest)
       | _ -> nodes @ [ node ])
  | _ -> nodes @ [ node ]

let last_path_component value =
  List.filter (fun part -> part <> "") (String.split_on_char '/' value)
  |> List.fold_left (fun _ part -> Some part) None

let youtube_url value =
  let value = S.trim value in
  if S.starts_with ~prefix:"http://" value || S.starts_with ~prefix:"https://" value
  then value
  else "https://www.youtube.com/watch?v=" ^ value

let nonnegative_integer value =
  try
    let number = int_of_string value in
    if number >= 0 then Some number else None
  with Failure _ -> None

let clock_seconds parts =
  let numbers = List.filter_map nonnegative_integer parts in
  if List.length parts <> List.length numbers then None
  else
    match numbers with
    | [ seconds ] -> Some seconds
    | [ minutes; seconds ] ->
      if minutes <= 59 && seconds <= 59 then Some ((minutes * 60) + seconds)
      else None
    | [ hours; minutes; seconds ] ->
      if minutes <= 59 && seconds <= 59 then
        Some ((hours * 3600) + (minutes * 60) + seconds)
      else None
    | _ -> None

let two_digits value = if value < 10 then "0" ^ string_of_int value else string_of_int value

let youtube_timestamp value =
  match
    clock_seconds (String.split_on_char ':' (S.trim value))
  with
  | Some seconds ->
    let hours = seconds / 3600 in
    let minutes = seconds mod 3600 / 60 in
    let remainder = seconds mod 60 in
    let label =
      (if hours > 0 then two_digits hours ^ ":" else "")
      ^ two_digits minutes ^ ":" ^ two_digits remainder
    in
    Some (Markup_youtube_timestamp (seconds, label))
  | None -> None

let tweet_id value =
  let value = S.trim value in
  match String.split_on_char '?' value with
  | first :: _ ->
    (match last_path_component first with
     | Some component -> component
     | None -> value)
  | [] -> value

let fenced_code source =
  if S.starts_with ~prefix:"```" source && S.ends_with ~suffix:"```" source then
    match String.index_opt source '\n' with
    | Some newline ->
      let language = S.trim (String.sub source 3 (newline - 3)) in
      let length = String.length source - newline - 4 in
      if length >= 0 then
        Some
          (Markup_code_block
             ( (if language <> "" then Some language else None)
             , String.sub source (newline + 1) length ))
      else None
    | None -> None
  else None

let node_name (link : Mldoc.Nested_link.t) =
  S.trim (strip_wrapped "[[" "]]" link.content)

let source_slice source position =
  match position with
  | Some (position : Mldoc.Pos.pos_meta) ->
    if
      position.start_pos >= 0
      && position.end_pos >= position.start_pos
      && position.end_pos <= String.length source
    then String.sub source position.start_pos (position.end_pos - position.start_pos)
    else ""
  | None -> ""

let emphasis = function
  | `Bold -> "bold"
  | `Italic -> "italic"
  | `Underline -> "underline"
  | `Strike_through -> "strike-through"
  | `Highlight -> "highlight"

let rec tag_part node =
  match node with
  | Inline.Nested_link link -> node_name link
  | Inline.Link link ->
    (match link.url with
     | Inline.Page_ref value -> value
     | _ -> Inline.ascii node)
  | Inline.Plain value -> value
  | Inline.Spaces value -> value
  | _ -> Inline.ascii node

and convert_macro (macro : Inline.Macro.t) raw =
  let name = String.lowercase_ascii macro.name in
  let arguments = macro.arguments in
  if name = "cloze" then
    [ Markup_cloze (S.trim (String.concat ", " arguments)) ]
  else if arguments = [] then raw
  else
    let value = match arguments with v :: _ -> v | [] -> "" in
    match name with
    | "video" -> [ Markup_video (S.trim value) ]
    | "iframe" -> [ Markup_iframe (S.trim value) ]
    | "youtube" -> [ Markup_video (youtube_url value) ]
    | "youtube-timestamp" ->
      (match youtube_timestamp value with
       | Some node -> [ node ]
       | None -> [])
    | "vimeo" ->
      [ Markup_video ("https://player.vimeo.com/video/" ^ S.trim value) ]
    | "bilibili" ->
      [
        Markup_iframe
          ("https://player.bilibili.com/player.html?bvid=" ^ S.trim value);
      ]
    | "tweet" | "twitter" ->
      [
        Markup_iframe
          ("https://platform.twitter.com/embed/Tweet.html?id=" ^ tweet_id value);
      ]
    | _ -> raw

and convert_nodes source references tags nodes =
  let rec collect converted = function
    | (Inline.Inline_Html "<ins>", _) :: rest ->
      let rec closing inside = function
        | (Inline.Inline_Html "</ins>", _) :: rest -> Some (List.rev inside, rest)
        | node :: rest -> closing (node :: inside) rest
        | [] -> None in
      (match closing [] rest with
       | Some (inside, rest) -> collect (append_node converted
           (Markup_emphasis ("underline", convert_nodes source references tags inside))) rest
       | None -> collect (append_node converted (Markup_text "<ins>")) rest)
    | (node, position) :: rest -> collect
        (List.fold_left append_node converted (convert_node source references tags node position)) rest
    | [] -> converted in
  collect [] nodes

and convert_node source references tags node position =
  let raw = [ Markup_text (source_slice source position) ] in
  match node with
  | Inline.Plain value -> [ Markup_text value ]
  | Inline.Spaces value -> [ Markup_text value ]
  | Inline.Break_Line -> [ Markup_text "\n" ]
  | Inline.Hard_Break_Line -> [ Markup_text "\n" ]
  | Inline.Code value -> [ Markup_code value ]
  | Inline.Inline_Html html when S.starts_with ~prefix:"<ins>" html && S.ends_with ~suffix:"</ins>" html ->
    let inner = String.sub html 5 (String.length html - 11) in
    let children = match Angstrom.parse_string ~consume:Angstrom.Consume.All (Inline.parse config) inner with
      | Ok nodes -> convert_nodes inner references tags nodes | Error _ -> [Markup_text inner] in
    [Markup_emphasis ("underline", children)]
  | Inline.Verbatim value -> [ Markup_code value ]
  | Inline.Latex_Fragment (Inline.Inline expression) ->
    [ Markup_math (expression, false) ]
  | Inline.Latex_Fragment (Inline.Displayed expression) ->
    [ Markup_math (expression, true) ]
  | Inline.Export_Snippet ("html", html) -> [Markup_html html]
  | Inline.Macro macro -> convert_macro macro raw
  | Inline.Emphasis (style, children) ->
    [
      Markup_emphasis
        ( emphasis style
        , convert_nodes source references tags
            (List.map (fun child -> (child, None)) children) );
    ]
  | Inline.Nested_link link ->
    (match find_summary references (node_name link) with
     | Some summary ->
       [ Markup_node_ref (summary.Cache_model.uuid, summary.Cache_model.title) ]
     | None -> [ Markup_text (node_name link) ])
  | Inline.Tag children ->
    let value = S.trim (String.concat "" (List.map tag_part children)) in
    (match find_summary tags value with
     | Some summary ->
       [ Markup_tag_ref (summary.Cache_model.uuid, summary.Cache_model.title) ]
     | None -> [ Markup_text ("#" ^ value) ])
  | Inline.Link link when S.starts_with ~prefix:"![" link.full_text ->
    [Markup_image (Inline.string_of_url link.url, String.concat "" (List.map tag_part link.label))]
  | Inline.Link link ->
    (match link.url with
     | Inline.Block_ref _ -> raw
     | Inline.Page_ref value ->
       (match find_summary references value with
        | Some summary ->
          [
            Markup_node_ref
              (summary.Cache_model.uuid, summary.Cache_model.title);
          ]
        | None ->
          (match link.label with
           | [] | [ Inline.Plain "" ] -> [ Markup_text value ]
           | label ->
             convert_nodes source references tags
               (List.map (fun child -> (child, None)) label)))
     | _ ->
       [
         Markup_link
           ( (match link.url with
              | Inline.Complex { protocol; link = value }
                when S.includes ~sub:(protocol ^ "://") link.full_text ->
                protocol ^ "://" ^ value
              | url -> Inline.string_of_url url)
           , convert_nodes source references tags
               (List.map (fun child -> (child, None)) link.label) );
       ])
  | _ -> raw

let parse_inline references tags source =
  match
    Angstrom.parse_string ~consume:Angstrom.Consume.All (Inline.parse config)
      source
  with
  | Ok nodes -> convert_nodes source references tags nodes
  | Error _ -> [ Markup_text source ]

let parse references tags source =
  if source = "" then []
  else
    match fenced_code source with
    | Some node -> [ node ]
    | None ->
      if
        S.starts_with ~prefix:"$$" source && S.ends_with ~suffix:"$$" source
      then [ Markup_math (strip_wrapped "$$" "$$" source, true) ]
      else if S.starts_with ~prefix:">" source then
        [
          Markup_quote
            (parse_inline references tags (S.trim (String.sub source 1 (String.length source - 1))));
        ]
      else parse_inline references tags source

let plain_text nodes =
  let result = Buffer.create 64 in
  let rec append = function
    | Markup_text value | Markup_code value | Markup_math (value, _)
    | Markup_cloze value | Markup_code_block (_, value) -> Buffer.add_string result value
    | Markup_node_ref (_, label) -> Buffer.add_string result label
    | Markup_tag_ref (_, label) -> Buffer.add_char result '#'; Buffer.add_string result label
    | Markup_emphasis (_, nodes) | Markup_quote nodes | Markup_link (_, nodes) -> List.iter append nodes
    | Markup_image (_, label) -> Buffer.add_string result label
    | Markup_video _ | Markup_iframe _ | Markup_html _ | Markup_youtube_timestamp _ -> ()
  in
  List.iter append nodes;
  Buffer.contents result
