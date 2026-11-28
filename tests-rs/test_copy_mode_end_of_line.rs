// Copy mode end-of-line went to the last column of the pane whatever the line
// held. tmux (window_copy_cursor_end_of_line, grid_reader_cursor_end_of_line)
// follows a wrapped line to its last row and stops at the end of the text,
// trailing blanks left out; vi keys stay on the last character (tmux 3.7 and
// later, window_copy_cursor_limit) and emacs keys go one past it. start-of-line
// and back-to-indentation go back to the first row of a wrapped line. Every
// position here is what tmux 3.8 reports for the same lines.
//
// These tests drive the real copy mode over a pane tree with a stub PTY (no
// psmux server). Registered from src/copy_mode.rs.

use super::*;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use crate::types::Node;

const ROWS: u16 = 10;
const COLS: u16 = 40;
const SCROLLBACK: usize = 200;

const CJK: &str = "\u{65e5}\u{672c}\u{8a9e}";

fn make_pane(id: usize, rows: u16, cols: u16) -> crate::types::Pane {
    let (master, writer) = crate::util::stub_pane_pty(portable_pty::PtySize {
        rows,
        cols,
        pixel_width: 0,
        pixel_height: 0,
    });
    let child = crate::util::StubChild::exited();
    let term = Arc::new(Mutex::new(vt100::Parser::new(rows, cols, SCROLLBACK)));
    let epoch = Instant::now() - Duration::from_secs(2);
    crate::types::Pane {
        master,
        writer,
        child,
        term,
        last_rows: rows,
        last_cols: cols,
        id,
        title: format!("pane{id}"),
        title_locked: false,
        child_pid: None,
        data_version: Arc::new(AtomicU64::new(0)),
        last_title_check: epoch,
        last_infer_title: epoch,
        dead: false,
        dead_info: None,
        last_text_input: None,
        last_special_key: None,
        vt_bridge_cache: None,
        vti_mode_cache: None,
        mouse_input_cache: None, win32_input_latched: false, input_off: false,
        scroll_fg_cache: None,
        mouse_proto_owner: None,
        wheel_auth: None,
        cursor_shape: Arc::new(AtomicU8::new(0)),
        bell_pending: Arc::new(AtomicBool::new(false)),
        cpr_pending: Arc::new(AtomicBool::new(false)),
        color_query_pending: Arc::new(std::sync::atomic::AtomicU32::new(0)),
        copy_state: None, live_term: None,
        pane_style: None,
        pane_options: Default::default(),
        squelch_until: None,
        output_ring: Arc::new(Mutex::new(std::collections::VecDeque::new())),
        spawned_at: None,
        start_command: String::new(),
        cwd_hint: None,
    }
}

fn make_window(id: usize) -> crate::types::Window {
    crate::types::Window {
        root: Node::Split { kind: crate::types::LayoutKind::Horizontal, sizes: vec![], children: vec![] },
        active_path: vec![],
        name: "w".to_string(),
        id,
        area: ratatui::layout::Rect::new(0, 0, COLS, ROWS),
        window_size: None,
        window_options: Default::default(),
        activity_flag: false,
        bell_flag: false,
        silence_flag: false,
        last_output_time: Instant::now(),
        last_seen_version: 0,
        manual_rename: false,
        layout_index: 0,
        pane_mru: vec![],
        zoom_saved: None,
        linked_from: None,
        floating: Vec::new(),
        floating_focus: None,
    }
}

/// One window, one pane that has printed `output`, in copy mode with `keys`.
fn copy_app(output: &str, keys: &str) -> AppState {
    let mut app = AppState::new("copy_eol".to_string());
    app.window_base_index = 0;
    app.pane_base_index = 0;
    app.mode_keys = keys.to_string();
    let pane = make_pane(0, ROWS, COLS);
    pane.term.lock().expect("parser lock").process(output.as_bytes());
    let mut win = make_window(0);
    win.root = Node::Leaf(pane);
    app.windows.push(win);
    app.active_idx = 0;
    app.last_window_area = ratatui::layout::Rect::new(0, 0, COLS, ROWS);
    enter_copy_mode(&mut app);
    app
}

