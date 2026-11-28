//! #1115: the `cat` placeholder blocker must be written for the shell that
//! runs it. With SHELL set to Git Bash the PowerShell blocker reached
//! `bash -c` and died with a syntax error (status 2); with cmd.exe it died
//! with "'$__psmux_in' is not recognized" (status 1).

use super::*;

#[test]
fn powershell_and_no_shell_keep_the_powershell_blocker() {
    for s in [
        None,
        Some(r"C:\Program Files\PowerShell\7\pwsh.exe"),
        Some(r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"),
        Some("pwsh"),
        Some(r"C:\Users\x\AppData\Local\Microsoft\WindowsApps\pwsh.exe"),
    ] {
        assert_eq!(
            cat_blocker_for_shell(s),
            CatBlocker::PaneShell(POWERSHELL_CAT_BLOCKER),
            "{s:?}"
        );
    }
}

#[test]
fn posix_shells_get_a_posix_blocker() {
    for s in [
        r"C:\Program Files\Git\bin\bash.exe",
        r"C:\Program Files\Git\usr\bin\bash.exe",
        r#""C:\Program Files\Git\bin\bash.exe""#,
        r"C:\msys64\usr\bin\sh.exe",
        r"C:\msys64\usr\bin\zsh.exe",
        "dash",
        r"C:\cygwin64\bin\ksh.EXE",
        "BASH.EXE",
    ] {
        assert_eq!(cat_blocker_for_shell(Some(s)), CatBlocker::PosixShell(POSIX_CAT_BLOCKER), "{s}");
    }
    assert_eq!(
        cat_blocker_for_shell(Some(r"C:\tools\fish.exe")),
        CatBlocker::PosixShell(FISH_CAT_BLOCKER)
    );
}

#[test]
fn cmd_and_unknown_shells_start_powershell_directly() {
    for s in [r"C:\Windows\System32\cmd.exe", "cmd", r"C:\tools\nu.exe", r"C:\x\elvish.exe"] {
        assert_eq!(cat_blocker_for_shell(Some(s)), CatBlocker::PowerShellDirect, "{s}");
    }
}

#[test]
fn posix_blocker_uses_no_powershell_syntax() {
    for b in [POSIX_CAT_BLOCKER, FISH_CAT_BLOCKER] {
        assert!(!b.contains("[Console]"), "{b}");
        assert!(!b.contains("-ge"), "{b}");
        assert!(!b.contains("Start-Sleep"), "{b}");
    }
}

/// Parse the POSIX blocker with a real bash when Git for Windows is present.
/// `bash -n` only parses, it runs nothing.
#[cfg(windows)]
#[test]
fn posix_blocker_parses_in_git_bash_when_present() {
    let bash = r"C:\Program Files\Git\bin\bash.exe";
    if !std::path::Path::new(bash).exists() {
        eprintln!("skip: Git Bash not installed");
        return;
    }
    let out = std::process::Command::new(bash)
        .args(["-n", "-c", POSIX_CAT_BLOCKER])
        .output()
        .expect("run bash -n");
    assert!(out.status.success(), "bash -n failed: {}", String::from_utf8_lossy(&out.stderr));
    // The old blocker is exactly what bash rejected in #1115.
    let old = std::process::Command::new(bash)
        .args(["-n", "-c", POWERSHELL_CAT_BLOCKER])
        .output()
        .expect("run bash -n");
    assert!(!old.status.success());
}
