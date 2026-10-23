open Test_util
open Markup

let summary uuid title : Cache_model.entity_summary = { uuid; title }

let parse = Markup.parse

let parse_bare source = parse [] [] source

let markup_json source = to_yojson (parse_bare source)

let rich_node_semantics () =
  check_eq
    [
      Markup_text "Hello ";
      Markup_emphasis ("bold", [ Markup_text "bold" ]);
      Markup_text " ";
      Markup_code "code";
      Markup_text " ";
      Markup_node_ref ("page-uuid", "Page target");
      Markup_text " ";
      Markup_node_ref ("block-uuid", "Block target");
      Markup_text " ";
      Markup_tag_ref ("tag-uuid", "Project");
    ]
    (parse
       [ summary "page-uuid" "Page target"; summary "block-uuid" "Block target" ]
       [ summary "tag-uuid" "Project" ]
       "Hello **bold** `code` [[page-uuid]] [[Block target]] #[[tag-uuid]]")

let reference_resolution_and_raw_source () =
  List.iter
    (fun source -> check_eq [ Markup_text source ] (parse_bare source))
    [ "Legacy ((block-uuid)) stays text"; "{{unknown value}}" ];
  check_eq
    [ Markup_text "Unknown missing" ]
    (parse_bare "Unknown [[missing]]");
  check_eq
    [ Markup_text "Unknown #missing" ]
    (parse_bare "Unknown #[[missing]]");
  check_eq
    [ Markup_text "\xF0\x9F\x98\x80 Unknown missing and #missing" ]
    (parse_bare "\xF0\x9F\x98\x80 Unknown [[missing]] and #[[missing]]");
  check_eq
    [
      Markup_text "Inline ";
      Markup_tag_ref ("tag-uuid", "Project");
      Markup_text " tag";
    ]
    (parse [] [ summary "tag-uuid" "Project" ] "Inline #[[Project]] tag");
  check_eq
    [ Markup_node_ref ("target-id", "Canonical Title") ]
    (parse [ summary "target-id" "Canonical Title" ] [] "[[canonical title]]")

let external_links_keep_hashtags_and_references_as_label_text () =
  let url = "https://github.com/logseq/logseq_journal/pull/90" in
  let source = "[PR #90](" ^ url ^ ")" in
  let references = [ summary "roadmap" "Roadmap" ] in
  let tags = [ summary "tag-90" "90"; summary "project" "project" ] in
  check_eq [ Markup_link (url, [ Markup_text "PR #90" ]) ]
    (parse references tags source);
  check_eq
    [ Markup_link (url, [ Markup_text "#project [[Roadmap]]" ]) ]
    (parse references tags ("[#project [[Roadmap]]](" ^ url ^ ")"));
  let normalized = Ref_text.to_ids (fun _ -> Some "roadmap")
    (fun _ -> Some "tag-90") source in
  check_eq [ Markup_link (url, [ Markup_text "PR #90" ]) ]
    (parse references tags normalized)

let external_link_protocols_preserve_source_separators () =
  List.iter (fun (source, url, label) ->
    check_eq ~msg:source [ Markup_link (url, [ Markup_text label ]) ]
      (parse_bare source))
    [
      ("https://example.com/#90", "https://example.com/#90", "https://example.com/#90");
      ("<https://example.com/#90>", "https://example.com/#90", "https://example.com/#90");
      ("[HTTP](http://example.com)", "http://example.com", "HTTP");
      ("<mailto:person@example.com>", "mailto:person@example.com", "mailto:person@example.com");
      ("[Email](mailto:person@example.com)", "mailto:person@example.com", "Email");
    ]

let issue_hashes_stay_literal_even_when_matching_tags_exist () =
  let source = "db-test#1442 (patches incl. #13730/#[[13732)]]." in
  let tags = [summary "tag-1442" "1442"; summary "tag-13730" "13730/";
    summary "tag-13732" "13732)"] in
  check_eq [Markup_text source] (parse [] tags source)

let stable_native_json_contract () =
  check_eq
    (Yojson.Basic.from_string
       "[{\"type\":\"text\",\"text\":\"Open \"},{\"type\":\"nodeReference\",\"uuid\":\"block-uuid\",\"title\":\"Target\"},{\"type\":\"tagReference\",\"uuid\":\"tag-uuid\",\"title\":\"Project\"}]")
    (to_yojson
       [
         Markup_text "Open ";
         Markup_node_ref ("block-uuid", "Target");
         Markup_tag_ref ("tag-uuid", "Project");
       ])

let inline_math_cloze_and_text_coalescing () =
  check_eq
    [
      Markup_text "Inline ";
      Markup_math ("x^2", false);
      Markup_text " math";
    ]
    (parse_bare "Inline $x^2$ math");
  check_eq [ Markup_cloze "first, second" ] (parse_bare "{{cloze first, second}}");
  check_eq [ Markup_cloze "" ] (parse_bare "{{cloze}}");
  List.iter
    (fun source -> check (fenced_code source = None))
    [ "```"; "plain" ];
  check_eq
    [ Markup_text "first second" ]
    (append_node [ Markup_text "first" ] (Markup_text " second"))

