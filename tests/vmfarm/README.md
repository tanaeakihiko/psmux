# Hyper-V test farm

Local Hyper-V VMs for two jobs:

1. a real Windows 10 22H2 (build 19045, inbox conhost 10.0.19041.x) to test psmux
   on without another machine, and
2. running `tests\run_all_tests.ps1` sharded over several VMs at once, so a full
   sweep takes roughly a fifth of the sequential time.

Everything here runs from an **elevated** PowerShell 7 on the Hyper-V host and
talks to the guests over PowerShell Direct (VMBus), so the VMs need no network
setup, WinRM or open ports. The guests use the built in `Default Switch` (NAT)
only for the optional OpenSSH Server feature and Windows Update.

| File | What it does |
| --- | --- |
| `New-GoldenVhd.ps1` | Applies an install ISO to a new VHDX with DISM, makes it bootable, adds `unattend.template.xml` and `firstlogon.ps1`. The golden is never booted and is marked read only. |
| `FarmCommon.ps1` | Helpers: credential, `New-FarmVM` (Gen2, differencing disk), `Wait-FarmGuest`, `Install-FarmGuest`, `Update-FarmGuest`, `Start-FarmDesktopJob` / `Wait-FarmDesktopJob`. |
| `New-FarmShards.ps1` | Creates, provisions and checkpoints the shard VMs (`psmux-s1..N` for Windows 11, `psmux-w10-s1..N` for Windows 10). |
| `Invoke-InVM.ps1` | Runs one script in a VM on its interactive desktop and brings the output back. |
| `Invoke-ShardedSweep.ps1` | The sharded sweep orchestrator. |
| `ShardPlan.ps1` | The shard planner the runner and the orchestrator share. |
| `suite_durations.json` | Per suite durations from a full sequential sweep, the planner's input. |
| `host_only_suites.txt` | Timing gates and WSL suites the shards leave out; run them on the host. |
| `guest\Install-Tools.ps1` | Inside a guest: installs pwsh, Git for Windows, Python, Neovim, Node.js, Alacritty, WezTerm, OpenSSH Server. |
| `guest\Install-Updates.ps1` | Inside a guest: Windows Update through the WU agent (as SYSTEM). |

