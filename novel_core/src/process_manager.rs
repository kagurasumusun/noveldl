use anyhow::{Result, anyhow};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::fs;
use std::net::TcpListener;
use std::path::PathBuf;
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant};

use crate::runtime::Runtime;

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ProcessMeta {
    pub pid: u32,
    pub ppid: Option<u32>,
    pub started_at: String,
    pub platform: String,
    pub service: String,
    pub port: Option<u16>,
}

#[derive(Debug)]
pub struct ProcessManager {
    service_name: String,
}

impl ProcessManager {
    pub fn new(service_name: impl Into<String>) -> Self {
        Self {
            service_name: service_name.into(),
        }
    }
    fn pid_dir(&self) -> PathBuf {
        Runtime::tmp_dir().join("pids")
    }
    fn pid_path(&self) -> PathBuf {
        self.pid_dir().join(format!("{}.pid", self.service_name))
    }
    fn port_path(&self) -> PathBuf {
        self.pid_dir().join(format!("{}.port", self.service_name))
    }

    pub fn register(&self, meta: &ProcessMeta) -> Result<()> {
        fs::create_dir_all(self.pid_dir())?;
        fs::write(self.pid_path(), serde_json::to_vec_pretty(meta)?)?;
        if let Some(port) = meta.port {
            fs::write(self.port_path(), port.to_string())?;
        }
        Ok(())
    }

    pub fn register_current_process(&self, port: Option<u16>) -> Result<ProcessMeta> {
        let meta = ProcessMeta {
            pid: std::process::id(),
            ppid: None,
            started_at: Utc::now().to_rfc3339(),
            platform: std::env::consts::OS.to_string(),
            service: self.service_name.clone(),
            port,
        };
        self.register(&meta)?;
        Ok(meta)
    }

    pub fn read_process_info(&self) -> Result<Option<ProcessMeta>> {
        let path = self.pid_path();
        if !path.exists() {
            return Ok(None);
        }
        let raw = fs::read_to_string(path)?;
        if let Ok(meta) = serde_json::from_str::<ProcessMeta>(&raw) {
            return Ok(Some(meta));
        }
        if let Ok(pid) = raw.trim().parse::<u32>() {
            return Ok(Some(ProcessMeta {
                pid,
                ppid: None,
                started_at: String::new(),
                platform: std::env::consts::OS.to_string(),
                service: self.service_name.clone(),
                port: None,
            }));
        }
        Ok(None)
    }

    pub fn process_running(&self, pid: u32) -> bool {
        if cfg!(windows) {
            Command::new("cmd")
                .args(["/C", &format!("tasklist /FI \"PID eq {}\"", pid)])
                .output()
                .map(|o| String::from_utf8_lossy(&o.stdout).contains(&pid.to_string()))
                .unwrap_or(false)
        } else {
            Command::new("kill")
                .args(["-0", &pid.to_string()])
                .status()
                .map(|s| s.success())
                .unwrap_or(false)
        }
    }

    pub fn cleanup_stale_process(&self) -> Result<()> {
        if let Some(info) = self.read_process_info()? {
            if !self.process_running(info.pid) {
                self.cleanup_files()?;
                return Ok(());
            }
            return Err(anyhow!(
                "service '{}' is already running with pid {}",
                self.service_name,
                info.pid
            ));
        }
        Ok(())
    }

    pub fn stop_process(&self, timeout: Duration) -> Result<bool> {
        let Some(info) = self.read_process_info()? else {
            return Ok(false);
        };
        let pid = info.pid;
        if !self.process_running(pid) {
            self.cleanup_files()?;
            return Ok(false);
        }
        if cfg!(windows) {
            let _ = Command::new("taskkill")
                .args(["/PID", &pid.to_string(), "/T", "/F"])
                .status();
            thread::sleep(Duration::from_millis(500));
        } else {
            let _ = Command::new("kill")
                .args(["-TERM", &pid.to_string()])
                .status();
            let deadline = Instant::now() + timeout;
            while Instant::now() < deadline {
                if !self.process_running(pid) {
                    break;
                }
                thread::sleep(Duration::from_millis(100));
            }
            if self.process_running(pid) {
                let _ = Command::new("kill")
                    .args(["-KILL", &pid.to_string()])
                    .status();
            }
        }
        self.cleanup_files()?;
        Ok(true)
    }

    pub fn stop_process_detailed(&self, timeout: Duration) -> Result<String> {
        let Some(info) = self.read_process_info()? else {
            return Ok("no process metadata".to_string());
        };
        let pid = info.pid;
        if !self.process_running(pid) {
            self.cleanup_files()?;
            return Ok(format!("process {} already stopped", pid));
        }
        let stopped = self.stop_process(timeout)?;
        if stopped {
            Ok(format!(
                "stopped process {} for service {}",
                pid, self.service_name
            ))
        } else {
            Ok(format!("failed to stop process {}", pid))
        }
    }

    pub fn find_process_using_port(&self, port: u16) -> Option<String> {
        if cfg!(target_os = "linux") {
            Self::run_and_trim(
                "sh",
                &[
                    "-c",
                    &format!("lsof -i :{} -t 2>/dev/null | head -n1", port),
                ],
            )
            .and_then(|pid| {
                if pid.is_empty() {
                    None
                } else {
                    Self::run_and_trim(
                        "sh",
                        &[
                            "-c",
                            &format!(
                                "ps -p {} -o pid,ppid,user,command --no-headers 2>/dev/null",
                                pid
                            ),
                        ],
                    )
                    .or(Some(format!("PID: {}", pid)))
                }
            })
        } else if cfg!(target_os = "macos") {
            Self::run_and_trim(
                "sh",
                &[
                    "-c",
                    &format!("lsof -i :{} -t 2>/dev/null | head -n1", port),
                ],
            )
            .and_then(|pid| {
                if pid.is_empty() {
                    None
                } else {
                    Self::run_and_trim(
                        "sh",
                        &[
                            "-c",
                            &format!(
                                "ps -p {} -o pid,ppid,user,command 2>/dev/null | tail -n +2",
                                pid
                            ),
                        ],
                    )
                    .or(Some(format!("PID: {}", pid)))
                }
            })
        } else if cfg!(windows) {
            Self::run_and_trim("cmd", &["/C", &format!("netstat -ano | findstr :{}", port)])
        } else {
            None
        }
    }

    fn run_and_trim(cmd: &str, args: &[&str]) -> Option<String> {
        Command::new(cmd).args(args).output().ok().and_then(|o| {
            let s = String::from_utf8_lossy(&o.stdout).trim().to_string();
            if s.is_empty() { None } else { Some(s) }
        })
    }

    pub fn cleanup_files(&self) -> Result<()> {
        let _ = fs::remove_file(self.pid_path());
        let _ = fs::remove_file(self.port_path());
        Ok(())
    }
    pub fn port_in_use(&self, port: u16, host: &str) -> bool {
        TcpListener::bind((host, port)).is_err()
    }
    pub fn check_port_conflict(&self, port: u16, host: &str) -> Result<()> {
        if self.port_in_use(port, host) {
            Err(anyhow!("port {} is already in use", port))
        } else {
            Ok(())
        }
    }

    pub fn check_port_conflict_with_message(&self, port: u16, host: &str) -> Result<()> {
        if !self.port_in_use(port, host) {
            return Ok(());
        }
        let detail = self
            .find_process_using_port(port)
            .unwrap_or_else(|| "(process detail unavailable)".to_string());
        Err(anyhow!(
            "Port {} is already in use.\n{}\nPlease stop the process, choose another port, or run process cleanup.",
            port,
            detail
        ))
    }
}