let timestamp_validation () =
  List.iter
    (fun (source, seconds, label) ->
       check_eq
         (Some (Markup_youtube_timestamp (seconds, label)))
         (youtube_timestamp source))
    [
      ("0", 0, "00:00");
      (" 83 ", 83, "01:23");
      ("59:59", 3599, "59:59");
      ("25:01:02", 90062, "25:01:02");
    ];
  List.iter
    (fun source -> check (youtube_timestamp source = None))
    [
      "";
      "-1";
      "60:00";
      "00:60";
      "1:60:00";
      "1:00:60";
      "1:2:3:4";
      "words";
      "999999999999999999999999999999";
    ];
  check_eq
    (Yojson.Basic.from_string "[]")
    (markup_json "{{youtube-timestamp 60:00}}")

let block_markup_boundaries () =
  check_eq (Yojson.Basic.from_string "[]") (markup_json "");
  check_eq
    (Yojson.Basic.from_string
       "[{\"type\":\"codeBlock\",\"text\":\"line 1\\nline 2\\n\",\"style\":\"\"}]")
    (markup_json "```\nline 1\nline 2\n```");
  check_eq
    (Yojson.Basic.from_string
       "[{\"type\":\"math\",\"text\":\"\",\"style\":\"display\"}]")
    (markup_json "$$$$");
  check_eq "123" (tweet_id " https://x.com/logseq/status/123/?tracking=true ");
  List.iter
    (fun (source, expected) ->
       check_eq (Yojson.Basic.from_string expected) (markup_json source))
    [
      ( "> quoted text"
      , "[{\"type\":\"quote\",\"children\":[{\"type\":\"text\",\"text\":\"quoted text\"}]}]" );
      ( "$$x^2 + y^2$$"
      , "[{\"type\":\"math\",\"text\":\"x^2 + y^2\",\"style\":\"display\"}]" );
      ( "```swift\nlet value = 1\n```"
      , "[{\"type\":\"codeBlock\",\"text\":\"let value = 1\\n\",\"style\":\"swift\"}]" );
      ( "{{cloze Remember this}}"
      , "[{\"type\":\"cloze\",\"text\":\"Remember this\"}]" );
    ]

let playable_and_web_embeds () =
  List.iter (fun (source, expected) ->
    check (Yojson.Basic.equal (Yojson.Basic.from_string expected) (markup_json source))) [
    "{{video https://cdn.example.com/demo.mp4}}",
      {|[{"type":"video","url":"https://cdn.example.com/demo.mp4"}]|};
    "{{iframe https://example.com/embed}}",
      {|[{"type":"iframe","url":"https://example.com/embed","embedURL":"https://example.com/embed","mediaHeaders":{},"positionParameter":"start"}]|};
    "{{youtube dQw4w9WgXcQ}}",
      {|[{"type":"video","url":"https://www.youtube.com/watch?v=dQw4w9WgXcQ","embedURL":"https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?playsinline=1","mediaHeaders":{"Referer":"https://logseq.com/"},"positionParameter":"start"}]|};
    "{{vimeo 76979871}}",
      {|[{"type":"video","url":"https://player.vimeo.com/video/76979871","embedURL":"https://player.vimeo.com/video/76979871","mediaHeaders":{},"positionParameter":"start"}]|};
    "{{bilibili BV1xx411c7mD}}",
      {|[{"type":"iframe","url":"https://player.bilibili.com/player.html?bvid=BV1xx411c7mD","embedURL":"https://player.bilibili.com/player.html?bvid=BV1xx411c7mD","mediaHeaders":{},"positionParameter":"start"}]|};
    "{{twitter https://x.com/logseq/status/1234567890}}",
      {|[{"type":"iframe","url":"https://platform.twitter.com/embed/Tweet.html?id=1234567890","embedURL":"https://platform.twitter.com/embed/Tweet.html?id=1234567890","mediaHeaders":{},"positionParameter":"start"}]|};
    "{{youtube-timestamp 83}}",
      {|[{"type":"youtubeTimestamp","text":"01:23","style":"83","url":null,"seconds":83}]|};
    "{{youtube-timestamp 01:01:23}}",
      {|[{"type":"youtubeTimestamp","text":"01:01:23","style":"3683","url":null,"seconds":3683}]|};
  ]

let mixed_embeds_retain_surrounding_text () =
  check_eq
    (Yojson.Basic.from_string
       "[{\"type\":\"text\",\"text\":\"Before \"},{\"type\":\"video\",\"url\":\"https://cdn.example.com/demo.mp4\"},{\"type\":\"text\",\"text\":\" after\"}]")
    (markup_json "Before {{video https://cdn.example.com/demo.mp4}} after")

let cases =
  [
    case "rich node semantics" rich_node_semantics;
    case "reference resolution and raw source" reference_resolution_and_raw_source;
    case "external links keep hashtags and references as label text"
      external_links_keep_hashtags_and_references_as_label_text;
    case "issue hashes stay literal even when matching tags exist"
      issue_hashes_stay_literal_even_when_matching_tags_exist;
    case "external link protocols preserve source separators"
      external_link_protocols_preserve_source_separators;
    case "stable native json contract" stable_native_json_contract;
    case "inline math cloze and text coalescing" inline_math_cloze_and_text_coalescing;
    case "timestamp validation" timestamp_validation;
    case "block markup boundaries" block_markup_boundaries;
    case "playable and web embeds" playable_and_web_embeds;
    case "mixed embeds retain surrounding text" mixed_embeds_retain_surrounding_text;
  ]
