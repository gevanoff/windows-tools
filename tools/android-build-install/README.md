# Android Build and Install

Build Android projects with their Gradle wrappers, install debug APKs on a connected Android device, compare installed APKs with local builds, update repositories from Git, and keep per-project build preferences from one Windows 11 launcher.

## Requirements

- Windows 11
- Windows PowerShell 5.1 or later
- Git for Windows for the **Git Pull** action
- an Android project containing `gradlew.bat`
- a JDK compatible with the project's Gradle / Android Gradle Plugin versions
- Android SDK Platform-Tools (`adb.exe`)
- Android SDK Build-Tools (`aapt2.exe` or `aapt.exe`) for package inspection and auto-launch
- an Android device with USB debugging enabled
- the appropriate Windows USB driver when the device requires one

The project remains responsible for its normal Gradle dependencies and Android SDK components.

## Normal workflow

1. Connect and unlock the Android device.
2. Double-click `Build-And-Install-Android.bat`.
3. Select a remembered repository.
4. Use any of the available actions:
   - **Build** — build, install, and optionally launch the project;
   - **Git Pull** — safely fast-forward the selected clean repository;
   - **Settings...** — configure persistent project-specific build defaults;
   - **Scan Device...** — compare saved projects' local APKs with installed copies;
   - **Reports...** — inspect previous build/install logs;
   - **Add... / Remove** — manage remembered repository paths.
5. After a build/install run finishes, the chooser returns so another action can be performed without restarting the launcher.

Double-clicking a project is equivalent to selecting it and clicking **Build**.

## Drag and drop

Drag an Android repository or project folder onto `Build-And-Install-Android.bat` in File Explorer.

The dragged path is used immediately, remembered for future sessions, and built using any saved per-project settings. After the run finishes, the normal project chooser opens.

Both root-level and nested Android layouts are supported. For example:

```text
chatturanga/
    gradlew.bat
```

and:

```text
prism-break/
    android/
        gradlew.bat
```

The tool searches for `gradlew.bat` in the selected directory and up to two directory levels below it. If multiple Gradle roots exist, it asks which one to build.

## Saved projects

Remembered repository paths are stored per Windows user at:

```text
%LOCALAPPDATA%\WindowsTools\android-build-install\projects.json
```

The most recently used project moves to the top. Paths that no longer exist are omitted from the chooser. Removing a project from the chooser does not modify or delete the repository.

## Per-project settings

Click **Settings...** for the selected project. Settings are stored outside Git at:

```text
%LOCALAPPDATA%\WindowsTools\android-build-install\project-preferences.json
```

Available settings are:

### Gradle task

Default:

```text
assembleDebug
```

This can be changed for projects that use another assemble task, for example:

```text
assembleDemoDebug
```

### Preferred APK

When a project produces several debug APKs, a preferred APK can be stored so the tool does not ask which one to install on every run.

The path can be absolute or relative to the saved repository path. Using a relative path is recommended because it remains valid if the entire repository tree is moved together.

For Prism Break, the conventional preferred APK is:

```text
android\app\build\outputs\apk\debug\app-debug.apk
```

If a configured preferred APK is not produced by the current build, the tool warns and falls back to the normal APK chooser rather than installing an arbitrary file.

### JAVA_HOME

A project-specific JDK directory can be selected. When configured, the tool sets `JAVA_HOME` for that build before invoking the project's Gradle wrapper.

When blank, Java resolution follows the normal environment:

1. existing `JAVA_HOME`;
2. `java.exe` on `PATH`.

### Auto-launch

When enabled, a successful install is followed by an attempt to launch the installed package's launcher activity through ADB.

The APK package ID is read with Android Build-Tools. Auto-launch failure is treated as a warning: the build/install still counts as successful because installation already completed.

## Git Pull

Select a project and click **Git Pull** to update its repository.

The action deliberately uses:

```text
git pull --ff-only
```

and has conservative safety rules:

- the selected path must be inside a Git repository;
- the current branch must have an upstream tracking branch;
- detached HEAD is rejected;
- any tracked or untracked working-tree change causes the pull to stop;
- no automatic stash, merge commit, reset, checkout, or conflict resolution is performed;
- non-fast-forward pulls fail without changing history.

