// Issue #735: psmux asserts a cursor shape on every attach and defaults to
// `bar`, so attaching replaces the cursor shape the terminal was configured
// with. tmux defaults `cursor-style` to `default` and never asserts a shape of
// its own.
//
// tmux, tag 3.7c `e476c123`:
//   options-table.c:62-65    the choice list, `default` first
//   options-table.c:336-341  `cursor-style`, `.default_num = 0`
//   tty.c:332-386            `tty_start_tty` sends no DECSCUSR
//   tty.c:816-825            `tty_update_cursor` sends the reset for
//                            SCREEN_CURSOR_DEFAULT only when its own last
//                            style was not SCREEN_CURSOR_DEFAULT
//
// `SCREEN_CURSOR_DEFAULT` (tmux.h) is a third state beside block, underline
// and bar: "no opinion". psmux spells it 0 and now keeps it, instead of
// resolving it to a shape on the way out.
//
// These tests pin the two halves that are testable in process: what the
// configuration resolves to, and what the attach path writes for it. The
// client's per frame latch is the same rule one level up, and its starting
// value is the comment at `client.rs` `last_cursor_style`.

/// The cursor options are read from the process environment, not from
/// `AppState`, so a test that wants to know what psmux falls back to has to
/// remove them first and put them back afterwards. Same guard, same shared
/// lock as `test_option_default_parity.rs`, which explains at length why a
/// test that reads an environment variable it never set is measuring the
/// developer's shell.
struct CursorEnv {
    _lock: std::sync::MutexGuard<'static, ()>,
    saved: Vec<(&'static str, Option<String>)>,
}

impl CursorEnv {
    fn take() -> Self {
        let lock = crate::util::lock_test_env();
        let saved = ["PSMUX_CURSOR_STYLE", "PSMUX_CURSOR_BLINK"]
            .into_iter()
            .map(|name| {
                let previous = std::env::var(name).ok();
                std::env::remove_var(name);
                (name, previous)
            })
            .collect();
        Self { _lock: lock, saved }
    }

