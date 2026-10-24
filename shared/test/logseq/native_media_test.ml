open Test_util
module J = Yojson.Basic
module U = Yojson.Basic.Util
let video source = Markup.to_yojson [Markup.Markup_video source] |> U.to_list |> List.hd

let shared_video_requests_canonicalize_supported_sources () =
  List.iter (fun source ->
    let node = video source in
    check_eq (U.member "embedURL" node) (`String "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?playsinline=1&start=12");
    check_eq (U.member "Referer" (U.member "mediaHeaders" node)) (`String "https://logseq.com/")) [
    "https://youtu.be/dQw4w9WgXcQ?t=12";
    "https://www.youtube.com/watch?v=dQw4w9WgXcQ&start=12";
    "https://m.youtube.com/shorts/dQw4w9WgXcQ?t=12";
    "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?start=12"];
  check_eq (U.member "embedURL" (video "https://player.vimeo.com/video/123")) (`String "https://player.vimeo.com/video/123")

let media_projection_rejects_unsafe_urls_and_spoofed_youtube_hosts () =
  List.iter (fun source ->
    let node = video source in
    check_eq (U.member "url" node) `Null;
    check_eq (U.member "embedURL" node) `Null) ["javascript:alert(1)"; "file:///tmp/movie"; "data:text/html,test"];
  List.iter (fun source ->
    check_eq (U.member "embedURL" (video source)) `Null;
    check_eq (Rpc.youtube_target_urls [Rpc_test.video_block "bad" ("{{video " ^ source ^ "}}");
      Rpc_test.video_block "time" "{{youtube-timestamp 00:10}}"])
      []) ["https://youtube.com.evil.test/watch?v=dQw4w9WgXcQ"; "https://youtu.be/short"]

let inline_timestamps_are_projected_with_their_player () =
  let source = "https://youtu.be/dQw4w9WgXcQ" in
  let nodes = Markup.to_yojson [Markup.Markup_video source; Markup.Markup_youtube_timestamp (83, "01:23")]
    |> U.to_list in
  check_eq (U.member "url" (List.nth nodes 1)) (`String source);
  check_eq (U.member "seconds" (List.nth nodes 1)) (`Int 83)

let timestamp_zero_overrides_the_source_start_time () =
  let nodes = Markup.to_yojson [Markup.Markup_video "https://youtu.be/dQw4w9WgXcQ?t=12";
    Markup.Markup_youtube_timestamp (0, "00:00")] |> U.to_list in
  check_eq (U.member "embedURL" (List.nth nodes 1))
    (`String "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?playsinline=1&start=0")

let bare_youtube_links_render_as_players () =
  List.iter (fun source ->
    let nodes = Markup.parse [] [] source |> Markup.to_yojson |> U.to_list in
    check_eq ~msg:source (U.member "type" (List.hd nodes)) (`String "video");
    check_eq (U.member "embedURL" (List.hd nodes))
      (`String "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?playsinline=1")
  ) ["https://youtu.be/dQw4w9WgXcQ"; "https://www.youtube.com/watch?v=dQw4w9WgXcQ"];
  let nodes = Markup.parse [] [] "[Watch this](https://youtu.be/dQw4w9WgXcQ)" |> Markup.to_yojson |> U.to_list in
  check_eq ~msg:"Explicitly labelled links stay links" (U.member "type" (List.hd nodes)) (`String "link")

let cases = [
  case "bare YouTube links render as players" bare_youtube_links_render_as_players;
  case "timestamp zero overrides the source start time" timestamp_zero_overrides_the_source_start_time;
  case "shared video requests canonicalize supported sources" shared_video_requests_canonicalize_supported_sources;
  case "media projection rejects unsafe URLs and spoofed YouTube hosts" media_projection_rejects_unsafe_urls_and_spoofed_youtube_hosts;
  case "inline timestamps are projected with their player" inline_timestamps_are_projected_with_their_player;
]
