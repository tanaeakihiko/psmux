//! tmux runs a pane command string through `default-shell -c` (spawn.c).
//! psmux ran it through the SHELL variable (or the pwsh walk) even when
//! `default-shell` named another shell: `set -g default-shell cmd` gave cmd
//! panes, but `split-window "echo %OS%"` ran in pwsh. A command now follows
//! the configured default-shell; with default-shell unset nothing changes.

use super::*;

fn argv(b: &CommandBuilder) -> Vec<String> {
    b.get_argv().iter().map(|a| a.to_string_lossy().into_owned()).collect()
}

fn cmd_exe() -> String {
    std::env::var("ComSpec").unwrap_or_else(|_| r"C:\Windows\System32\cmd.exe".into())
}

#[test]
fn unset_default_shell_names_no_command_shell() {
    assert_eq!(command_shell_for(""), None);
    assert_eq!(command_shell_for("   "), None);
}

#[test]
fn a_default_shell_that_does_not_exist_falls_back() {
    assert_eq!(command_shell_for(r"C:\no\such\shell-1115.exe"), None);
    assert_eq!(command_shell_for("no-such-shell-1115"), None);
}

#[cfg(windows)]
#[test]
fn cmd_default_shell_resolves_with_or_without_a_path() {
    let full = command_shell_for(&cmd_exe()).expect("full path");
    assert!(full.to_ascii_lowercase().ends_with("cmd.exe"), "{full}");
    let bare = command_shell_for("cmd").expect("bare name");
    assert!(bare.to_ascii_lowercase().ends_with("cmd.exe"), "{bare}");
}

#[cfg(windows)]
#[test]
fn a_command_string_runs_in_the_named_shell() {
    let shell = command_shell_for(&cmd_exe()).unwrap();
    let b = build_command_in(Some("echo %OS% & ver"), Some(&shell), false, false);
    let a = argv(&b);
    assert!(a[0].to_ascii_lowercase().ends_with("cmd.exe"), "{a:?}");
    assert_eq!(&a[1..], ["/C", "echo %OS% & ver"], "{a:?}");
}

#[cfg(windows)]
#[test]
fn default_shell_with_arguments_still_resolves_the_program() {
    let value = format!("\"{}\" /Q", cmd_exe());
    let shell = command_shell_for(&value).expect("quoted path with args");
    assert!(shell.to_ascii_lowercase().ends_with("cmd.exe"), "{shell}");
}

#[cfg(windows)]
#[test]
fn git_bash_default_shell_runs_commands_with_dash_c() {
    let bash = r"C:\Program Files\Git\bin\bash.exe";
    if !std::path::Path::new(bash).exists() {
        eprintln!("skip: Git Bash not installed");
        return;
    }
    let shell = command_shell_for(bash).expect("git bash");
    let b = build_command_in(Some("echo $0 && uname"), Some(&shell), false, false);
    let a = argv(&b);
    assert!(a[0].to_ascii_lowercase().ends_with("bash.exe"), "{a:?}");
    assert_eq!(&a[1..], ["-c", "echo $0 && uname"], "{a:?}");
}

/// #1115: the `cat` placeholder follows the shell that really runs it, now
/// the configured default-shell.
#[cfg(windows)]
#[test]
fn cat_placeholder_follows_the_default_shell() {
    let shell = command_shell_for(&cmd_exe()).unwrap();
    let a = argv(&build_command_in(Some("cat"), Some(&shell), false, false));
    // cmd cannot block like cat: PowerShell runs the blocker directly.
    assert!(a.iter().any(|w| w == POWERSHELL_CAT_BLOCKER), "{a:?}");
    assert!(!a[0].to_ascii_lowercase().ends_with("cmd.exe"), "{a:?}");
    let argv_form = argv(&build_argv_command_in(&["cat".to_string()], Some(&shell), false, false));
    assert_eq!(a, argv_form);

    let bash = r"C:\Program Files\Git\bin\bash.exe";
    if std::path::Path::new(bash).exists() {
        let shell = command_shell_for(bash).unwrap();
        let a = argv(&build_command_in(Some("cat"), Some(&shell), false, false));
        assert!(a[0].to_ascii_lowercase().ends_with("bash.exe"), "{a:?}");
        assert_eq!(&a[1..], ["-c", POSIX_CAT_BLOCKER], "{a:?}");
    }
}

/// No default-shell: exactly the builder psmux has always made.
#[cfg(windows)]
#[test]
fn no_default_shell_builds_what_it_always_did() {
    for c in ["echo hi", "cat", "Get-ChildItem | Select -First 1", "-- cmd /c ver"] {
        assert_eq!(
            argv(&build_command_in(Some(c), None, false, false)),
            argv(&build_command(Some(c), false, false)),
            "{c}"
        );
    }
}
