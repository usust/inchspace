#[cfg(any(target_os = "macos", target_os = "windows"))]
use base64::{engine::general_purpose, Engine as _};
#[cfg(target_os = "macos")]
use objc2::{runtime::AnyObject, AllocAnyThread};
#[cfg(target_os = "macos")]
use objc2_app_kit::{
    NSBitmapImageFileType, NSBitmapImageRep, NSBitmapImageRepPropertyKey, NSWorkspace,
};
#[cfg(target_os = "macos")]
use objc2_foundation::{NSDictionary, NSSize, NSString};
#[cfg(any(target_os = "macos", target_os = "linux"))]
use std::fs;
#[cfg(target_os = "windows")]
use std::os::windows::ffi::OsStrExt;
#[cfg(target_os = "macos")]
use std::time::{SystemTime, UNIX_EPOCH};
use serde::Serialize;
use std::{
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::Mutex,
    thread,
    time::{Duration, Instant},
};
use sysinfo::{Networks, System};
use tauri::{
    menu::{AboutMetadata, MenuBuilder, SubmenuBuilder},
    Manager,
};
#[cfg(target_os = "windows")]
use windows_sys::{
    core::PCWSTR,
    Win32::{
        Graphics::Gdi::{
            CreateCompatibleDC, CreateDIBSection, DeleteDC, DeleteObject, GetDC, ReleaseDC,
            SelectObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS,
        },
        UI::{
            Shell::{SHGetFileInfoW, SHFILEINFOW, SHGFI_ICON, SHGFI_LARGEICON, SHGFI_SYSICONINDEX},
            WindowsAndMessaging::{DestroyIcon, DrawIconEx, DI_NORMAL, HICON},
        },
    },
};
#[cfg(target_os = "windows")]
use windows::{
    Win32::UI::{
        Controls::{IImageList, ILD_TRANSPARENT},
        Shell::{SHGetImageList, SHIL_EXTRALARGE, SHIL_JUMBO},
    },
};

