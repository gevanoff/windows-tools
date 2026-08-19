# Android Build and Install

Build an Android project with its Gradle wrapper and install the resulting debug APK on an Android device connected to a Windows 11 desktop.

The tool is intended for quick physical-device testing of local Android projects without requiring `adb` to already be available on the PowerShell `PATH`.

## Requirements

- Windows 11
- Windows PowerShell 5.1 or later
- an Android project containing `gradlew.bat`
- a JDK compatible with that project's Gradle/Android Gradle Plugin versions
- Android SDK Platform-Tools (`adb.exe`)
- an Android device with USB debugging enabled
- the appropriate Windows USB driver for the device, when one is required

The project itself remains responsible for its normal Gradle dependencies and Android SDK components.

## Use

### Double-click

1. Connect the Android device by USB.
2. Unlock the device and approve the USB debugging prompt if Android displays one.
3. Double-click `Build-And-Install-Android.bat`.
4. Choose the repository or Android project folder.
5. The tool builds the debug APK and installs it on the connected device.

### Drag and drop

Drag an Android repository or project folder onto `Build-And-Install-Android.bat` in File Explorer.

This works with both layouts currently used by the projects this utility was designed around:

```text
chatturanga/
    gradlew.bat
    ...
```

and repositories where Android lives in a subdirectory:

```text
prism-break/
    android/
        gradlew.bat
        ...
```

The tool looks for `gradlew.bat` in the selected directory and up to two directory levels below it. If more than one Gradle project is found, it asks which one to build.

## Build and install behavior

By default the tool runs:

```text
gradlew.bat assembleDebug --stacktrace
```

After a successful build it searches Android module output directories for APKs under:

```text
build\outputs\apk
```

If there is one debug APK, it is selected automatically. If several APKs are present, the tool asks which one to install.

Installation uses:

```text
adb -s <device-serial> install -r <apk>
```

`-r` replaces an existing installation while preserving its app data when Android permits the update.

The tool does **not** automatically uninstall an existing app when signatures differ. Android reports this as `INSTALL_FAILED_UPDATE_INCOMPATIBLE`; uninstalling would normally remove the app's local data, so that action is left explicit.

## Finding adb

The tool does not require `adb` to be on `PATH`. It checks, in order:

1. `sdk.dir` in the selected Gradle project's `local.properties`
2. `ANDROID_SDK_ROOT`
3. `ANDROID_HOME`
4. the standard Android Studio SDK location under `%LOCALAPPDATA%\Android\Sdk`
5. `adb.exe` on `PATH`

This is intended to avoid the common Windows situation where Android Studio can use `adb` but a normal PowerShell window cannot.

## Device handling

The tool runs `adb devices -l` before building.

- One authorized device: selected automatically.
- Multiple authorized devices: asks which device to use.
- Unauthorized device: asks you to unlock it and approve USB debugging.
- Offline device: stops and asks you to reconnect or restart USB debugging.
- No device: stops before building.

You can also specify a serial explicitly with `-DeviceSerial`.

## Java

The utility deliberately does not choose or change JDK versions automatically. Android projects can have materially different Gradle/JDK compatibility requirements.

It uses:

1. `JAVA_HOME`, when set and valid; otherwise
2. `java.exe` from `PATH`.

If a project's Gradle version rejects the selected Java runtime, use the JDK required by that project and run the utility again.

## Command-line use

Run with the standard debug build:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File .\Build-And-Install-Android.ps1 `
    -Project "C:\src\chatturanga"
```

Specify a different Gradle assemble task:

```powershell
.\Build-And-Install-Android.ps1 `
    -Project "C:\src\some-app" `
    -GradleTask "assembleDemoDebug"
```

Target a particular attached device:

```powershell
.\Build-And-Install-Android.ps1 `
    -Project "C:\src\some-app" `
    -DeviceSerial "DEVICE_SERIAL"
```

## Safety characteristics

- validates the selected project directory before building;
- uses the project's own Gradle wrapper rather than a global Gradle installation;
- stops before installation when the build fails;
- stops before building when no usable Android device is connected;
- never uninstalls an existing Android application automatically;
- uses `adb install -r` so successful updates normally retain app data;
- returns a nonzero exit code when building or installation fails.

## Possible future improvements

- optionally launch the installed app after installation;
- remember recently used project folders;
- add a graphical project/device chooser instead of console selection when multiple choices exist;
- optionally run project tests before installation;
- support saved per-project Gradle task/JDK preferences;
- support Android App Bundle workflows when needed.