/// Rows 0 to 7: plain, trailing blanks, empty, indented, a 50 cell line that
/// wraps onto row 5, a CJK line ending in "ab", and one ending on a wide
/// character.
fn lines(keys: &str) -> AppState {
    let long = "0".repeat(50);
    copy_app(&format!("abcdefghi\r\ntrail   \r\n\r\n  indented x\r\n{long}\r\n{CJK}ab\r\n{CJK}\r\n"), keys)
}

fn eol_from(app: &mut AppState, row: u16, col: u16) -> (u16, u16) {
    app.copy_pos = Some((row, col));
    move_to_line_end(app);
    app.copy_pos.expect("copy_pos")
}

#[test]
fn vi_end_of_line_stops_on_the_last_character() {
    let mut app = lines("vi");
    assert_eq!(eol_from(&mut app, 0, 0), (0, 8));
    assert_eq!(eol_from(&mut app, 1, 0), (1, 4), "trailing blanks are not part of the line");
    assert_eq!(eol_from(&mut app, 2, 0), (2, 0), "an empty line stays on column 0");
    assert_eq!(eol_from(&mut app, 3, 5), (3, 11));
    assert_eq!(eol_from(&mut app, 4, 0), (5, 9), "a wrapped line ends on its last row");
    assert_eq!(eol_from(&mut app, 6, 0), (6, 7), "a line ending in 'ab' after CJK");
    assert_eq!(eol_from(&mut app, 7, 0), (7, 4), "a last wide character keeps its first cell");
}

#[test]
fn emacs_end_of_line_goes_one_past_the_last_character() {
    let mut app = lines("emacs");
    assert_eq!(eol_from(&mut app, 0, 0), (0, 9));
    assert_eq!(eol_from(&mut app, 1, 0), (1, 5));
    assert_eq!(eol_from(&mut app, 2, 0), (2, 0));
    assert_eq!(eol_from(&mut app, 3, 0), (3, 12));
    assert_eq!(eol_from(&mut app, 4, 0), (5, 10));
    assert_eq!(eol_from(&mut app, 6, 0), (6, 8));
    assert_eq!(eol_from(&mut app, 7, 0), (7, 6));
}

#[test]
fn end_of_line_follows_a_wrapped_line_to_its_last_row() {
    // The 50 cell line fills row 1 and 10 cells of row 2.
    let long = "0".repeat(50);
    for (keys, want) in [("vi", (2, 9)), ("emacs", (2, 10))] {
        let mut app = copy_app(&format!("abc\r\n{long}\r\nnext\r\n"), keys);
        assert_eq!(eol_from(&mut app, 1, 0), want, "{keys} from the first row");
        assert_eq!(eol_from(&mut app, 2, 3), want, "{keys} from the second row");
        assert_eq!(eol_from(&mut app, 3, 0), (3, if keys == "vi" { 3 } else { 4 }), "{keys} on the line after");
    }
}

#[test]
fn the_lines_fixture_wraps_where_the_tests_expect() {
    let app = lines("vi");
    let win = &app.windows[app.active_idx];
    let pane = active_pane(&win.root, &win.active_path).expect("pane");
    let parser = pane.term.lock().expect("parser lock");
    assert!(parser.screen().row_wrapped(4));
    assert!(!parser.screen().row_wrapped(3));
}

#[test]
fn end_of_line_repeated_stays_put() {
    let mut app = lines("vi");
    app.copy_pos = Some((0, 0));
    for _ in 0..3 {
        move_to_line_end(&mut app);
    }
    assert_eq!(app.copy_pos, Some((0, 8)));
}

