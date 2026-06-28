#[cfg(any(target_os = "macos", target_os = "windows"))]
use base64::{engine::general_purpose, Engine as _};
#[cfg(any(target_os = "macos", target_os = "linux"))]
use std::fs;
#[cfg(target_os = "windows")]
use std::os::windows::ffi::OsStrExt;
#[cfg(target_os = "macos")]
use std::time::{SystemTime, UNIX_EPOCH};
use serde::Serialize;
use std::{
    path::{Path, PathBuf},
    process::Command,
};
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

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ApplicationInfo {
    name: String,
    path: String,
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
fn launch_application(app_path: String) -> Result<(), String> {
    let app_path = PathBuf::from(app_path);

    platform_launch_application(&app_path)
}

#[tauri::command]
fn open_directory(directory_path: String) -> Result<(), String> {
    let directory_path = PathBuf::from(directory_path);

    platform_open_directory(&directory_path)
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
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.close();
            }
        }
        "quit_app" => app.exit(0),
        "toggle_fullscreen" => {
            if let Some(window) = app.get_webview_window("main") {
                if let Ok(is_fullscreen) = window.is_fullscreen() {
                    let _ = window.set_fullscreen(!is_fullscreen);
                }
            }
        }
        _ => {}
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            application_picker_options,
            inspect_application,
            launch_application,
            open_directory
        ])
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            install_menu(app)?;
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
