// What a liveness lookup costs for a dead PID, and that the #650 fallback is
// still there for a PID that is only refused.
//
// Every psmux command sweeps the data dir before anything else and asks
// `get_process_name_or_snapshot` about each registry's `.pid`. For a crashed
// server that PID is gone, `OpenProcess` fails, and the lookup used to walk the
// whole process table to make sure (30 to 45 ms per registry on a busy
// desktop, so six dead registries put about 200 ms on the next command). A PID
// that names no process fails with ERROR_INVALID_PARAMETER and needs no walk;
// a PID that exists but lives in another Terminal Services session fails with
// ERROR_ACCESS_DENIED, and that one must still be answered from the table
// (#650), or a desktop command deletes a live ssh started server's registry.
//
// Walks are counted with PROC_TABLE_WALKS (per thread), never timed.

use super::*;

fn walks() -> u64 {
    PROC_TABLE_WALKS.with(|c| c.get())
}

/// A PID that really existed and has really gone: the child is waited for
/// and dropped, so no handle keeps its process object alive.
fn dead_pid() -> u32 {
    let mut child = std::process::Command::new("cmd")
        .args(["/c", "exit"])
        .spawn()
        .expect("spawn cmd");
    let pid = child.id();
    let _ = child.wait();
    drop(child);
    pid
}

#[test]
fn refused_pid_still_asks_the_snapshot_issue650() {
    // ERROR_ACCESS_DENIED: the process is there, only the handle is refused.
    let mut asked = false;
    let got = name_or_snapshot(Err(5), || {
        asked = true;
        Some("psmux".to_string())
    });
    assert!(asked, "#650: a refused handle must fall back to the process table");
    assert_eq!(got.as_deref(), Some("psmux"), "#650: the table's answer must be returned");

    // Any failure other than "no such process" keeps the old behaviour too.
    let mut asked = false;
    let got = name_or_snapshot(Err(0), || {
        asked = true;
        Some("psmux".to_string())
    });
    assert!(asked && got.is_some(), "an unreadable image name must still ask the table");

    let mut asked = false;
    let got = name_or_snapshot(Err(31), || {
        asked = true;
        None
    });
    assert!(asked && got.is_none(), "an unknown error must still ask the table");
}

#[test]
fn missing_pid_skips_the_snapshot() {
    let got = name_or_snapshot(Err(ERROR_INVALID_PARAMETER), || {
        panic!("a PID that names no process must not walk the process table")
    });
    assert_eq!(got, None);

    let got = name_or_snapshot(Ok("pwsh".to_string()), || {
        panic!("a PID whose handle opened must not walk the process table")
    });
    assert_eq!(got.as_deref(), Some("pwsh"));
}

#[test]
fn dead_pid_is_reported_as_no_such_process_by_openprocess() {
    // The premise of the fast path, checked against the real API rather than
    // assumed: a gone PID is ERROR_INVALID_PARAMETER, not ACCESS_DENIED.
    let pid = dead_pid();
    match process_name_by_handle(pid) {
        Err(code) => assert_eq!(code, ERROR_INVALID_PARAMETER, "OpenProcess error for dead pid {pid}"),
        // The PID was reused by a new process in between: nothing to assert.
        Ok(name) => eprintln!("pid {pid} was reused by {name}; premise not checked this run"),
    }
}

#[test]
fn dead_pid_lookup_walks_no_process_table() {
    let pid = dead_pid();
    let by_handle = process_name_by_handle(pid);
    let before = walks();
    let got = get_process_name_or_snapshot(pid);
    let walked = walks() - before;
    if got.is_none() {
        assert_eq!(walked, 0, "a dead pid must be answered without a process table walk (handle said {by_handle:?})");
    }
}

#[test]
fn live_pid_lookup_still_answers() {
    let me = std::process::id();
    let got = get_process_name_or_snapshot(me).expect("own process must be found");
    assert!(got.to_ascii_lowercase().starts_with("psmux"), "own image name, got {got}");
}

#[test]
fn snapshot_answer_for_a_live_pid_is_unchanged() {
    // The #650 fallback itself: the table names a live process.
    let me = std::process::id();
    let got = process_name_from_snapshot(me).expect("own pid must be in the table");
    assert!(got.to_ascii_lowercase().starts_with("psmux"), "snapshot image name, got {got}");
}

#[test]
fn pin_on_first_walk_shares_one_walk_and_only_when_asked() {
    let me = std::process::id();

    // Nothing asks: no walk at all.
    let before = walks();
    {
        let _pin = pin_on_first_walk();
    }
    assert_eq!(walks() - before, 0, "a sweep that needs no table must not walk one");

    // Six fallbacks in one sweep (six refused registries): one walk.
    let before = walks();
    {
        let _pin = pin_on_first_walk();
        for _ in 0..6 {
            assert!(process_name_from_snapshot(me).is_some());
        }
    }
    assert_eq!(walks() - before, 1, "one sweep must share one process table");

    // After the guard, a fresh question walks again: nothing stays pinned.
    let before = walks();
    assert!(process_name_from_snapshot(me).is_some());
    assert!(process_name_from_snapshot(me).is_some());
    assert_eq!(walks() - before, 2, "outside a sweep every fresh lookup walks, as before");
}

#[test]
fn pin_on_first_walk_nests_and_restores() {
    let me = std::process::id();
    let before = walks();
    {
        let _outer = pin_on_first_walk();
        assert!(process_name_from_snapshot(me).is_some());
        {
            let _inner = pin_on_first_walk();
            assert!(process_name_from_snapshot(me).is_some());
        }
        // The inner guard must hand the outer one its table back.
        assert!(process_name_from_snapshot(me).is_some());
    }
    assert_eq!(walks() - before, 1, "nested sweeps share the outer table");

    let before = walks();
    assert!(process_name_from_snapshot(me).is_some());
    assert_eq!(walks() - before, 1, "and nothing is left pinned afterwards");
}