#[test]
fn end_of_line_in_a_rectangle_selection_goes_to_the_last_column() {
    let mut app = lines("vi");
    app.copy_pos = Some((0, 0));
    app.copy_anchor = Some((0, 0));
    app.copy_selection_mode = crate::types::SelectionMode::Rect;
    move_to_line_end(&mut app);
    assert_eq!(app.copy_pos, Some((0, COLS - 1)));
    app.copy_selection_mode = crate::types::SelectionMode::Char;
    move_to_line_end(&mut app);
    assert_eq!(app.copy_pos, Some((0, 8)));
}

#[test]
fn start_of_line_and_back_to_indentation_go_to_the_first_row_of_a_wrapped_line() {
    let long = format!("  {}", "x".repeat(60));
    let mut app = copy_app(&format!("top\r\n{long}\r\n"), "vi");
    app.copy_pos = Some((2, 7));
    move_to_line_start(&mut app);
    assert_eq!(app.copy_pos, Some((1, 0)));
    app.copy_pos = Some((2, 7));
    move_to_first_nonblank(&mut app);
    assert_eq!(app.copy_pos, Some((1, 2)));
    // A row that is not a continuation keeps its own row.
    app.copy_pos = Some((0, 2));
    move_to_line_start(&mut app);
    assert_eq!(app.copy_pos, Some((0, 0)));
}

#[test]
fn back_to_indentation_on_an_empty_line_stays_put() {
    let mut app = lines("vi");
    app.copy_pos = Some((2, 0));
    move_to_first_nonblank(&mut app);
    assert_eq!(app.copy_pos, Some((2, 0)));
    app.copy_pos = Some((3, 9));
    move_to_first_nonblank(&mut app);
    assert_eq!(app.copy_pos, Some((3, 2)));
}

#[test]
fn end_of_line_scrolls_down_to_the_rest_of_a_wrapped_line() {
    // A screen of short lines, a 50 cell line, then enough short lines to
    // push it into the history.
    let mut out = String::new();
    for i in 0..ROWS {
        out.push_str(&format!("above {i}\r\n"));
    }
    out.push_str(&format!("{}\r\n", "y".repeat(50)));
    for i in 0..20 {
        out.push_str(&format!("filler {i}\r\n"));
    }
    let mut app = copy_app(&out, "vi");
    // Scroll back until the long line's first row is the last visible row.
    let sb = {
        let win = &app.windows[app.active_idx];
        let pane = active_pane(&win.root, &win.active_path).expect("pane");
        let mut parser = pane.term.lock().expect("parser lock");
        let mut found = None;
        for sb in 0..=SCROLLBACK {
            parser.screen_mut().set_scrollback(sb);
            let s = parser.screen();
            if s.cell(ROWS - 1, 0).is_some_and(|c| c.contents() == "y") && s.row_wrapped(ROWS - 1) {
                found = Some(s.scrollback());
                break;
            }
        }
        found.expect("the long line can sit on the last row")
    };
    app.copy_scroll_offset = sb;
    assert_eq!(eol_from(&mut app, ROWS - 1, 0), (ROWS - 1, 9));
    assert_eq!(app.copy_scroll_offset, sb - 1, "the view moved down one row");
}

// The copy itself is checked through selection_text: yank_selection also
// writes the system clipboard, which a unit test must not touch.
fn one_row_selection_text(p: &mut vt100::Parser, row: u16, c0: u16, c1: u16, cols: u16) -> String {
    let (r, mode) = (row as i64, crate::types::SelectionMode::Char);
    selection_text(p, ROWS, cols, (r, c0), (r, c1), mode, false, 0)
}

#[test]
fn a_one_row_selection_past_the_text_copies_only_the_text() {
    let mut p = vt100::Parser::new(ROWS, COLS, 0);
    p.process(format!("trail   \r\na   b\r\n{CJK}x\r\n").as_bytes());
    let s = &mut p;
    assert_eq!(one_row_selection_text(s, 0, 0, 7, COLS), "trail");
    assert_eq!(one_row_selection_text(s, 0, 0, COLS - 1, COLS), "trail");
    assert_eq!(one_row_selection_text(s, 0, 2, 3, COLS), "ai");
    // Blanks between words inside the selection stay.
    assert_eq!(one_row_selection_text(s, 1, 0, 2, COLS), "a  ");
    assert_eq!(one_row_selection_text(s, 1, 0, 9, COLS), "a   b");
    // A selection wholly past the text copies nothing.
    assert_eq!(one_row_selection_text(s, 0, 20, 30, COLS), "");
    assert_eq!(one_row_selection_text(s, 2, 0, 9, COLS), format!("{CJK}x"));
}

