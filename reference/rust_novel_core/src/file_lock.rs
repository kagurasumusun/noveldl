use anyhow::{Result, anyhow};
use fs2::FileExt;
use std::fs::OpenOptions;
use std::path::Path;
use std::thread;
use std::time::{Duration, Instant};

pub fn with_exclusive_lock<T>(path: &Path, f: impl FnOnce() -> Result<T>) -> Result<T> {
    with_exclusive_lock_timeout(path, Duration::from_secs(30), f)
}

pub fn with_exclusive_lock_timeout<T>(
    path: &Path,
    timeout: Duration,
    f: impl FnOnce() -> Result<T>,
) -> Result<T> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let file = OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .open(path)?;

    let start = Instant::now();
    loop {
        match file.try_lock_exclusive() {
            Ok(()) => break,
            Err(_) if start.elapsed() >= timeout => {
                return Err(anyhow!("lock acquisition timeout: {}", path.display()));
            }
            Err(_) => thread::sleep(Duration::from_millis(10)),
        }
    }

    let out = f();
    file.unlock()?;
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Barrier};

    #[test]
    fn exclusive_lock_serializes_access() {
        let lock_path = std::env::temp_dir().join("novel_core_lock_test.lock");
        let _ = std::fs::remove_file(&lock_path);

        let barrier = Arc::new(Barrier::new(2));
        let b2 = barrier.clone();
        let lp2 = lock_path.clone();

        let holder = std::thread::spawn(move || {
            with_exclusive_lock_timeout(&lp2, Duration::from_secs(1), || {
                b2.wait();
                std::thread::sleep(Duration::from_millis(150));
                Ok(())
            })
            .expect("holder lock should succeed");
        });

        barrier.wait();
        let start = Instant::now();
        with_exclusive_lock_timeout(&lock_path, Duration::from_secs(1), || Ok(()))
            .expect("contender lock should eventually succeed");
        let waited = start.elapsed();

        holder.join().expect("holder thread should join");
        assert!(waited >= Duration::from_millis(120));
    }
}
