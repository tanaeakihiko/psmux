//! display-popup follows default-shell, as tmux does: a command string runs
//! through it and an empty popup opens it. With default-shell unset a popup
//! builds exactly what it always did (`pwsh -NoProfile -Command <cmd>`, and
//! the pane shell for an empty popup).

use super::*;

fn argv(b: &portable_pty::CommandBuilder) -> Vec<String> {
    b.get_argv().iter().map(|a| a.to_string_lossy().into_owned()).collect()
}

fn cmd_exe() -> String {
    std::env::var("ComSpec").unwrap_or_else(|_| r"C:\Windows\System32\cmd.exe".into())
}

#[cfg(windows)]
#[test]
fn unset_default_shell_keeps_todays_pwsh_popup() {
    let a = argv(&popup_command_builder("Get-Date; Read-Host", ""));
    assert_eq!(a, ["pwsh", "-NoProfile", "-Command", "Get-Date; Read-Host"]);
}

#[cfg(windows)]
#[test]
fn unset_default_shell_empty_popup_is_the_pane_shell() {
    assert_eq!(
        argv(&popup_command_builder("", "")),
        argv(&crate::pane::build_command(None, true, false))
    );
}

#[cfg(windows)]
#[test]
fn cmd_default_shell_runs_the_popup_command_in_cmd() {
    let a = argv(&popup_command_builder("echo %OS% & pause", &cmd_exe()));
    assert!(a[0].to_ascii_lowercase().ends_with("cmd.exe"), "{a:?}");
    assert_eq!(&a[1..], ["/C", "echo %OS% & pause"], "{a:?}");
}

#[cfg(windows)]
#[test]
fn cmd_default_shell_empty_popup_opens_cmd() {
    let a = argv(&popup_command_builder("", &cmd_exe()));
    assert!(a[0].to_ascii_lowercase().ends_with("cmd.exe"), "{a:?}");
}

#[cfg(windows)]
#[test]
fn git_bash_default_shell_runs_the_popup_command_with_dash_c() {
    let bash = r"C:\Program Files\Git\bin\bash.exe";
    if !std::path::Path::new(bash).exists() {
        eprintln!("skip: Git Bash not installed");
        return;
    }
    let a = argv(&popup_command_builder("echo $0; read", bash));
    assert!(a[0].to_ascii_lowercase().ends_with("bash.exe"), "{a:?}");
    assert_eq!(&a[1..], ["-c", "echo $0; read"], "{a:?}");
}

#[cfg(windows)]
#[test]
fn pwsh_default_shell_keeps_the_profile_free_invocation() {
    let Some(pwsh) = crate::pane::command_shell_for("pwsh") else {
        eprintln!("skip: pwsh not installed");
        return;
    };
    let a = argv(&popup_command_builder("Get-Date", "pwsh"));
    assert_eq!(a, [pwsh.as_str(), "-NoProfile", "-Command", "Get-Date"]);
}

#[cfg(windows)]
#[test]
fn a_default_shell_that_does_not_exist_keeps_todays_popup() {
    let a = argv(&popup_command_builder("Get-Date", r"C:\no\such\shell.exe"));
    assert_eq!(a, ["pwsh", "-NoProfile", "-Command", "Get-Date"]);
}

#[cfg(windows)]
#[test]
fn argv_form_still_decodes_with_a_default_shell() {
    let a = argv(&popup_command_builder("-- cmd.exe /q /k", &cmd_exe()));
    assert_eq!(a, ["cmd.exe", "/q", "/k"], "{a:?}");
}