// A program that writes a full row and then CR LF leaves a row that does not
// wrap; the inbox console host of Windows 10 hands psmux every full row that
// way. With emacs keys tmux 3.8 then puts the cursor one past the row, at
// column sx (window_copy_cursor_limit gives the line's length,
// window-copy.c:6315), and a selection to there takes the whole row. psmux
// held the cursor on the last column, so the copy lost the last character.
// tmux 3.8 gives the same positions on a 20 column pane.

/// Row 0 full of 'a', row 1 "one two " and a full row of 'z', row 2 short,
/// row 3 ending on a wide character in the last two columns, each ended
/// with CR LF.
fn full_rows(keys: &str) -> AppState {
    let n = COLS as usize;
    copy_app(
        &format!("{}\r\none two {}\r\nshort\r\n{}\u{4e16}\r\n", "a".repeat(n), "z".repeat(n - 8), "a".repeat(n - 2)),
        keys,
    )
}

#[test]
fn the_full_rows_fixture_does_not_wrap() {
    let app = full_rows("emacs");
    let p = match &app.windows[0].root { Node::Leaf(p) => p, _ => unreachable!() };
    let parser = p.term.lock().expect("parser lock");
    for r in 0..4 {
        assert!(!parser.screen().row_wrapped(r), "row {r} must not wrap");
    }
}

#[test]
fn emacs_end_of_line_goes_one_past_a_full_row() {
    let mut app = full_rows("emacs");
    assert_eq!(eol_from(&mut app, 0, 0), (0, COLS));
    assert_eq!(eol_from(&mut app, 3, 0), (3, COLS), "a last wide character ends the row too");
    assert_eq!(eol_from(&mut app, 2, 0), (2, 5), "a short row as before");
    let mut app = full_rows("vi");
    assert_eq!(eol_from(&mut app, 0, 0), (0, COLS - 1), "vi keys stay on the last character");
    assert_eq!(eol_from(&mut app, 3, 0), (3, COLS - 2));
}

#[test]
fn left_from_one_past_a_full_row_is_its_last_column() {
    let mut app = full_rows("emacs");
    eol_from(&mut app, 0, 0);
    move_copy_cursor(&mut app, -1, 0);
    assert_eq!(app.copy_pos, Some((0, COLS - 1)));
    // Right goes on to the start of the next line, as tmux's does.
    eol_from(&mut app, 0, 0);
    move_copy_cursor(&mut app, 1, 0);
    assert_eq!(app.copy_pos, Some((1, 0)));
}

#[test]
fn emacs_next_word_end_goes_one_past_a_full_row() {
    for (keys, want) in [("emacs", [(1, 7), (1, COLS)]), ("vi", [(1, 6), (1, COLS - 1)])] {
        let mut app = full_rows(keys);
        app.copy_pos = Some((1, 4));
        move_word_end(&mut app);
        assert_eq!(app.copy_pos, Some(want[0]), "{keys} to the end of 'two'");
        move_word_end(&mut app);
        assert_eq!(app.copy_pos, Some(want[1]), "{keys} to the end of the row");
    }
}

#[test]
fn an_emacs_selection_to_the_end_of_a_full_row_copies_all_of_it() {
    let mut app = full_rows("emacs");
    let (_, end) = eol_from(&mut app, 0, 0);
    let p = match &mut app.windows[0].root { Node::Leaf(p) => p, _ => unreachable!() };
    let mut parser = p.term.lock().expect("parser lock");
    let mode = crate::types::SelectionMode::Char;
    let text = selection_text(&mut parser, ROWS, COLS, (0, 0), (0, end), mode, true, 0);
    assert_eq!(text, "a".repeat(COLS as usize));
}

