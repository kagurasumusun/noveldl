use std::thread;
use std::time::{Duration, Instant};

pub struct RateLimiter {
    interval: Duration,
    steps_wait: Duration,
    wait_counter: u64,
    max_steps_wait_time: Duration,
    last: Instant,
}

impl RateLimiter {
    pub fn new(interval_ms: u64, steps_wait_secs: u64) -> Self {
        let interval = Duration::from_millis(interval_ms);
        let steps_wait = Duration::from_secs(steps_wait_secs);
        let max_steps_wait_time = if steps_wait > interval {
            steps_wait
        } else {
            interval
        };
        Self {
            interval,
            steps_wait,
            wait_counter: 0,
            max_steps_wait_time,
            last: Instant::now() - Duration::from_secs(20),
        }
    }

    pub fn new_millis(ms: u64) -> Self {
        Self::new(ms, 5)
    }

    pub fn wait_for_download(&mut self, download_wait_steps: u64) {
        if self.last.elapsed() > self.max_steps_wait_time {
            self.wait_counter = 0;
        }

        if download_wait_steps > 0
            && self.wait_counter % download_wait_steps == 0
            && self.wait_counter >= download_wait_steps
        {
            thread::sleep(self.max_steps_wait_time);
        } else if self.wait_counter > 0 {
            thread::sleep(self.interval);
        }

        self.wait_counter += 1;
        self.last = Instant::now();
    }

    pub fn wait(&mut self) {
        self.wait_for_download(0)
    }

    pub fn wait_interruptible<F>(&mut self, mut should_stop: F) -> bool
    where
        F: FnMut() -> bool,
    {
        if should_stop() {
            return false;
        }
        if self.last.elapsed() > self.max_steps_wait_time {
            self.wait_counter = 0;
        }

        let sleep_for = if self.wait_counter > 0 {
            self.interval
        } else {
            Duration::ZERO
        };
        if !sleep_for.is_zero() && interruptible_sleep(sleep_for, &mut should_stop) {
            return false;
        }

        self.wait_counter += 1;
        self.last = Instant::now();
        !should_stop()
    }

    pub fn reset(&mut self) {
        self.wait_counter = 0;
        self.last = Instant::now() - Duration::from_secs(20);
    }

    pub fn steps_wait(&self) -> Duration {
        self.steps_wait
    }
}

fn interruptible_sleep<F>(duration: Duration, should_stop: &mut F) -> bool
where
    F: FnMut() -> bool,
{
    let deadline = Instant::now() + duration;
    while Instant::now() < deadline {
        if should_stop() {
            return true;
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        thread::sleep(remaining.min(Duration::from_millis(100)));
    }
    should_stop()
}