    fn set(&self, style: Option<&str>, blink: Option<&str>) {
        match style {
            Some(v) => std::env::set_var("PSMUX_CURSOR_STYLE", v),
            None => std::env::remove_var("PSMUX_CURSOR_STYLE"),
        }
        match blink {
            Some(v) => std::env::set_var("PSMUX_CURSOR_BLINK", v),
            None => std::env::remove_var("PSMUX_CURSOR_BLINK"),
        }
    }
}

impl Drop for CursorEnv {
    fn drop(&mut self) {
        for (name, previous) in &self.saved {
            match previous {
                Some(value) => std::env::set_var(name, value),
                None => std::env::remove_var(name),
            }
        }
    }
}

fn attach_bytes() -> Vec<u8> {
    let mut sink: Vec<u8> = Vec::new();
    crate::rendering::apply_cursor_style(&mut sink).expect("writing to a Vec cannot fail");
    sink
}

#[test]
fn nothing_configured_resolves_to_no_opinion() {
    let env = CursorEnv::take();
    env.set(None, None);
    assert_eq!(
        crate::rendering::configured_cursor_code(),
        0,
        "with nothing set, psmux must have no opinion about the cursor shape"
    );
}

#[test]
fn the_three_shapes_resolve_to_their_decscusr_codes() {
    let env = CursorEnv::take();
    // DECSCUSR: 1/2 block, 3/4 underline, 5/6 bar, odd blinking, even steady.
    for (style, blink, code) in [
        ("block", "1", 1u8),
        ("block", "0", 2),
        ("underline", "1", 3),
        ("underline", "0", 4),
        ("bar", "1", 5),
        ("bar", "0", 6),
        // `beam` is an accepted spelling of `bar`.
        ("beam", "1", 5),
    ] {
        env.set(Some(style), Some(blink));
        assert_eq!(
            crate::rendering::configured_cursor_code(),
            code,
            "style {} with blink {}",
            style,
            blink
        );
    }
}

/// tmux has no `cursor-blink`: its `cursor-style` carries the blink in the
/// value (`blinking-block`, `blinking-underline`, `blinking-bar`,
/// options-table.c:62-65 and tmux.1). A config written for tmux has to name a
/// shape psmux understands, so the prefix is accepted and names the shape.
#[test]
fn the_tmux_spellings_name_the_same_three_shapes() {
    let env = CursorEnv::take();
    for (style, plain, code) in [
        ("blinking-block", "block", 1u8),
        ("blinking-underline", "underline", 3),
        ("blinking-bar", "bar", 5),
    ] {
        env.set(Some(style), Some("1"));
        assert_eq!(crate::rendering::configured_cursor_code(), code, "{}", style);
        env.set(Some(plain), Some("1"));
        assert_eq!(crate::rendering::configured_cursor_code(), code, "{}", plain);
    }
}

/// A value that names the blink blinks on its own. `cursor-blink` is a psmux
/// option a tmux config does not carry, so `cursor-style blinking-bar` by
/// itself has to mean a blinking bar, not whatever that option defaults to.
#[test]
fn a_value_that_names_the_blink_blinks_with_the_option_unset() {
    let env = CursorEnv::take();
    for (style, code) in [
        ("blinking-block", 1u8),
        ("blinking-underline", 3),
        ("blinking-bar", 5),
    ] {
        env.set(Some(style), None);
        assert_eq!(
            crate::rendering::configured_cursor_code(),
            code,
            "{} with cursor-blink unset must blink",
            style
        );
    }
}

/// Set, `cursor-blink` decides: it is the setting that speaks about nothing
/// but blinking, so it wins over the blink in the value's name.
#[test]
fn the_blink_option_wins_over_the_blink_in_the_value() {
    let env = CursorEnv::take();
    for (style, steady) in [
        ("blinking-block", 2u8),
        ("blinking-underline", 4),
        ("blinking-bar", 6),
    ] {
        env.set(Some(style), Some("0"));
        assert_eq!(
            crate::rendering::configured_cursor_code(),
            steady,
            "{} with cursor-blink off must not blink",
            style
        );
    }
}

/// INCOMPATIBLE with psmux before this change, and the reason it is here:
/// `cursor-blink` defaulted to `on`, so a bare `block` blinked. tmux means the
/// STEADY block by that word (DECSCUSR 2) and spells the blinking one
/// `blinking-block`, so the default is now `off` and the three bare shapes
/// mean what tmux means. A config that wants the old cursor adds
/// `set -g cursor-blink on`.
#[test]
fn a_bare_shape_is_steady_with_the_option_unset() {
    let env = CursorEnv::take();
    for (style, steady) in [("block", 2u8), ("underline", 4), ("bar", 6)] {
        env.set(Some(style), None);
        assert_eq!(
            crate::rendering::configured_cursor_code(),
            steady,
            "a bare {} must be the steady shape tmux means by the word",
            style
        );
    }
}

/// The option takes words, the variable it is stored in takes digits, and the
/// two have to agree. `set -g cursor-blink off` writes `0`, but a shell can
/// export the word itself, and `PSMUX_CURSOR_BLINK=off` must not come out
/// meaning blinking just because it is not the literal `0`.
#[test]
fn the_variable_is_read_the_way_the_option_value_is_parsed() {
    let env = CursorEnv::take();
    for yes in ["1", "on", "true"] {
        env.set(Some("bar"), Some(yes));
        assert_eq!(crate::rendering::configured_cursor_code(), 5, "blink [{}]", yes);
    }
    for no in ["0", "off", "false", "no", ""] {
        env.set(Some("bar"), Some(no));
        assert_eq!(crate::rendering::configured_cursor_code(), 6, "blink [{}]", no);
    }
    // Unset is its own answer, not a value, which is what lets a bare shape
    // be steady while `blinking-bar` blinks.
    env.set(Some("bar"), None);
    assert_eq!(crate::rendering::cursor_blink_option(), None);
    env.set(Some("bar"), Some("0"));
    assert_eq!(crate::rendering::cursor_blink_option(), Some(false));
    env.set(Some("bar"), Some("on"));
    assert_eq!(crate::rendering::cursor_blink_option(), Some(true));
}

/// The fallback for an unset `cursor-blink` is the option's own default, so
/// the two must not drift apart.
#[test]
fn the_blink_fallback_is_the_catalog_default() {
    let catalog = crate::server::option_catalog::default_for("cursor-blink")
        .expect("cursor-blink must be in the catalog");
    assert_eq!(
        crate::rendering::CURSOR_BLINK_DEFAULT_BLINKS,
        catalog == "on",
        "the catalog says cursor-blink defaults to [{}]",
        catalog
    );
}

#[test]
fn default_and_anything_unrecognised_resolve_to_no_opinion() {
    let env = CursorEnv::take();
    for style in ["default", "wobble", "", "blinking-wobble"] {
        // The blink value must not rescue a style that names no shape: there
        // is nothing to blink.
        for blink in ["1", "0"] {
            env.set(Some(style), Some(blink));
            assert_eq!(
                crate::rendering::configured_cursor_code(),
                0,
                "style {} with blink {}",
                style,
                blink
            );
        }
    }
}

#[test]
fn the_attach_writes_nothing_when_nothing_asked_for_a_shape() {
    let env = CursorEnv::take();
    env.set(None, None);
    assert!(
        attach_bytes().is_empty(),
        "attaching must not touch the cursor the terminal was configured with"
    );
    env.set(Some("default"), Some("1"));
    assert!(
        attach_bytes().is_empty(),
        "`cursor-style default` is the same state spelled out"
    );
}

#[test]
fn the_attach_writes_the_shape_that_was_asked_for() {
    let env = CursorEnv::take();
    env.set(Some("block"), Some("0"));
    assert_eq!(attach_bytes(), b"\x1b[2 q", "steady block is DECSCUSR 2");
    env.set(Some("bar"), Some("1"));
    assert_eq!(attach_bytes(), b"\x1b[5 q", "blinking bar is DECSCUSR 5");
}

#[test]
fn the_catalog_default_is_the_state_that_asserts_nothing() {
    let env = CursorEnv::take();
    env.set(
        Some(
            crate::server::option_catalog::default_for("cursor-style")
                .expect("cursor-style must be in the catalog"),
        ),
        None,
    );
    assert_eq!(
        crate::rendering::configured_cursor_code(),
        0,
        "the catalog default must be the value that leaves the terminal alone"
    );
}

/// The overlay the user reads (Prefix + ?) prints its own table of defaults,
/// and it drifted: it said `cursor-style` defaulted to the empty string and
/// `cursor-blink` to `off`, while the catalog said `bar` and `on`.
///
/// This is not a sweep of the whole table. Nine more of its entries disagree
/// with the catalog today: `pane-border-style`, `set-titles-string`,
/// `status-left-style`, `status-right-style`, `window-status-style`,
/// `window-status-current-style` and `window-status-last-style` print an empty
/// default where the catalog has a real one, and `main-pane-width` and
/// `main-pane-height` print prose (`0 (60% heuristic)`) where it has `0`. Each
/// needs its own decision, so this pins the two options the issue is about.
#[test]
fn the_help_overlay_prints_the_catalog_defaults_for_the_cursor_options() {
    let lines = crate::help::options_lines();
    for name in ["cursor-style", "cursor-blink"] {
        let catalog = crate::server::option_catalog::default_for(name)
            .unwrap_or_else(|| panic!("{} must be in the catalog", name));
        let line = lines
            .iter()
            .find(|l| l.trim_start().starts_with(name))
            .unwrap_or_else(|| panic!("the overlay must list {}", name));
        let printed = line.trim_start()[name.len()..].trim();
        assert_eq!(
            printed, catalog,
            "the overlay prints [{}] as the default of {}, the catalog says [{}]",
            printed, name, catalog
        );
    }
}