// Every copy cursor move is held inside window_copy_cursor_limit in tmux
// (window_copy_update_cursor), and up and down remember the column a run of
// vertical moves started from and whether it was at the end of its line
// (lastcx, lastsx). psmux kept the column through up, down and the page
// moves whatever the new line held, did not limit history-bottom, and its
// cursor-right and cursor-left stopped at the pane edge instead of going on
// to the next or previous line. Each case below starts as the E2E suite
// does (top-line, cursor-down to the row, start-of-line, end-of-line), runs
// the moves, and expects the position tmux 3.8 reports for the same rows on
// a 20 by 8 pane with status off: row 0 full of 'a', row 1 "one two " and
// twelve 'z', row 2 "short", row 3 eighteen 'a' and a wide character, each
// ended with CR LF.

const MOVES: &[(&str, u16, &str, (u16, u16))] = &[
    ("emacs", 0, "cursor-down", (1, 20)),
    ("emacs", 0, "cursor-down cursor-down", (2, 5)),
    ("emacs", 0, "cursor-down cursor-down cursor-down", (3, 20)),
    ("emacs", 0, "cursor-down cursor-down cursor-down cursor-down", (4, 0)),
    ("emacs", 3, "cursor-down", (4, 0)),
    ("emacs", 1, "cursor-up", (0, 0)),
    ("emacs", 2, "cursor-up", (1, 0)),
    ("emacs", 4, "cursor-up", (3, 0)),
    ("emacs", 0, "halfpage-down", (4, 0)),
    ("emacs", 0, "page-down", (6, 0)),
    ("emacs", 3, "halfpage-up", (0, 0)),
    ("emacs", 0, "cursor-right", (1, 0)),
    ("emacs", 3, "cursor-right", (4, 0)),
    ("emacs", 2, "cursor-right", (3, 0)),
    ("emacs", 0, "cursor-right cursor-right", (1, 1)),
    ("emacs", 0, "history-bottom", (7, 0)),
    ("emacs", 0, "cursor-left cursor-down cursor-down cursor-down", (3, 19)),
    ("emacs", 2, "cursor-up cursor-up", (0, 0)),
    ("emacs", 0, "begin-selection cursor-down cursor-down", (2, 5)),
    ("emacs", 0, "rectangle-toggle begin-selection cursor-down cursor-down", (2, 20)),
    ("emacs", 1, "start-of-line cursor-left", (0, 20)),
    ("emacs", 3, "start-of-line cursor-left", (2, 5)),
    ("emacs", 4, "start-of-line cursor-left", (3, 20)),
    ("emacs", 0, "start-of-line cursor-left", (0, 0)),
    ("emacs", 3, "cursor-left cursor-left cursor-right", (3, 18)),
    ("emacs", 3, "cursor-left cursor-right", (3, 20)),
    ("emacs", 7, "cursor-right", (7, 0)),
    ("emacs", 6, "cursor-down", (7, 0)),
    ("emacs", 0, "cursor-down cursor-up", (0, 20)),
    ("emacs", 2, "cursor-down cursor-up", (2, 0)),
    ("emacs", 0, "cursor-left cursor-left cursor-down cursor-down cursor-down cursor-up", (2, 5)),
    ("emacs", 0, "halfpage-down halfpage-up", (0, 20)),
    ("emacs", 0, "scroll-down", (0, 20)),
    ("emacs", 0, "rectangle-toggle cursor-down cursor-down", (2, 5)),
    ("emacs", 0, "rectangle-toggle cursor-right", (1, 0)),
    ("emacs", 0, "begin-selection rectangle-toggle cursor-right cursor-right", (1, 1)),
    ("vi", 0, "cursor-down", (1, 19)),
    ("vi", 0, "cursor-down cursor-down", (2, 4)),
    ("vi", 0, "cursor-down cursor-down cursor-down", (3, 4)),
    ("vi", 0, "cursor-down cursor-down cursor-down cursor-down", (4, 0)),
    ("vi", 3, "cursor-down", (4, 0)),
    ("vi", 1, "cursor-up", (0, 19)),
    ("vi", 2, "cursor-up", (1, 4)),
    ("vi", 4, "cursor-up", (3, 0)),
    ("vi", 0, "halfpage-down", (4, 0)),
    ("vi", 0, "page-down", (6, 0)),
    ("vi", 3, "halfpage-up", (0, 18)),
    ("vi", 0, "cursor-right", (1, 0)),
    ("vi", 3, "cursor-right", (4, 0)),
    ("vi", 2, "cursor-right", (3, 0)),
    ("vi", 0, "cursor-right cursor-right", (1, 1)),
    ("vi", 0, "history-bottom", (7, 0)),
    ("vi", 0, "cursor-left cursor-down cursor-down cursor-down", (3, 4)),
    ("vi", 2, "cursor-up cursor-up", (0, 4)),
    ("vi", 0, "begin-selection cursor-down cursor-down", (2, 4)),
    ("vi", 0, "rectangle-toggle begin-selection cursor-down cursor-down", (2, 19)),
    ("vi", 1, "start-of-line cursor-left", (0, 19)),
    ("vi", 3, "start-of-line cursor-left", (2, 4)),
    ("vi", 4, "start-of-line cursor-left", (3, 18)),
    ("vi", 0, "start-of-line cursor-left", (0, 0)),
    ("vi", 3, "cursor-left cursor-left cursor-right", (3, 17)),
    ("vi", 3, "cursor-left cursor-right", (3, 18)),
    ("vi", 7, "cursor-right", (7, 0)),
    ("vi", 6, "cursor-down", (7, 0)),
    ("vi", 0, "cursor-down cursor-up", (0, 19)),
    ("vi", 2, "cursor-down cursor-up", (2, 4)),
    ("vi", 0, "cursor-left cursor-left cursor-down cursor-down cursor-down cursor-up", (2, 4)),
    ("vi", 0, "halfpage-down halfpage-up", (0, 19)),
    ("vi", 0, "scroll-down", (0, 19)),
    ("vi", 0, "rectangle-toggle cursor-down cursor-down", (2, 5)),
    ("vi", 0, "rectangle-toggle cursor-right", (1, 0)),
    ("vi", 0, "begin-selection rectangle-toggle cursor-right cursor-right", (1, 0)),
];

