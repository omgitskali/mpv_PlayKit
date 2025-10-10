fn main() {
    #[cfg(windows)]
    {
        let mut res = winres::WindowsResource::new();

        res.set_icon("../installer/mpv-icon.ico");

        res.set("ProductName", "umpv");
        res.set("FileDescription", "Rumpv");
        res.set("CompanyName", "");
        res.set("LegalCopyright", "");
        res.set("OriginalFilename", "umpv.exe");

        if let Err(e) = res.compile() {
            eprintln!("警告: 无法嵌入图标资源: {}", e);
            eprintln!("请确保 mpv-icon.ico 文件存在");
        }
    }
}