const APP_NAME: &str = "方寸 InchSpace";
const MAIN_WINDOW_LABEL: &str = "main";
const FLOATING_BALL_WINDOW_LABEL: &str = "floating-ball";
const FLOATING_BALL_SIZE: f64 = 64.0;
const FLOATING_BALL_MARGIN: f64 = 22.0;
const MAIN_WINDOW_DEFAULT_WIDTH: f64 = 1180.0;
const MAIN_WINDOW_DEFAULT_HEIGHT: f64 = 820.0;
const MAIN_WINDOW_MIN_WIDTH: f64 = 1176.0;
const MAIN_WINDOW_MIN_HEIGHT: f64 = 814.0;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ApplicationInfo {
    name: String,
    path: String,
    icon_data_url: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DirectoryInfo {
    name: String,
    path: String,
    comparison_path: String,
    containing_app_directory_path: Option<String>,
    icon_data_url: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ApplicationPickerOptions {
    default_path: Option<String>,
    filters: Vec<ApplicationFileFilter>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ApplicationFileFilter {
    name: String,
    extensions: Vec<String>,
}

struct SystemMetricsSampler {
    last_network_sample: Instant,
    networks: Networks,
    system: System,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SystemMetrics {
    cpu_usage: f32,
    download_bytes_per_second: f64,
    memory_total_bytes: u64,
    memory_usage: f32,
    memory_used_bytes: u64,
    upload_bytes_per_second: f64,
}

impl SystemMetricsSampler {
    fn new() -> Self {
        let mut system = System::new();
        system.refresh_cpu_usage();
        system.refresh_memory();

        Self {
            last_network_sample: Instant::now(),
            networks: Networks::new_with_refreshed_list(),
            system,
        }
    }

    fn sample(&mut self) -> SystemMetrics {
        self.system.refresh_cpu_usage();
        self.system.refresh_memory();

        let now = Instant::now();
        let elapsed_seconds = now
            .duration_since(self.last_network_sample)
            .as_secs_f64()
            .max(0.001);

        self.networks.refresh(true);
        let downloaded_bytes = self
            .networks
            .iter()
            .map(|(_, network)| network.received())
            .sum::<u64>();
        let uploaded_bytes = self
            .networks
            .iter()
            .map(|(_, network)| network.transmitted())
            .sum::<u64>();

        self.last_network_sample = now;

        let memory_total_bytes = self.system.total_memory();
        let memory_used_bytes = self.system.used_memory();
        let memory_usage = if memory_total_bytes == 0 {
            0.0
        } else {
            memory_used_bytes as f32 / memory_total_bytes as f32 * 100.0
        };

        SystemMetrics {
            cpu_usage: self.system.global_cpu_usage().clamp(0.0, 100.0),
            download_bytes_per_second: downloaded_bytes as f64 / elapsed_seconds,
            memory_total_bytes,
            memory_usage: memory_usage.clamp(0.0, 100.0),
            memory_used_bytes,
            upload_bytes_per_second: uploaded_bytes as f64 / elapsed_seconds,
        }
    }
}

fn application_filter(name: &str, extensions: &[&str]) -> ApplicationFileFilter {
    ApplicationFileFilter {
        name: name.to_owned(),
        extensions: extensions
            .iter()
            .map(|extension| (*extension).to_owned())
            .collect(),
    }
}

fn existing_directory(path: impl Into<PathBuf>) -> Option<String> {
    let path = path.into();

    path.is_dir()
        .then(|| path.to_string_lossy().into_owned())
}

fn path_extension_lowercase(path: &Path) -> Option<String> {
    path.extension()
        .and_then(|extension| extension.to_str())
        .map(str::to_ascii_lowercase)
}

fn has_path_extension(path: &Path, extensions: &[&str]) -> bool {
    path_extension_lowercase(path)
        .as_deref()
        .is_some_and(|extension| extensions.contains(&extension))
}

#[cfg(target_os = "macos")]
fn plist_string_value(plist: &plist::Value, key: &str) -> Option<String> {
    plist
        .as_dictionary()
        .and_then(|dictionary| dictionary.get(key))
        .and_then(plist::Value::as_string)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

fn fallback_app_name(app_path: &Path) -> String {
    app_path
        .file_stem()
        .and_then(|name| name.to_str())
        .unwrap_or("Application")
        .to_owned()
}

fn fallback_directory_name(directory_path: &Path) -> String {
    directory_path
        .file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.trim().is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| directory_path.to_string_lossy().into_owned())
}

#[cfg(target_os = "macos")]
fn macos_mobile_documents_directory() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .map(|home| home.join("Library").join("Mobile Documents"))
}

#[cfg(target_os = "macos")]
fn macos_icloud_drive_directory() -> Option<PathBuf> {
    macos_mobile_documents_directory().map(|path| path.join("com~apple~CloudDocs"))
}

#[cfg(target_os = "macos")]
fn is_same_path_text(first: &Path, second: &Path) -> bool {
    first.to_string_lossy().trim_end_matches('/')
        == second.to_string_lossy().trim_end_matches('/')
}

#[cfg(target_os = "macos")]
fn macos_resolve_directory_alias(directory_path: &Path) -> PathBuf {
    let Some(mobile_documents) = macos_mobile_documents_directory() else {
        return directory_path.to_path_buf();
    };
    let Some(icloud_drive) = macos_icloud_drive_directory() else {
        return directory_path.to_path_buf();
    };

    let i_cloud_alias = mobile_documents.join("iCloud");
    let i_cloud_drive_alias = mobile_documents.join("iCloud Drive");

    if is_same_path_text(directory_path, &i_cloud_alias)
        || is_same_path_text(directory_path, &i_cloud_drive_alias)
    {
        return icloud_drive;
    }

    directory_path.to_path_buf()
}

fn canonical_directory_path(directory_path: &Path) -> PathBuf {
    fs::canonicalize(directory_path).unwrap_or_else(|_| directory_path.to_path_buf())
}

fn directory_comparison_path(directory_path: &Path) -> String {
    let value = canonical_directory_path(directory_path)
        .to_string_lossy()
        .replace('\\', "/")
        .trim_end_matches('/')
        .to_owned();

    #[cfg(any(target_os = "macos", target_os = "windows"))]
    {
        return value.to_lowercase();
    }

    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        value
    }
}

#[cfg(target_os = "macos")]
fn macos_icloud_app_container_name(directory_path: &Path) -> Option<String> {
    let mobile_documents = macos_mobile_documents_directory()?;
    let relative_path = directory_path.strip_prefix(&mobile_documents).ok()?;
    let mut components = relative_path.components();
    let container_name = components.next()?.as_os_str().to_str()?;

    if !container_name.starts_with("iCloud~") {
        return None;
    }

    let is_container_root = components.clone().next().is_none();
    let is_documents_root = components
        .next()
        .is_some_and(|component| component.as_os_str() == "Documents")
        && components.next().is_none();

    if !is_container_root && !is_documents_root {
        return None;
    }

    container_name
        .split('~')
        .next_back()
        .map(|name| name.replace('-', " "))
        .map(|name| {
            let mut characters = name.chars();
            match characters.next() {
                Some(first) => first.to_uppercase().collect::<String>() + characters.as_str(),
                None => name,
            }
        })
        .filter(|name| !name.trim().is_empty())
}

#[cfg(target_os = "macos")]
fn macos_containing_icloud_app_directory(directory_path: &Path) -> Option<PathBuf> {
    let mobile_documents = macos_mobile_documents_directory()?;
    let relative_path = directory_path.strip_prefix(&mobile_documents).ok()?;
    let mut components = relative_path.components();
    let container_name = components.next()?.as_os_str();

    if !container_name.to_str()?.starts_with("iCloud~") {
        return None;
    }

    if !components
        .next()
        .is_some_and(|component| component.as_os_str() == "Documents")
    {
        return None;
    }

    if components.next().is_none() {
        return None;
    }

    Some(mobile_documents.join(container_name).join("Documents"))
}

#[cfg(target_os = "macos")]
fn containing_app_directory_path(directory_path: &Path) -> Option<String> {
    macos_containing_icloud_app_directory(directory_path)
        .map(|path| canonical_directory_path(&path))
        .filter(|path| path.is_dir())
        .map(|path| path.to_string_lossy().into_owned())
}

#[cfg(not(target_os = "macos"))]
fn containing_app_directory_path(_directory_path: &Path) -> Option<String> {
    None
}

#[cfg(target_os = "macos")]
fn directory_display_name(directory_path: &Path) -> String {
    if macos_icloud_drive_directory()
        .as_deref()
        .is_some_and(|icloud_drive| is_same_path_text(directory_path, icloud_drive))
    {
        return "iCloud Drive".to_owned();
    }

    if let Some(container_name) = macos_icloud_app_container_name(directory_path) {
        return container_name;
    }

    fallback_directory_name(directory_path)
}

#[cfg(not(target_os = "macos"))]
fn directory_display_name(directory_path: &Path) -> String {
    fallback_directory_name(directory_path)
}

#[cfg(target_os = "macos")]
fn icon_path_from_plist(app_path: &Path, plist: &plist::Value) -> Option<PathBuf> {
    let icon_name = plist_string_value(plist, "CFBundleIconFile")?;
    let icon_file = if Path::new(&icon_name).extension().is_some() {
        icon_name
    } else {
        format!("{icon_name}.icns")
    };
    let icon_path = app_path.join("Contents").join("Resources").join(icon_file);

    icon_path.exists().then_some(icon_path)
}

#[cfg(target_os = "macos")]
fn icns_to_png_data_url(icon_path: &Path) -> Option<String> {
    let created_at = SystemTime::now().duration_since(UNIX_EPOCH).ok()?.as_millis();
    let output_path = std::env::temp_dir().join(format!(
        "inchspace-app-icon-{}-{created_at}.png",
        std::process::id()
    ));

    let output = Command::new("/usr/bin/sips")
        .arg("-s")
        .arg("format")
        .arg("png")
        .arg(icon_path)
        .arg("--out")
        .arg(&output_path)
        .output()
        .ok()?;

    if !output.status.success() {
        let _ = fs::remove_file(&output_path);
        return None;
    }

    let bytes = fs::read(&output_path).ok()?;
    let _ = fs::remove_file(&output_path);
    Some(format!(
        "data:image/png;base64,{}",
        general_purpose::STANDARD.encode(bytes)
    ))
}

#[cfg(target_os = "macos")]
fn macos_file_icon_data_url(path: &Path) -> Option<String> {
    let workspace = NSWorkspace::sharedWorkspace();
    let path = NSString::from_str(&path.to_string_lossy());
    let icon = workspace.iconForFile(&path);
    icon.setSize(NSSize::new(256.0, 256.0));

    let tiff_data = icon.TIFFRepresentation()?;
    let bitmap = NSBitmapImageRep::initWithData(NSBitmapImageRep::alloc(), &tiff_data)?;
    let property_keys: [&NSBitmapImageRepPropertyKey; 0] = [];
    let property_values: [&AnyObject; 0] = [];
    let properties = NSDictionary::<NSBitmapImageRepPropertyKey, AnyObject>::from_slices(
        &property_keys,
        &property_values,
    );
    let png_data = unsafe {
        bitmap.representationUsingType_properties(NSBitmapImageFileType::PNG, &properties)
    }?;

    Some(format!(
        "data:image/png;base64,{}",
        general_purpose::STANDARD.encode(png_data.to_vec())
    ))
}

#[cfg(target_os = "macos")]
fn macos_icloud_drive_icon_data_url() -> Option<String> {
    [
        "/System/Library/CoreServices/Finder.app/Contents/Applications/iCloud Drive.app/Contents/Resources/OpenICloudDriveAppIcon.icns",
        "/System/Library/PrivateFrameworks/iCloudDriveCore.framework/Versions/A/Resources/iCloudDrive.icns",
        "/System/Library/PrivateFrameworks/iCloudDriveCore.framework/Versions/A/Resources/iCloud Drive.app/Contents/Resources/iCloudDrive.icns",
        "/System/Library/CoreServices/Setup Assistant.app/Contents/Resources/iCloudDrive.icns",
    ]
    .into_iter()
    .map(Path::new)
    .find(|path| path.exists())
    .and_then(icns_to_png_data_url)
}

#[cfg(target_os = "macos")]
fn macos_icloud_app_container_bundle_identifier(directory_path: &Path) -> Option<String> {
    let mobile_documents = macos_mobile_documents_directory()?;
    let relative_path = directory_path.strip_prefix(&mobile_documents).ok()?;
    let mut components = relative_path.components();
    let container_name = components.next()?.as_os_str().to_str()?;

    let is_container_root = components.clone().next().is_none();
    let is_documents_root = components
        .next()
        .is_some_and(|component| component.as_os_str() == "Documents")
        && components.next().is_none();

    if !is_container_root && !is_documents_root {
        return None;
    }

    let bundle_identifier = container_name.strip_prefix("iCloud~")?.replace('~', ".");

    (!bundle_identifier.trim().is_empty()).then_some(bundle_identifier)
}

#[cfg(target_os = "macos")]
fn macos_escape_metadata_query_value(value: &str) -> String {
    value.replace('\\', "\\\\").replace('\'', "\\'")
}

#[cfg(target_os = "macos")]
fn macos_application_path_for_bundle_identifier(bundle_identifier: &str) -> Option<PathBuf> {
    let query = format!(
        "kMDItemCFBundleIdentifier == '{}'",
        macos_escape_metadata_query_value(bundle_identifier)
    );
    let output = Command::new("/usr/bin/mdfind").arg(query).output().ok()?;

    if !output.status.success() {
        return None;
    }

    String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(PathBuf::from)
        .find(|path| has_path_extension(path, &["app"]) && path.is_dir())
}

#[cfg(target_os = "macos")]
fn macos_app_icon_data_url(app_path: &Path) -> Option<String> {
    plist::Value::from_file(app_path.join("Contents").join("Info.plist"))
        .ok()
        .and_then(|plist| icon_path_from_plist(app_path, &plist))
        .and_then(|icon_path| icns_to_png_data_url(&icon_path))
        .or_else(|| macos_file_icon_data_url(app_path))
}

#[cfg(target_os = "macos")]
fn macos_icloud_app_container_icon_data_url(directory_path: &Path) -> Option<String> {
    let bundle_identifier = macos_icloud_app_container_bundle_identifier(directory_path)?;
    macos_application_path_for_bundle_identifier(&bundle_identifier)
        .as_deref()
        .and_then(macos_app_icon_data_url)
}

#[cfg(target_os = "macos")]
fn platform_directory_icon_data_url(directory_path: &Path) -> Option<String> {
    if macos_icloud_drive_directory()
        .as_deref()
        .is_some_and(|icloud_drive| is_same_path_text(directory_path, icloud_drive))
    {
        return macos_icloud_drive_icon_data_url()
            .or_else(|| macos_file_icon_data_url(directory_path));
    }

    macos_icloud_app_container_icon_data_url(directory_path)
        .or_else(|| macos_file_icon_data_url(directory_path))
}

#[cfg(target_os = "windows")]
fn platform_directory_icon_data_url(directory_path: &Path) -> Option<String> {
    windows_extract_icon_data_url(directory_path)
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn platform_directory_icon_data_url(_directory_path: &Path) -> Option<String> {
    None
}

fn platform_inspect_directory(directory_path: &Path) -> Result<DirectoryInfo, String> {
    #[cfg(target_os = "macos")]
    let directory_path = macos_resolve_directory_alias(directory_path);
    #[cfg(not(target_os = "macos"))]
    let directory_path = directory_path.to_path_buf();

    ensure_directory_path(&directory_path)?;
    let canonical_path = canonical_directory_path(&directory_path);

    Ok(DirectoryInfo {
        name: directory_display_name(&canonical_path),
        path: canonical_path.to_string_lossy().into_owned(),
        comparison_path: directory_comparison_path(&canonical_path),
        containing_app_directory_path: containing_app_directory_path(&canonical_path),
        icon_data_url: platform_directory_icon_data_url(&canonical_path),
    })
}

#[tauri::command]
fn application_picker_options() -> ApplicationPickerOptions {
    platform_application_picker_options()
}

#[tauri::command]
fn inspect_application(app_path: String) -> Result<ApplicationInfo, String> {
    let app_path = PathBuf::from(app_path);

    platform_inspect_application(&app_path)
}

#[tauri::command]
fn inspect_directory(directory_path: String) -> Result<DirectoryInfo, String> {
    let directory_path = PathBuf::from(directory_path);

    platform_inspect_directory(&directory_path)
}

#[tauri::command]
fn launch_application(app_path: String) -> Result<(), String> {
    let app_path = PathBuf::from(app_path);

    platform_launch_application(&app_path)
}

#[tauri::command]
fn open_directory(directory_path: String) -> Result<(), String> {
    let directory_path = PathBuf::from(directory_path);

    platform_open_directory(&directory_path)
}

#[tauri::command]
async fn activate_main_window(app: tauri::AppHandle) -> Result<(), String> {
    let window = get_or_create_main_window(&app)?;
    show_main_window(&window)
}

#[tauri::command]
fn system_metrics(
    sampler: tauri::State<'_, Mutex<SystemMetricsSampler>>,
) -> Result<SystemMetrics, String> {
    sampler
        .lock()
        .map_err(|_| "System metrics sampler is not available".to_owned())
        .map(|mut sampler| sampler.sample())
}

#[tauri::command]
fn request_orderly_shutdown() -> Result<(), String> {
    platform_request_orderly_shutdown()
}

#[tauri::command]
fn set_dock_icon_visible(app: tauri::AppHandle, visible: bool) -> Result<(), String> {
    platform_set_dock_icon_visible(&app, visible)
}

#[cfg(target_os = "macos")]
fn platform_set_dock_icon_visible(app: &tauri::AppHandle, visible: bool) -> Result<(), String> {
    let focused_window = app
        .webview_windows()
        .into_values()
        .find(|window| window.is_focused().unwrap_or_default());

    app.set_dock_visibility(visible)
        .map_err(|_| "Unable to update Dock icon visibility".to_owned())?;

    if let Some(focused_window) = focused_window {
        let _ = focused_window.set_focus();
    }

    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn platform_set_dock_icon_visible(
    _app: &tauri::AppHandle,
    _visible: bool,
) -> Result<(), String> {
    Ok(())
}

fn spawn_detached(mut command: Command, error_message: &str) -> Result<(), String> {
    command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());

    command
        .spawn()
        .map(|_| ())
        .map_err(|_| error_message.to_owned())
}

#[cfg(target_os = "macos")]
fn platform_request_orderly_shutdown() -> Result<(), String> {
    let script = r#"
set protectedAppNames to {"Finder", "方寸 InchSpace", "InchSpace", "inchspace"}
tell application "System Events"
  set appNames to name of every application process whose background only is false
end tell
repeat with appName in appNames
  set appNameText to appName as text
  if protectedAppNames does not contain appNameText then
    try
      ignoring application responses
        tell application appNameText to quit
      end ignoring
    end try
    delay 0.45
  end if
end repeat
delay 1.2
tell application "System Events"
  set appProcessIds to unix id of every application process whose background only is false and name is not "Finder" and name is not "方寸 InchSpace" and name is not "InchSpace" and name is not "inchspace"
end tell
repeat with appProcessId in appProcessIds
  try
    do shell script "/bin/kill -TERM " & (appProcessId as integer)
  end try
end repeat
delay 1
tell application "System Events"
  set appProcessIds to unix id of every application process whose background only is false and name is not "Finder" and name is not "方寸 InchSpace" and name is not "InchSpace" and name is not "inchspace"
end tell
repeat with appProcessId in appProcessIds
  try
    do shell script "/bin/kill -KILL " & (appProcessId as integer)
  end try
end repeat
delay 0.4
tell application "System Events" to shut down
"#;
    let mut command = Command::new("/usr/bin/osascript");
    command.arg("-e").arg(script);

    spawn_detached(command, "Unable to request shutdown")
}

#[cfg(target_os = "windows")]
fn platform_request_orderly_shutdown() -> Result<(), String> {
    let current_pid = std::process::id();
    let script = format!(
        r#"
$excludePid = {current_pid}
$excludedNames = @("explorer", "ApplicationFrameHost")
Get-Process | Where-Object {{
  $_.MainWindowHandle -ne 0 -and
  $_.Id -ne $excludePid -and
  $excludedNames -notcontains $_.ProcessName
}} | Sort-Object ProcessName | ForEach-Object {{
  try {{ [void]$_.CloseMainWindow() }} catch {{ }}
  Start-Sleep -Milliseconds 450
}}
Start-Sleep -Seconds 2
shutdown.exe /s /t 0 /f
"#
    );
    let mut command = Command::new("powershell.exe");
    command
        .arg("-NoProfile")
        .arg("-ExecutionPolicy")
        .arg("Bypass")
        .arg("-Command")
        .arg(script);

    spawn_detached(command, "Unable to request shutdown")
}

#[cfg(target_os = "linux")]
fn platform_request_orderly_shutdown() -> Result<(), String> {
    let mut command = Command::new("sh");
    command
        .arg("-c")
        .arg("systemctl poweroff || loginctl poweroff || shutdown -h now");

    spawn_detached(command, "Unable to request shutdown")
}

#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
fn platform_request_orderly_shutdown() -> Result<(), String> {
    Err("Shutdown is not supported on this platform".into())
}

fn get_or_create_main_window(app: &tauri::AppHandle) -> Result<tauri::WebviewWindow, String> {
    if let Some(window) = app.get_webview_window(MAIN_WINDOW_LABEL) {
        return Ok(window);
    }

    if let Some(config) = app
        .config()
        .app
        .windows
        .iter()
        .find(|config| config.label == MAIN_WINDOW_LABEL)
    {
        return tauri::WebviewWindowBuilder::from_config(app, config)
            .map_err(|_| "Unable to prepare main window".to_owned())?
            .build()
            .map_err(|_| "Unable to create main window".to_owned());
    }

    tauri::WebviewWindowBuilder::new(
        app,
        MAIN_WINDOW_LABEL,
        tauri::WebviewUrl::App("index.html".into()),
    )
    .title(APP_NAME)
    .inner_size(MAIN_WINDOW_DEFAULT_WIDTH, MAIN_WINDOW_DEFAULT_HEIGHT)
    .min_inner_size(MAIN_WINDOW_MIN_WIDTH, MAIN_WINDOW_MIN_HEIGHT)
    .build()
    .map_err(|_| "Unable to create main window".to_owned())
}

fn show_main_window(window: &tauri::WebviewWindow) -> Result<(), String> {
    let _ = window.set_visible_on_all_workspaces(true);
    let _ = window.unminimize();
    window
        .show()
        .map_err(|_| "Unable to show main window".to_owned())?;
    let _ = window.set_always_on_top(true);
    window
        .set_focus()
        .map_err(|_| "Unable to focus main window".to_owned())?;

    let raised_window = window.clone();
    thread::spawn(move || {
        thread::sleep(Duration::from_millis(320));
        let _ = raised_window.set_always_on_top(false);
        let _ = raised_window.set_visible_on_all_workspaces(false);
    });

    Ok(())
}

fn ensure_directory_path(directory_path: &Path) -> Result<(), String> {
    if directory_path.is_dir() {
        Ok(())
    } else {
        Err("Selected item is not a directory".into())
    }
}

#[cfg(target_os = "macos")]
fn platform_open_directory(directory_path: &Path) -> Result<(), String> {
    ensure_directory_path(directory_path)?;

    Command::new("/usr/bin/open")
        .arg(directory_path)
        .spawn()
        .map(|_| ())
        .map_err(|_| "Unable to open directory".to_owned())
}

#[cfg(target_os = "windows")]
fn platform_open_directory(directory_path: &Path) -> Result<(), String> {
    ensure_directory_path(directory_path)?;

    Command::new("explorer")
        .arg(directory_path)
        .spawn()
        .map(|_| ())
        .map_err(|_| "Unable to open directory".to_owned())
}

#[cfg(target_os = "linux")]
fn platform_open_directory(directory_path: &Path) -> Result<(), String> {
    ensure_directory_path(directory_path)?;

    Command::new("xdg-open")
        .arg(directory_path)
        .spawn()
        .map(|_| ())
        .map_err(|_| "Unable to open directory".to_owned())
}

#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
fn platform_open_directory(directory_path: &Path) -> Result<(), String> {
    ensure_directory_path(directory_path)?;

    Err("Opening directories is not supported on this platform".into())
}

#[cfg(target_os = "macos")]
fn platform_application_picker_options() -> ApplicationPickerOptions {
    ApplicationPickerOptions {
        default_path: existing_directory("/Applications"),
        filters: vec![application_filter("macOS Application", &["app"])],
    }
}

#[cfg(target_os = "windows")]
fn platform_application_picker_options() -> ApplicationPickerOptions {
    let default_path = std::env::var_os("PROGRAMDATA")
        .map(PathBuf::from)
        .and_then(|path| {
            existing_directory(
                path.join("Microsoft")
                    .join("Windows")
                    .join("Start Menu")
                    .join("Programs"),
            )
        })
        .or_else(|| {
            std::env::var_os("ProgramFiles")
                .map(PathBuf::from)
                .and_then(|path| existing_directory(path))
        });

    ApplicationPickerOptions {
        default_path,
        filters: vec![application_filter("Windows Application", &["exe", "lnk"])],
    }
}

#[cfg(target_os = "linux")]
fn platform_application_picker_options() -> ApplicationPickerOptions {
    ApplicationPickerOptions {
        default_path: existing_directory("/usr/share/applications")
            .or_else(|| existing_directory("/usr/local/share/applications")),
        filters: vec![application_filter("Linux Application", &["desktop"])],
    }
}

#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
fn platform_application_picker_options() -> ApplicationPickerOptions {
    ApplicationPickerOptions {
        default_path: None,
        filters: vec![application_filter(
            "Application",
            &["app", "exe", "lnk", "desktop"],
        )],
    }
}

#[cfg(target_os = "macos")]
fn platform_inspect_application(app_path: &Path) -> Result<ApplicationInfo, String> {
    let app_path = PathBuf::from(app_path);

    if !has_path_extension(&app_path, &["app"]) || !app_path.is_dir() {
        return Err("Selected item is not a .app bundle".into());
    }

    let info_plist_path = app_path.join("Contents").join("Info.plist");
    let plist = plist::Value::from_file(&info_plist_path)
        .map_err(|_| "Unable to read application metadata".to_owned())?;
    let name = plist_string_value(&plist, "CFBundleDisplayName")
        .or_else(|| plist_string_value(&plist, "CFBundleName"))
        .unwrap_or_else(|| fallback_app_name(&app_path));
    let icon_data_url =
        icon_path_from_plist(&app_path, &plist).and_then(|path| icns_to_png_data_url(&path));

    Ok(ApplicationInfo {
        name,
        path: app_path.to_string_lossy().into_owned(),
        icon_data_url,
    })
}

#[cfg(target_os = "macos")]
fn platform_launch_application(app_path: &Path) -> Result<(), String> {
    if !has_path_extension(app_path, &["app"]) || !app_path.is_dir() {
        return Err("Selected item is not a .app bundle".into());
    }

    let status = Command::new("/usr/bin/open")
        .arg(app_path)
        .status()
        .map_err(|_| "Unable to launch application".to_owned())?;

    if status.success() {
        Ok(())
    } else {
        Err("Unable to launch application".into())
    }
}

#[cfg(target_os = "windows")]
fn windows_extract_icon_data_url(app_path: &Path) -> Option<String> {
    let wide_path = app_path
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let mut file_info = SHFILEINFOW::default();
    let result = unsafe {
        SHGetFileInfoW(
            wide_path.as_ptr() as PCWSTR,
            0,
            &mut file_info,
            std::mem::size_of::<SHFILEINFOW>() as u32,
            SHGFI_SYSICONINDEX,
        )
    };

    if result != 0 {
        if let Some(icon_data_url) = windows_system_image_list_icon_data_url(file_info.iIcon) {
            return Some(icon_data_url);
        }
    }

    let mut fallback_file_info = SHFILEINFOW::default();
    let fallback_result = unsafe {
        SHGetFileInfoW(
            wide_path.as_ptr() as PCWSTR,
            0,
            &mut fallback_file_info,
            std::mem::size_of::<SHFILEINFOW>() as u32,
            SHGFI_ICON | SHGFI_LARGEICON,
        )
    };

    if fallback_result == 0 || fallback_file_info.hIcon.is_null() {
        return None;
    }

    let icon_data_url = unsafe { windows_hicon_to_png_data_url(fallback_file_info.hIcon, 64) };
    unsafe {
        DestroyIcon(fallback_file_info.hIcon);
    }
    icon_data_url
}

#[cfg(target_os = "windows")]
fn windows_system_image_list_icon_data_url(icon_index: i32) -> Option<String> {
    [SHIL_JUMBO as i32, SHIL_EXTRALARGE as i32]
        .into_iter()
        .find_map(|image_list_size| unsafe {
            let image_list = SHGetImageList::<IImageList>(image_list_size).ok()?;
            let icon = image_list.GetIcon(icon_index, ILD_TRANSPARENT.0).ok()?;
            let icon_data_url = windows_hicon_to_png_data_url(icon.0, 256);
            let _ = DestroyIcon(icon.0);

            icon_data_url
        })
}

#[cfg(target_os = "windows")]
unsafe fn windows_hicon_to_png_data_url(icon: HICON, icon_size: i32) -> Option<String> {
    let screen_dc = unsafe { GetDC(std::ptr::null_mut()) };

    if screen_dc.is_null() {
        return None;
    }

    let memory_dc = unsafe { CreateCompatibleDC(screen_dc) };

    if memory_dc.is_null() {
        unsafe {
            ReleaseDC(std::ptr::null_mut(), screen_dc);
        }
        return None;
    }

    let mut bitmap_bits = std::ptr::null_mut();
    let mut bitmap_info = BITMAPINFO::default();
    bitmap_info.bmiHeader = BITMAPINFOHEADER {
        biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
        biWidth: icon_size,
        biHeight: -icon_size,
        biPlanes: 1,
        biBitCount: 32,
        biCompression: BI_RGB,
        ..Default::default()
    };
    let bitmap = unsafe {
        CreateDIBSection(
            screen_dc,
            &bitmap_info,
            DIB_RGB_COLORS,
            &mut bitmap_bits,
            std::ptr::null_mut(),
            0,
        )
    };
    unsafe {
        ReleaseDC(std::ptr::null_mut(), screen_dc);
    }

    if bitmap.is_null() || bitmap_bits.is_null() {
        unsafe {
            DeleteDC(memory_dc);
        }
        return None;
    }

    let old_bitmap = unsafe { SelectObject(memory_dc, bitmap) };
    let did_draw = unsafe {
        DrawIconEx(
            memory_dc,
            0,
            0,
            icon,
            icon_size,
            icon_size,
            0,
            std::ptr::null_mut(),
            DI_NORMAL,
        )
    };

    if !old_bitmap.is_null() {
        unsafe {
            SelectObject(memory_dc, old_bitmap);
        }
    }
    unsafe {
        DeleteDC(memory_dc);
    }

    if did_draw == 0 {
        unsafe {
            DeleteObject(bitmap);
        }
        return None;
    }

    let icon_size = icon_size as usize;
    let byte_len = icon_size * icon_size * 4;
    let bgra = unsafe { std::slice::from_raw_parts(bitmap_bits.cast::<u8>(), byte_len) };
    let mut rgba = Vec::with_capacity(byte_len);

    for pixel in bgra.chunks_exact(4) {
        rgba.extend_from_slice(&[pixel[2], pixel[1], pixel[0], pixel[3]]);
    }

    if rgba.chunks_exact(4).all(|pixel| pixel[3] == 0) {
        for pixel in rgba.chunks_exact_mut(4) {
            if pixel[0] != 0 || pixel[1] != 0 || pixel[2] != 0 {
                pixel[3] = u8::MAX;
            }
        }
    }

    unsafe {
        DeleteObject(bitmap);
    }

    png_rgba_data_url(&rgba, icon_size as u32, icon_size as u32)
}

#[cfg(target_os = "windows")]
fn png_rgba_data_url(rgba: &[u8], width: u32, height: u32) -> Option<String> {
    let mut png_bytes = Vec::new();
    let mut encoder = png::Encoder::new(&mut png_bytes, width, height);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);

    {
        let mut writer = encoder.write_header().ok()?;
        writer.write_image_data(rgba).ok()?;
    }

    Some(format!(
        "data:image/png;base64,{}",
        general_purpose::STANDARD.encode(png_bytes)
    ))
}

#[cfg(target_os = "windows")]
fn platform_inspect_application(app_path: &Path) -> Result<ApplicationInfo, String> {
    if !has_path_extension(app_path, &["exe", "lnk"]) || !app_path.is_file() {
        return Err("Selected item is not a Windows application or shortcut".into());
    }

    Ok(ApplicationInfo {
        name: fallback_app_name(app_path),
        path: app_path.to_string_lossy().into_owned(),
        icon_data_url: windows_extract_icon_data_url(app_path),
    })
}

#[cfg(target_os = "windows")]
fn platform_launch_application(app_path: &Path) -> Result<(), String> {
    if !has_path_extension(app_path, &["exe", "lnk"]) || !app_path.is_file() {
        return Err("Selected item is not a Windows application or shortcut".into());
    }

    Command::new("cmd")
        .arg("/C")
        .arg("start")
        .arg("")
        .arg(app_path)
        .spawn()
        .map(|_| ())
        .map_err(|_| "Unable to launch application".to_owned())
}

#[cfg(target_os = "linux")]
fn desktop_entry_value(app_path: &Path, key: &str) -> Option<String> {
    let content = fs::read_to_string(app_path).ok()?;
    let mut is_desktop_entry = false;

    for raw_line in content.lines() {
        let line = raw_line.trim();

        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        if line.starts_with('[') && line.ends_with(']') {
            is_desktop_entry = line == "[Desktop Entry]";
            continue;
        }

        if !is_desktop_entry {
            continue;
        }

        let Some((line_key, value)) = line.split_once('=') else {
            continue;
        };

        if line_key == key {
            let value = value.trim();

            if !value.is_empty() {
                return Some(value.to_owned());
            }
        }
    }

    None
}

#[cfg(target_os = "linux")]
fn sanitize_desktop_exec(exec: &str) -> String {
    let mut command = String::with_capacity(exec.len());
    let mut chars = exec.chars();

    while let Some(character) = chars.next() {
        if character != '%' {
            command.push(character);
            continue;
        }

        match chars.next() {
            Some('%') => command.push('%'),
            Some('f' | 'F' | 'u' | 'U' | 'i' | 'c' | 'k') => {}
            Some(_) | None => {}
        }
    }

    command.trim().to_owned()
}

#[cfg(target_os = "linux")]
fn platform_inspect_application(app_path: &Path) -> Result<ApplicationInfo, String> {
    if !has_path_extension(app_path, &["desktop"]) || !app_path.is_file() {
        return Err("Selected item is not a .desktop application".into());
    }

    Ok(ApplicationInfo {
        name: desktop_entry_value(app_path, "Name").unwrap_or_else(|| fallback_app_name(app_path)),
        path: app_path.to_string_lossy().into_owned(),
        icon_data_url: None,
    })
}

#[cfg(target_os = "linux")]
fn platform_launch_application(app_path: &Path) -> Result<(), String> {
    if !has_path_extension(app_path, &["desktop"]) || !app_path.is_file() {
        return Err("Selected item is not a .desktop application".into());
    }

    let exec = desktop_entry_value(app_path, "Exec")
        .map(|value| sanitize_desktop_exec(&value))
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "Unable to read application launch command".to_owned())?;

    Command::new("sh")
        .arg("-c")
        .arg(exec)
        .spawn()
        .map(|_| ())
        .map_err(|_| "Unable to launch application".to_owned())
}

#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
fn platform_inspect_application(app_path: &Path) -> Result<ApplicationInfo, String> {
    if !app_path.exists() {
        return Err("Selected application does not exist".into());
    }

    Ok(ApplicationInfo {
        name: fallback_app_name(app_path),
        path: app_path.to_string_lossy().into_owned(),
        icon_data_url: None,
    })
}

#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
fn platform_launch_application(app_path: &Path) -> Result<(), String> {
    if !app_path.exists() {
        return Err("Selected application does not exist".into());
    }

    Command::new(app_path)
        .spawn()
        .map(|_| ())
        .map_err(|_| "Unable to launch application".to_owned())
}

#[cfg(target_os = "macos")]
fn install_menu(app: &mut tauri::App) -> tauri::Result<()> {
    let about = AboutMetadata {
        name: Some(APP_NAME.into()),
        version: Some(env!("CARGO_PKG_VERSION").into()),
        copyright: Some("Copyright 2026 InchSpace".into()),
        ..Default::default()
    };

    let app_menu = SubmenuBuilder::new(app, "InchSpace")
        .about(Some(about))
        .separator()
        .services()
        .separator()
        .hide()
        .hide_others()
        .show_all()
        .separator()
        .quit()
        .build()?;

    let file_menu = SubmenuBuilder::new(app, "File")
        .text("new_space", "New Space")
        .separator()
        .close_window()
        .build()?;

    let edit_menu = SubmenuBuilder::new(app, "Edit")
        .undo()
        .redo()
        .separator()
        .cut()
        .copy()
        .paste()
        .select_all()
        .build()?;

    let view_menu = SubmenuBuilder::new(app, "View").fullscreen().build()?;

    let window_menu = SubmenuBuilder::new(app, "Window")
        .minimize()
        .maximize()
        .separator()
        .bring_all_to_front()
        .build()?;

    let help_menu = SubmenuBuilder::new(app, "Help")
        .text("open_help", "InchSpace Help")
        .build()?;

    let menu = MenuBuilder::new(app)
        .items(&[
            &app_menu,
            &file_menu,
            &edit_menu,
            &view_menu,
            &window_menu,
            &help_menu,
        ])
        .build()?;

    app.set_menu(menu)?;
    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn install_menu(app: &mut tauri::App) -> tauri::Result<()> {
    let file_menu = SubmenuBuilder::new(app, "File")
        .text("new_space", "New Space")
        .separator()
        .text("close_window", "Close Window")
        .text("quit_app", "Quit")
        .build()?;

    let edit_menu = SubmenuBuilder::new(app, "Edit")
        .cut()
        .copy()
        .paste()
        .select_all()
        .build()?;

    let view_menu = SubmenuBuilder::new(app, "View")
        .text("toggle_fullscreen", "Toggle Full Screen")
        .build()?;

    let help_menu = SubmenuBuilder::new(app, "Help")
        .about(Some(AboutMetadata {
            name: Some(APP_NAME.into()),
            version: Some(env!("CARGO_PKG_VERSION").into()),
            comments: Some("A cross-platform desktop workspace.".into()),
            copyright: Some("Copyright 2026 InchSpace".into()),
            ..Default::default()
        }))
        .build()?;

    let menu = MenuBuilder::new(app)
        .items(&[&file_menu, &edit_menu, &view_menu, &help_menu])
        .build()?;

    app.set_menu(menu)?;
    Ok(())
}

fn handle_menu_event(app: &tauri::AppHandle, id: &str) {
    match id {
        "close_window" => {
            if let Some(window) = app.get_webview_window(MAIN_WINDOW_LABEL) {
                let _ = window.close();
            }
        }
        "quit_app" => app.exit(0),
        "toggle_fullscreen" => {
            if let Some(window) = app.get_webview_window(MAIN_WINDOW_LABEL) {
                if let Ok(is_fullscreen) = window.is_fullscreen() {
                    let _ = window.set_fullscreen(!is_fullscreen);
                }
            }
        }
        _ => {}
    }
}

fn handle_window_event(window: &tauri::Window, event: &tauri::WindowEvent) {
    if window.label() != MAIN_WINDOW_LABEL {
        return;
    }

    if let tauri::WindowEvent::CloseRequested { api, .. } = event {
        api.prevent_close();
        let _ = window.hide();
    }
}

fn floating_ball_initial_position(app: &tauri::App) -> (f64, f64) {
    let monitor = app
        .get_webview_window(MAIN_WINDOW_LABEL)
        .and_then(|window| window.current_monitor().ok().flatten())
        .or_else(|| app.primary_monitor().ok().flatten());

    let Some(monitor) = monitor else {
        return (24.0, 240.0);
    };

    let scale_factor = monitor.scale_factor().max(1.0);
    let work_area = monitor.work_area();
    let work_area_left = f64::from(work_area.position.x);
    let work_area_top = f64::from(work_area.position.y);
    let work_area_width = f64::from(work_area.size.width);
    let work_area_height = f64::from(work_area.size.height);
    let ball_size = FLOATING_BALL_SIZE * scale_factor;
    let margin = FLOATING_BALL_MARGIN * scale_factor;
    let x = (work_area_left + work_area_width - ball_size - margin) / scale_factor;
    let y = (work_area_top + (work_area_height - ball_size).max(0.0) / 2.0) / scale_factor;

    (x, y)
}

fn install_floating_ball(app: &tauri::App) -> tauri::Result<()> {
    if app.get_webview_window(FLOATING_BALL_WINDOW_LABEL).is_some() {
        return Ok(());
    }

    let (x, y) = floating_ball_initial_position(app);

    tauri::WebviewWindowBuilder::new(
        app,
        FLOATING_BALL_WINDOW_LABEL,
        tauri::WebviewUrl::App("index.html".into()),
    )
    .title("方寸悬浮球")
    .inner_size(FLOATING_BALL_SIZE, FLOATING_BALL_SIZE)
    .min_inner_size(FLOATING_BALL_SIZE, FLOATING_BALL_SIZE)
    .max_inner_size(FLOATING_BALL_SIZE, FLOATING_BALL_SIZE)
    .position(x, y)
    .decorations(false)
    .resizable(false)
    .maximizable(false)
    .minimizable(false)
    .closable(false)
    .always_on_top(true)
    .visible_on_all_workspaces(true)
    .skip_taskbar(true)
    .focused(false)
    .transparent(true)
    .background_color(tauri::utils::config::Color(0, 0, 0, 0))
    .shadow(false)
    .accept_first_mouse(true)
    .build()?;

    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(Mutex::new(SystemMetricsSampler::new()))
        .invoke_handler(tauri::generate_handler![
            activate_main_window,
            application_picker_options,
            inspect_application,
            inspect_directory,
            launch_application,
            open_directory,
            request_orderly_shutdown,
            set_dock_icon_visible,
            system_metrics
        ])
        .plugin(tauri_plugin_dialog::init())
        .on_window_event(handle_window_event)
        .setup(|app| {
            install_menu(app)?;
            install_floating_ball(app)?;
            app.on_menu_event(|app_handle, event| {
                handle_menu_event(app_handle, event.id().as_ref());
            });
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running InchSpace");
}

#[cfg(all(test, target_os = "windows"))]
mod tests {
    use super::*;

    #[test]
    fn extracts_windows_executable_icon() {
        let current_exe = std::env::current_exe().expect("test executable path should be available");
        let icon_data_url =
            windows_extract_icon_data_url(&current_exe).expect("Windows should return an icon");
        let png_base64 = icon_data_url
            .strip_prefix("data:image/png;base64,")
            .expect("icon should be returned as a PNG data URL");
        let png_bytes = general_purpose::STANDARD
            .decode(png_base64)
            .expect("icon PNG data should be valid base64");

        assert!(png_bytes.starts_with(b"\x89PNG\r\n\x1A\n"));
        assert_eq!(
            u32::from_be_bytes(png_bytes[16..20].try_into().expect("PNG width bytes")),
            256
        );
        assert_eq!(
            u32::from_be_bytes(png_bytes[20..24].try_into().expect("PNG height bytes")),
            256
        );
    }
}