fn small_rows_app(keys: &str) -> AppState {
    let mut app = AppState::new("copy_moves".to_string());
    app.window_base_index = 0;
    app.pane_base_index = 0;
    app.mode_keys = keys.to_string();
    let pane = make_pane(0, 8, 20);
    pane.term.lock().expect("parser lock").process(
        format!("{}\r\none two {}\r\nshort\r\n{}\u{4e16}\r\n", "a".repeat(20), "z".repeat(12), "a".repeat(18)).as_bytes(),
    );
    let mut win = make_window(0);
    win.root = Node::Leaf(pane);
    app.windows.push(win);
    app.active_idx = 0;
    app.last_window_area = ratatui::layout::Rect::new(0, 0, 20, 8);
    enter_copy_mode(&mut app);
    app
}

fn run_move(app: &mut AppState, cmd: &str) {
    match cmd {
        "cursor-up" => move_copy_cursor(app, 0, -1),
        "cursor-down" => move_copy_cursor(app, 0, 1),
        "cursor-left" => move_copy_cursor(app, -1, 0),
        "cursor-right" => move_copy_cursor(app, 1, 0),
        "start-of-line" => move_to_line_start(app),
        "end-of-line" => move_to_line_end(app),
        "halfpage-up" => page_scroll(app, true, true),
        "halfpage-down" => page_scroll(app, false, true),
        "page-down" => page_scroll(app, false, false),
        "scroll-down" => scroll_copy_down(app, 1),
        "history-bottom" => scroll_to_bottom(app),
        "begin-selection" => begin_selection(app),
        "rectangle-toggle" => toggle_rectangle(app),
        other => panic!("no move {other}"),
    }
}

