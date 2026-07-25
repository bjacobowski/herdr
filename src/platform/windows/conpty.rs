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
    let app_local = match (dll.is_file(), host.is_file()) {
        (true, true) => Some(dll),
        (false, false) => None,
        (true, false) => {
            return Err(io::Error::other(format!(
                "app-local ConPTY runtime is missing {}",
                host.display()
            )));
        }
        (false, true) => {
            return Err(io::Error::other(format!(
                "app-local ConPTY runtime is missing {}",
                dll.display()
            )));
        }
    };

    portable_pty::win::configure_conpty(app_local).map_err(|err| io::Error::other(err.to_string()))
}
