use std::io;

pub(crate) fn configure_pty_backend() -> io::Result<()> {
    let exe = std::env::current_exe()?;
    let parent = exe.parent().ok_or_else(|| {
        io::Error::other(format!(
            "executable has no parent directory: {}",
            exe.display()
        ))
    })?;
    let dll = parent.join("conpty.dll");
    let host = parent.join("OpenConsole.exe");
    let app_local = (dll.is_file() && host.is_file()).then_some(dll);

    portable_pty::win::configure_conpty(app_local).map_err(|err| io::Error::other(err.to_string()))
}
