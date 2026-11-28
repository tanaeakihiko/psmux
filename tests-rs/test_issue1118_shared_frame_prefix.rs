// Issue #1118 on the shared server: the frame there is built by
// shared::frame::build_frame, a copy of run_server's, and its prefix and
// prefix2 still went in unescaped after 45c6763d fixed run_server's two
// builders. `set -g prefix C-\` then made every frame of a shared server
// `"prefix":"C-\"`, which is no JSON: the client drew nothing and the prefix
// never matched. These build the shared frame and parse it as the client does.

use super::{build_frame, FrameCache};
use crossterm::event::{KeyCode, KeyModifiers};

fn frame_json(app: &mut crate::types::AppState) -> serde_json::Value {
    let mut cache = FrameCache::new();
    let mut meta_dirty = true;
    build_frame(app, &mut cache, &mut meta_dirty).expect("build_frame");
    serde_json::from_str(&cache.combined_buf)
        .unwrap_or_else(|e| panic!("the shared frame is no JSON: {e}: {}", cache.combined_buf))
}

#[test]
fn shared_frame_parses_with_ctrl_backslash_prefix() {
    let mut app = crate::server::test_issue431_m4_blobs::app_with_sixel_pane();
    app.prefix_key = Some((KeyCode::Char('\\'), KeyModifiers::CONTROL));
    let frame = frame_json(&mut app);
    assert_eq!(frame["prefix"], "C-\\");
    assert_eq!(frame["prefix2"], "");
}

#[test]
fn shared_frame_parses_with_ctrl_backslash_prefix2() {
    let mut app = crate::server::test_issue431_m4_blobs::app_with_sixel_pane();
    app.prefix_key = Some((KeyCode::Char('b'), KeyModifiers::CONTROL));
    app.prefix2_key = Some((KeyCode::Char('\\'), KeyModifiers::CONTROL));
    let frame = frame_json(&mut app);
    assert_eq!(frame["prefix"], "C-b");
    assert_eq!(frame["prefix2"], "C-\\");
}

#[test]
fn shared_frame_parses_with_double_quote_prefix() {
    let mut app = crate::server::test_issue431_m4_blobs::app_with_sixel_pane();
    app.prefix_key = Some((KeyCode::Char('"'), KeyModifiers::NONE));
    let frame = frame_json(&mut app);
    assert_eq!(frame["prefix"], "\"");
}