This makes **Git Pull** suitable for quickly updating a clean local checkout while keeping any repository with local work explicit and under normal Git control.

## Build and install behavior

The default build command is:

```text
gradlew.bat assembleDebug --stacktrace
```

After a successful build the tool searches Android module output directories under:

```text
build\outputs\apk
```

If there is one debug APK it is selected automatically. When several exist, the saved preferred APK is used if it exactly matches a produced APK; otherwise the tool asks which one to install.

Installation uses:

```text
adb -s <device-serial> install -r <apk>
```

`-r` replaces an existing installation while preserving app data when Android permits the update.

The tool does **not** automatically uninstall an app when Android reports `INSTALL_FAILED_UPDATE_INCOMPATIBLE`. Uninstalling normally removes local app data, so that remains an explicit user action.

## Device scan

Click **Scan Device...** to compare existing local debug APKs with packages currently installed on the attached device. The scan does not rebuild or install anything.

Results are:

- **Same** — local and installed APK SHA-256 hashes match exactly;
- **Different** — the package is installed but its APK bytes differ from the local APK;
- **Not installed** — the local APK's package is absent from the device;
- **No local build** — no local APK exists yet;
- **Unknown** — an exact comparison cannot safely be made.

The scanner identifies package IDs using Android Build-Tools, queries the installed package with ADB, temporarily pulls a single installed APK when possible, computes SHA-256 hashes, and removes the temporary copy afterward.

Split APK installations and ambiguous local APK sets are reported as **Unknown** rather than guessed. When several local APKs exist, the scanner recognizes one unique conventional `app\build\outputs\apk\debug\app-debug.apk` when present.

## Reports and failure logs

Each build/install run is recorded under:

```text
%LOCALAPPDATA%\WindowsTools\android-build-install\logs
```

Reports include:

- selected project;
- Gradle task;
- preferred APK preference;
- JDK override;
- auto-launch setting;
- Gradle output;
- ADB install/launch output;
- final exit code.

Use **Reports...** to browse and open previous runs. If a build/install fails, its report also opens automatically in Notepad.

## Finding ADB

The tool does not require `adb` to be on `PATH`. It checks, in order:

1. `sdk.dir` in the selected Gradle project's `local.properties`;
2. `ANDROID_SDK_ROOT`;
3. `ANDROID_HOME`;
4. `%LOCALAPPDATA%\Android\Sdk`;
5. `adb.exe` on `PATH`.

## Device handling

Before building, the tool runs `adb devices -l`.

- One authorized device: selected automatically.
- Multiple authorized devices: asks which one to use.
- Unauthorized device: stops and asks for USB debugging authorization.
- Offline device: stops and asks for reconnection/restart of USB debugging.
- No device: stops before building.

## Command-line use

The compatibility entrypoint remains:

```powershell
.\Build-And-Install-Android.ps1 -Project "C:\src\chatturanga"
```

Optional arguments include:

```powershell
.\Build-And-Install-Android.ps1 `
    -Project "C:\src\some-app" `
    -GradleTask "assembleDemoDebug" `
    -PreferredApk "app\build\outputs\apk\demo\debug\app-demo-debug.apk" `
    -JavaHome "C:\Program Files\Android\Android Studio\jbr" `
    -AutoLaunch
```

A specific attached device can be selected with `-DeviceSerial`.

Direct command-line calls do not use the saved-project chooser or launcher-level report browser.

## Safety characteristics

- project source remains untouched by build/install operations;
- each project uses its own Gradle wrapper;
- installation never starts when Gradle fails;
- the tool never automatically uninstalls an Android application;
- `adb install -r` is used to preserve app data where Android permits it;
- Git Pull refuses dirty worktrees and non-fast-forward updates;
- device scanning is read-only except for a temporary local APK copy that is removed afterward;
- saved projects and preferences live under the Windows user's local application-data directory, outside Git repositories;
- build/install diagnostics are preserved as timestamped reports.

## Possible future improvements

- optional test/lint tasks before installation;
- graphical selection when multiple Android devices are attached;
- a per-project option to run Git Pull automatically before building (kept off by default);
- Android App Bundle workflows when needed.
