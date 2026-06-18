use crate::extensions::platform;
use std::env;
use std::path::PathBuf;

pub struct Runtime;

impl Runtime {
    pub fn root_dir() -> PathBuf {
        env::var("NOVEL_CORE_ROOT_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| std::env::current_dir().unwrap())
    }

    pub fn script_dir() -> PathBuf {
        env::var("NOVEL_CORE_SCRIPT_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from(env!("CARGO_MANIFEST_DIR")))
    }

    pub fn tmp_dir() -> PathBuf {
        env::var("NOVEL_CORE_TMP_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| {
                let system_tmp = platform::safe_system_tmp_dir();
                let dir = system_tmp.join("novel_core").join("tmp");
                if std::fs::create_dir_all(&dir).is_ok() {
                    dir
                } else {
                    Self::root_dir().join(".novel_core").join("tmp")
                }
            })
    }
}
