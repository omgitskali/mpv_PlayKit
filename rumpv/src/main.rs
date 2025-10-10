#!/usr/bin/env rust

#![windows_subsystem = "windows"]

use std::env;
use std::io::{self, Write};
use std::path::Path;
use std::process::Command;
use windows::core::*;
use windows::Win32::Storage::FileSystem::{
    CreateFileW, FILE_GENERIC_READ, FILE_GENERIC_WRITE,
    OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, FILE_SHARE_MODE,
};
use windows::Win32::UI::WindowsAndMessaging::*;
use std::os::windows::io::FromRawHandle;

fn read_conf() -> (String, String) {
    let conf_path = if let Ok(exe_path) = env::current_exe() {
        exe_path.parent()
            .map(|p| p.join("umpv.conf"))
            .unwrap_or_else(|| Path::new("umpv.conf").to_path_buf())
    } else {
        Path::new("umpv.conf").to_path_buf()
    };

    let txt = std::fs::read_to_string(&conf_path).unwrap_or_default();

    let mut socket = None;
    let mut flag   = None;

    for line in txt.lines() {
        if line.trim().is_empty() || line.starts_with('[') { continue; }
        if let Some((k, v)) = line.split_once('=') {
            let k = k.trim();
            let v = v.trim();
            match k {
                "Socket_Path"   => socket = Some(v.to_string()),
                "Loadfile_Flag" => flag   = Some(v.to_string()),
                _ => {}
            }
        }
    }

    (
        socket.unwrap_or(r"\\.\pipe\umpv".to_string()),
        flag.unwrap_or("replace".to_string()),
    )
}

fn is_url(filename: &str) -> bool {
    if let Some((prefix, _)) = filename.split_once("://") {
        prefix.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
    } else {
        false
    }
}

fn escape_mpv_string(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
}

fn send_files_to_mpv(pipe: &mut impl Write, files: &[String], loadfile_flag: &str) -> io::Result<()> {
    for file in files {
        let escaped = escape_mpv_string(file);
        let command = format!("raw loadfile \"{}\" \"{}\"\n", escaped, loadfile_flag);
        pipe.write_all(command.as_bytes())?;
    }
    pipe.flush()?;
    Ok(())
}

fn bring_mpv_to_foreground() {
    unsafe {
        let class_name = w!("mpv");

        if let Ok(hwnd) = FindWindowW(class_name, None) {
            if !hwnd.0.is_null() {
                let _ = ShowWindow(hwnd, SW_RESTORE);
                let _ = SetForegroundWindow(hwnd);
                let _ = BringWindowToTop(hwnd);
                let _ = SetWindowPos(
                    hwnd,
                    Some(HWND_TOP),
                    0, 0, 0, 0,
                    SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW,
                );
            }
        }
    }
}

fn start_mpv(files: &[String], socket_path: &str) -> io::Result<()> {
    let mpv_exe = env::var("MPV").unwrap_or_else(|_| "mpv.exe".to_string());

    let mut cmd = Command::new(&mpv_exe);
    cmd.arg(format!("--input-ipc-server={}", socket_path));
    cmd.arg("--");
    cmd.args(files);

    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x00000200;
        cmd.creation_flags(CREATE_NEW_PROCESS_GROUP);
    }

    cmd.spawn()?;

    std::thread::sleep(std::time::Duration::from_millis(500));

    Ok(())
}

fn try_connect_to_mpv(socket_path: &str, files: &[String], loadfile_flag: &str) -> io::Result<()> {
    unsafe {
        let pipe_name: Vec<u16> = socket_path.encode_utf16().chain(std::iter::once(0)).collect();

        let handle = CreateFileW(
            PCWSTR(pipe_name.as_ptr()),
            FILE_GENERIC_READ.0 | FILE_GENERIC_WRITE.0,
            FILE_SHARE_MODE(0x03),
            None,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            None,
        )?;

        let mut file = std::fs::File::from_raw_handle(handle.0 as _);

        if !files.is_empty() {
            send_files_to_mpv(&mut file, files, loadfile_flag)?;
        }

        bring_mpv_to_foreground();

        Ok(())
    }
}

fn main() -> io::Result<()> {
    let (socket_path, loadfile_flag) = read_conf();
    //eprintln!(">>> socket: {:?}", socket_path);
    //eprintln!(">>> flag  : {:?}", loadfile_flag);

    let args: Vec<String> = env::args().skip(1).collect();

    let files: Vec<String> = args
        .iter()
        .map(|f| {
            if is_url(f) {
                f.clone()
            } else {
                Path::new(f)
                    .canonicalize()
                    .ok()
                    .and_then(|p| p.to_str().map(String::from))
                    .unwrap_or_else(|| f.clone())
            }
        })
        .collect();

    match try_connect_to_mpv(&socket_path, &files, &loadfile_flag) {
        Ok(_) => Ok(()),
        Err(_) => start_mpv(&files, &socket_path),
    }
}