Defaults: farm root `C:\vmfarm` (override with `PSMUX_VMFARM_ROOT`), holding
`iso\`, `installers\`, `vhd\` and `vms\`. The guest admin credential and every run's results
live under `%USERPROFILE%\.psmux-test-data\vmfarm\`.

## Building from scratch

1. ISOs, from Microsoft only. The Evaluation Center pages link to these
   `go.microsoft.com` LinkIDs (64 bit, en-US):
   * Windows 10 Enterprise 22H2 evaluation: LinkID 2208844 (19045.2006)
   * Windows 11 Enterprise 25H2 evaluation: LinkID 2334167 (26200.6584)

   Check `Get-FileHash` against the hash Microsoft publishes and
   `Get-AuthenticodeSignature` on `setup.exe` and `efi\boot\bootx64.efi`.
2. Installers in `C:\vmfarm\installers\`, each verified (Authenticode, or the
   publisher's SHA256 for the unsigned ones): `PowerShell-<v>-win-x64.zip`,
   `Git-<v>-64-bit.exe`, `python-<v>-amd64.exe`, `nvim-win64.msi`,
   `node-v<v>-x64.msi`, `Alacritty-v<v>-installer.msi`,
   `WezTerm-<v>-setup.exe`. Use the versions the host has.
3. ```powershell
   . .\FarmCommon.ps1
   $cred = New-FarmCredential            # random password, Export-Clixml (DPAPI)
   .\New-GoldenVhd.ps1 -IsoPath C:\vmfarm\iso\w10.iso -VhdPath C:\vmfarm\vhd\golden-w10.vhdx -Credential $cred
   .\New-GoldenVhd.ps1 -IsoPath C:\vmfarm\iso\w11.iso -VhdPath C:\vmfarm\vhd\golden-w11.vhdx -Credential $cred
   .\New-FarmShards.ps1 -Os w11 -Count 5
   .\New-FarmShards.ps1 -Os w10 -Count 5      # optional Windows 10 shard set
   ```
   The Windows 10 RTM image must be patched before PowerShell 7.7 runs on it
   (.NET 11 needs the CET fixes: "Your Windows doesn't fully support CET");
   `New-FarmShards.ps1` and the single VM recipe below run `Update-FarmGuest`.

The single Windows 10 VM `psmux-w10`:

```powershell
. .\FarmCommon.ps1
New-FarmVM -Name psmux-w10 -ParentVhd C:\vmfarm\vhd\golden-w10.vhdx -Cpu 4 -MemoryBytes 6GB
Start-VM psmux-w10; Wait-FarmGuest psmux-w10
Update-FarmGuest psmux-w10; Install-FarmGuest psmux-w10
Checkpoint-VM -Name psmux-w10 -SnapshotName clean
```

Each VM boots its own differencing disk off the golden, so the first boot runs
specialize and OOBE from the answer file (own SID and computer name, no
sysprep): local admin `psmuxtest`, autologon for ever, no sleep, screen saver,
lock screen or Windows Update, Defender on but excluding `C:\psmux` and the
user's temp folder. The `clean` checkpoint is taken with the VM running and
logged on, so restoring it is a few seconds and lands on a ready desktop.

## Running something in a VM

```powershell
cd tests\vmfarm
.\Invoke-InVM.ps1 -VMName psmux-w10 -Script ..\test_foo.ps1 -BinDir <dir with psmux.exe, tmux.exe, pmux.exe>
```

The script runs on the VM's interactive desktop as the logged on user, elevated
and at Normal priority, with `-BinDir`'s copy first on PATH. Its stdout and
stderr are printed and the guest work folder (everything the script wrote next
to itself) is copied to `%TEMP%\vmfarm-out\<vm>-<id>\`. `-CopyIn` adds files or
folders next to the script, `-NoDesktop` runs it straight over PowerShell
Direct instead (no desktop: fine for CLI only checks, not for anything that
opens a window or injects console input). Restore the clean state with
`Restore-VMSnapshot -VMName psmux-w10 -Name clean -Confirm:$false`.

For an interactive look, `vmconnect.exe localhost psmux-w10`.

## Sharded sweep

```powershell
.\Invoke-ShardedSweep.ps1 -PlanOnly            # show the plan and estimates
.\Invoke-ShardedSweep.ps1                      # 5 Windows 11 shards, installed binaries
.\Invoke-ShardedSweep.ps1 -Os w10              # the Windows 10 shard set
.\Invoke-ShardedSweep.ps1 -Only '^test_(all|tmux_compat)$' -ShardCount 2
```

Per shard VM it restores `clean`, copies in `~\.cargo\bin\{psmux,tmux,pmux}.exe`
as `C:\psmux\target\release\` (the runner's own binary discovery) and this tests
tree as `C:\psmux\tests`, and starts
`run_all_tests.ps1 -ShardIndex i -ShardCount n -Exclude <host only>` on the
desktop with `PSMUX_TEST_SANDBOX=1`, which is set only inside the VM. Each
shard's `progress.log` is mirrored to the host every 30 s and its result lines
echoed; `STALL` is printed when a shard's progress.log has not changed for 20
minutes; past its deadline (estimate x 1.6 + 30 min, or `-DeadlineMinutes`) a
shard gets the runner's stop flag and then, five minutes later, is turned off.
At the end every shard's run folder and metrics are copied to
`%USERPROFILE%\.psmux-test-data\vmfarm\<run id>\shard<i>\`, and
`merged_summary.txt` / `merged_results.jsonl` there hold the merged result.

Run the host only suites on the host:

```powershell
$re = .\Invoke-ShardedSweep.ps1 -ListHostOnly
$env:PSMUX_TEST_SANDBOX = '1'   # only on a disposable machine, see AGENTS.md
pwsh -File ..\run_all_tests.ps1 -Only $re
```

### How suites are assigned

`run_all_tests.ps1 -ShardIndex i -ShardCount n` filters the suite list
(`-Only`, `-PerfOnly`, `-Exclude`) and then keeps slice `i` of a greedy longest
first plan over `suite_durations.json` (`-ShardTimings` takes another file, a
JSON map or any run's `results.jsonl`). Unknown suites cost the median. The plan
depends only on the suite list and the timings, so each VM computes its own
slice and the slices partition the list exactly. Without the shard switches the
runner behaves as before.