#[test]
fn every_move_lands_where_tmux_puts_it() {
    let mut wrong = Vec::new();
    for &(keys, row, cmds, want) in MOVES {
        let mut app = small_rows_app(keys);
        move_to_screen_top(&mut app);
        for _ in 0..row { run_move(&mut app, "cursor-down"); }
        run_move(&mut app, "start-of-line");
        run_move(&mut app, "end-of-line");
        for c in cmds.split(' ') { run_move(&mut app, c); }
        let got = app.copy_pos.expect("copy_pos");
        if got != want {
            wrong.push(format!("{keys} row {row} [{cmds}]: got x={} y={}, tmux x={} y={}", got.1, got.0, want.1, want.0));
        }
    }
    assert!(wrong.is_empty(), "{} of {} moves differ from tmux 3.8:\n{}", wrong.len(), MOVES.len(), wrong.join("\n"));
}

// scroll-up and scroll-down (the wheel runs them too), tmux's
// window_copy_cmd_scroll_up and _down: with a selection only the view moves,
// at either end of the history nothing changes, and otherwise each step is a
// vertical move in scroll_only mode, with the column settled as for cursor-up
// and cursor-down. The pane is 80 by 24 with 200
// numbered lines and "ab"; each case enters copy mode, runs cursor-up five
// times, then the moves, and expects tmux 3.8's copy_cursor_x,
// copy_cursor_y and scroll_position.
const SCROLLS: &[(&str, &str, (u16, u16, usize))] = &[
    ("vi", "begin-selection scroll-up scroll-up scroll-up", (1, 18, 3)),
    ("vi", "scroll-down", (1, 18, 0)),
    ("emacs", "scroll-up scroll-up scroll-up", (7, 18, 3)),
    ("emacs", "scroll-up scroll-up scroll-up scroll-up scroll-up scroll-up scroll-up scroll-up scroll-up scroll-up", (7, 18, 10)),
    ("emacs", "begin-selection scroll-up scroll-up scroll-up", (7, 18, 3)),
    ("emacs", "scroll-up scroll-up scroll-down", (7, 18, 1)),
    ("emacs", "scroll-down", (7, 18, 0)),
    ("emacs", "cursor-up cursor-up scroll-up scroll-down", (7, 16, 0)),
];

#[test]
fn scroll_up_and_down_move_the_cursor_as_tmux_does() {
    let mut wrong = Vec::new();
    for &(keys, cmds, want) in SCROLLS {
        let mut app = AppState::new("copy_scrolls".to_string());
        app.window_base_index = 0;
        app.pane_base_index = 0;
        app.mode_keys = keys.to_string();
        let pane = make_pane(0, 24, 80);
        {
            let mut parser = pane.term.lock().expect("parser lock");
            for i in 1..=200 { parser.process(format!("LINE{i:03}\r\n").as_bytes()); }
            parser.process(b"ab\r\n");
        }
        let mut win = make_window(0);
        win.root = Node::Leaf(pane);
        app.windows.push(win);
        app.active_idx = 0;
        app.last_window_area = ratatui::layout::Rect::new(0, 0, 80, 24);
        enter_copy_mode(&mut app);
        for _ in 0..5 { run_move(&mut app, "cursor-up"); }
        for c in cmds.split(' ') {
            match c {
                "scroll-up" => scroll_copy_up(&mut app, 1),
                other => run_move(&mut app, other),
            }
        }
        let (r, c) = app.copy_pos.expect("copy_pos");
        let got = (c, r, app.copy_scroll_offset);
        if got != want {
            wrong.push(format!("{keys} [{cmds}]: got {got:?}, tmux {want:?}"));
        }
    }
    assert!(wrong.is_empty(), "{} of {} differ from tmux 3.8:\n{}", wrong.len(), SCROLLS.len(), wrong.join("\n"));
}
