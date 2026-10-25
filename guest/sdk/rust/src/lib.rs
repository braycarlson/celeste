use std::collections::HashSet;
use std::fmt::Write as _;
use std::fs::{File, OpenOptions};
use std::io;
use std::os::unix::fs::{FileExt, OpenOptionsExt};
use std::process::{Command, Stdio};
use std::thread;
use std::time::Duration;

const AGENT_MODULE: &str = "dst.agent";
const CONSOLE_PATH: &str = "/dev/console";
const CONTROL_EVENT_DUE: u8 = 5;
const CONTROL_EVENT_WAIT: u8 = 3;
const CONTROL_POWER_LOSS: u8 = 1;
const CONTROL_PORT: u64 = 0x505;
const CONTROL_READY: u8 = 2;
const DETAILS_SEPARATOR: &str = " | ";
const DIRECTIONS: [&str; 3] = ["both", "requests", "replies"];
const DRAW_LATCH: u8 = 1;
const DRAW_PORT: u64 = 0x5e0;
const ENTROPY_PATH: &str = "/dev/urandom";

const EVENT_FIELDS: [&str; 22] = [
    "kind",
    "delay_ns",
    "duration_ns",
    "target",
    "choice",
    "restart",
    "restart_delay_ns",
    "clock_jump_ns",
    "clock_slew_ppm",
    "disk_full_slack_kib",
    "memory_immune",
    "memory_kills",
    "network_delay_ns",
    "network_direction",
    "network_jitter_ns",
    "network_link",
    "network_loss_permille",
    "network_peers",
    "network_reorder_permille",
    "pause_tree",
    "thread_choice",
    "throttle_permille",
];

const EVENT_MAGIC: u64 = 0x31544e5645545344;
const EVENT_PORT: u64 = 0x510;
const EVENT_SIGNED: [usize; 2] = [7, 8];
const GUIDANCE_PORT: u64 = 0x5f4;

const KINDS: [&str; 10] = [
    "none",
    "clock_jump",
    "clock_slew",
    "disk_full",
    "kill",
    "memory",
    "network",
    "pause",
    "thread_pause",
    "throttle",
];

const LINKS: [&str; 4] = ["none", "postgres", "rabbitmq", "redis"];
const LOCK_PATH: &str = "/dev/shm/dst-draw";
const MESSAGE_MAX: usize = 1024;
const O_NOCTTY: i32 = 0o400;
const OOM_IMMUNE: &str = "-1000";
const OOM_PATH: &str = "/proc/self/oom_score_adj";
const PORT_PATH: &str = "/dev/port";
const QUIET_PATH: &str = "/dev/shm/dst-quiet";
const QUIET_POLL: Duration = Duration::from_millis(50);
const QUIET_POLLS_MAX: u32 = 12_000;
const RESEED_CRNG: u64 = 0x5207;
const SEED_PORT: u64 = 0x508;

const TARGETS: [&str; 10] = [
    "none",
    "celery_worker",
    "gunicorn_worker",
    "postgres_backend",
    "postmaster",
    "rabbitmq",
    "redis_server",
    "workload",
    "containerd",
    "dockerd",
];

unsafe extern "C" {
    fn ioctl(fd: i32, request: u64, ...) -> i32;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Event {
    pub words: [u64; 22],
}

#[derive(Debug)]
pub enum Error {
    Agent(io::Error),
    Console(io::Error),
    EventField(String),
    EventMagic(u64),
    Port(io::Error),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Always,
    Maximize,
    Reachable,
    Sometimes,
    Unreachable,
}

#[derive(Default)]
pub struct Reporter {
    seen: HashSet<String>,
}

impl Event {
    pub fn kind(&self) -> u64 {
        self.words[0]
    }

    pub fn delay_ns(&self) -> u64 {
        self.words[1]
    }

    pub fn render(&self) -> Result<String, Error> {
        let mut text = String::new();

        for (index, name) in EVENT_FIELDS.iter().enumerate() {
            let word = self.words[index];
            let separator = if index == 0 { "" } else { " " };
            let names = event_names(name);

            match names {
                Some(table) => {
                    let position = usize::try_from(word).unwrap_or(usize::MAX);

                    let value = table
                        .get(position)
                        .ok_or_else(|| Error::EventField(name.to_string()))?;

                    write!(text, "{separator}{name}={value}").expect("a string write cannot fail");
                }
                None if EVENT_SIGNED.contains(&index) => {
                    write!(text, "{separator}{name}={}", word as i64)
                        .expect("a string write cannot fail");
                }
                None => {
                    write!(text, "{separator}{name}={word}").expect("a string write cannot fail");
                }
            }
        }

        Ok(text)
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Agent(error) => write!(formatter, "the agent could not start: {error}"),
            Error::Console(error) => write!(formatter, "the console refused a line: {error}"),
            Error::EventField(name) => write!(formatter, "the event field {name} is out of range"),
            Error::EventMagic(magic) => write!(formatter, "the event ports read magic {magic:#x}"),
            Error::Port(error) => write!(formatter, "a port exchange failed: {error}"),
        }
    }
}

impl std::error::Error for Error {}

impl Kind {
    fn name(self) -> &'static str {
        match self {
            Kind::Always => "always",
            Kind::Maximize => "maximize",
            Kind::Reachable => "reachable",
            Kind::Sometimes => "sometimes",
            Kind::Unreachable => "unreachable",
        }
    }
}

impl Reporter {
    fn report(&mut self, line: String) -> Result<(), Error> {
        if self.seen.contains(&line) {
            return Ok(());
        }

        console(&line)?;
        self.seen.insert(line);

        Ok(())
    }

    pub fn always(&mut self, condition: bool, message: &str, details: &str) -> Result<(), Error> {
        let outcome = if condition { "PASS" } else { "FAIL" };
        let suffix = if condition { "" } else { details };
        let line = line_build("DST ALWAYS ", outcome, message, suffix);

        self.report(line)
    }

    pub fn eventually(
        &mut self,
        condition: bool,
        message: &str,
        details: &str,
    ) -> Result<(), Error> {
        self.always(condition, message, details)?;
        console(if condition { "DST EVENTUALLY PASS" } else { "DST EVENTUALLY FAIL" })
    }

    pub fn never(&mut self, message: &str, details: &str) -> Result<(), Error> {
        self.report(line_build("DST UNREACHABLE ", "", message, details))
    }

    pub fn reachable(&mut self, message: &str) -> Result<(), Error> {
        self.report(line_build("DST REACHABLE ", "", message, ""))
    }

    pub fn sometimes(&mut self, condition: bool, message: &str) -> Result<(), Error> {
        if !condition {
            return Ok(());
        }

        self.report(line_build("DST SOMETIMES ", "", message, ""))
    }
}

fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = 0xffff_ffffu32;

    for byte in bytes {
        crc ^= u32::from(*byte);

        for _ in 0..8 {
            crc = (crc >> 1) ^ (0xedb8_8320 & 0u32.wrapping_sub(crc & 1));
        }
    }

    crc ^ 0xffff_ffff
}

fn event_names(name: &str) -> Option<&'static [&'static str]> {
    match name {
        "kind" => Some(&KINDS),
        "target" => Some(&TARGETS),
        "network_direction" => Some(&DIRECTIONS),
        "network_link" => Some(&LINKS),
        _ => None,
    }
}

fn event_read(command: u8) -> Result<Event, Error> {
    let mut bytes = [0u8; 23 * 8];

    exchange(CONTROL_PORT, command, EVENT_PORT, &mut bytes)?;

    let magic = u64::from_le_bytes(bytes[..8].try_into().expect("eight bytes"));

    if magic != EVENT_MAGIC {
        return Err(Error::EventMagic(magic));
    }

    let mut words = [0u64; 22];

    for (index, word) in words.iter_mut().enumerate() {
        let start = (index + 1) * 8;

        *word = u64::from_le_bytes(bytes[start..start + 8].try_into().expect("eight bytes"));
    }

    Ok(Event { words })
}

fn exchange(command_port: u64, command: u8, read_port: u64, out: &mut [u8]) -> Result<(), Error> {
    let lock = lock_take()?;

    let port = OpenOptions::new()
        .read(true)
        .write(true)
        .open(PORT_PATH)
        .map_err(Error::Port)?;

    port.write_all_at(&[command], command_port).map_err(Error::Port)?;
    port.read_exact_at(out, read_port).map_err(Error::Port)?;

    drop(lock);

    Ok(())
}

fn line_build(prefix: &str, outcome: &str, message: &str, details: &str) -> String {
    let mut line = String::from(prefix);

    if !outcome.is_empty() {
        line.push_str(outcome);
        line.push(' ');
    }

    line.push_str(&message_clean(message));

    if !details.is_empty() {
        line.push_str(DETAILS_SEPARATOR);
        line.push_str(details);
    }

    line
}

fn lock_take() -> Result<File, Error> {
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(LOCK_PATH)
        .map_err(Error::Port)?;

    lock.lock().map_err(Error::Port)?;

    Ok(lock)
}

fn message_clean(message: &str) -> String {
    let words: Vec<&str> = message.split_whitespace().collect();
    let joined = words.join(" ");

    assert!(joined.len() <= MESSAGE_MAX, "a message holds at most {MESSAGE_MAX} bytes");

    joined.replace('|', "/")
}

fn write_locked(port_first: u64, bytes: &[u8]) -> Result<(), Error> {
    let lock = lock_take()?;
    let port = OpenOptions::new().write(true).open(PORT_PATH).map_err(Error::Port)?;

    port.write_all_at(bytes, port_first).map_err(Error::Port)?;

    drop(lock);

    Ok(())
}

pub fn ack(identifier: &str) -> Result<(), Error> {
    console(&format!("DST ACK {identifier}"))
}

pub fn agent_spawn() -> Result<(), Error> {
    Command::new("python3")
        .arg("-m")
        .arg(AGENT_MODULE)
        .stdin(Stdio::null())
        .spawn()
        .map(drop)
        .map_err(Error::Agent)
}

pub fn below(limit: u64) -> Result<u64, Error> {
    Ok(word_below(random()?, limit))
}

pub fn boolean() -> Result<bool, Error> {
    Ok(word_boolean(random()?))
}

pub fn checked() -> Result<(), Error> {
    console("DST CHECK DONE")
}

pub fn choice<'a, T>(options: &'a [T]) -> Result<&'a T, Error> {
    assert!(!options.is_empty(), "a choice needs at least one option");

    let index = below(options.len() as u64)?;

    Ok(&options[index as usize])
}

pub fn console(line: &str) -> Result<(), Error> {
    let mut console = OpenOptions::new()
        .write(true)
        .custom_flags(O_NOCTTY)
        .open(CONSOLE_PATH)
        .map_err(Error::Console)?;

    let text = format!("{line}\n");

    io::Write::write_all(&mut console, text.as_bytes()).map_err(Error::Console)
}

pub fn control(command: u8) -> Result<(), Error> {
    let port = OpenOptions::new().write(true).open(PORT_PATH).map_err(Error::Port)?;

    port.write_all_at(&[command], CONTROL_PORT).map_err(Error::Port)
}

pub fn cpus_count() -> usize {
    thread::available_parallelism().map(usize::from).unwrap_or(1)
}

pub fn declare(properties: &[(Kind, &str)]) -> Result<(), Error> {
    for (kind, message) in properties {
        console(&line_build("DST DECLARE ", kind.name(), message, ""))?;
    }

    Ok(())
}

pub fn entropy_mix(value: u64) -> Result<(), Error> {
    let mut pool = OpenOptions::new().write(true).open(ENTROPY_PATH).map_err(Error::Port)?;

    io::Write::write_all(&mut pool, &value.to_le_bytes()).map_err(Error::Port)?;

    let fd = std::os::unix::io::AsRawFd::as_raw_fd(&pool);
    let rc = unsafe { ioctl(fd, RESEED_CRNG) };

    if rc != 0 {
        return Err(Error::Port(io::Error::last_os_error()));
    }

    Ok(())
}

pub fn event_due() -> Result<Event, Error> {
    event_read(CONTROL_EVENT_DUE)
}

pub fn event_wait() -> Result<u64, Error> {
    Ok(event_read(CONTROL_EVENT_WAIT)?.delay_ns())
}

pub fn eventually_ns() -> u64 {
    std::env::var("DST_EVENTUALLY_NS")
        .ok()
        .and_then(|text| text.parse().ok())
        .unwrap_or(0)
}

pub fn maximize(message: &str, value: u64) -> Result<(), Error> {
    let crc = crc32(message_clean(message).as_bytes());
    let mut bytes = [0u8; 12];

    bytes[..4].copy_from_slice(&crc.to_le_bytes());
    bytes[4..].copy_from_slice(&value.to_le_bytes());

    write_locked(GUIDANCE_PORT, &bytes)
}

pub fn oom_immune() -> Result<(), Error> {
    std::fs::write(OOM_PATH, OOM_IMMUNE).map_err(Error::Port)
}

pub fn power_loss() -> Result<(), Error> {
    control(CONTROL_POWER_LOSS)
}

pub fn present(identifier: &str) -> Result<(), Error> {
    console(&format!("DST PRESENT {identifier}"))
}

pub fn quiet_wait() -> bool {
    for _ in 0..QUIET_POLLS_MAX {
        if std::fs::metadata(QUIET_PATH).is_ok() {
            return true;
        }

        thread::sleep(QUIET_POLL);
    }

    false
}

pub fn random() -> Result<u64, Error> {
    let mut bytes = [0u8; 8];

    exchange(DRAW_PORT, DRAW_LATCH, DRAW_PORT + 1, &mut bytes)?;

    Ok(u64::from_le_bytes(bytes))
}

pub fn ready(agent: bool) -> Result<u64, Error> {
    console(&format!("DST CPUS {}", cpus_count()))?;
    control(CONTROL_READY)?;

    let run_seed = seed()?;

    entropy_mix(run_seed)?;
    oom_immune()?;

    if agent {
        agent_spawn()?;
    }

    Ok(run_seed)
}

pub fn seed() -> Result<u64, Error> {
    let port = OpenOptions::new().read(true).open(PORT_PATH).map_err(Error::Port)?;
    let mut bytes = [0u8; 8];

    port.read_exact_at(&mut bytes, SEED_PORT).map_err(Error::Port)?;

    Ok(u64::from_le_bytes(bytes))
}

pub fn word_below(word: u64, limit: u64) -> u64 {
    assert!(limit > 0, "a draw below {limit} has no value to return");

    let value = ((u128::from(word) * u128::from(limit)) >> 64) as u64;

    assert!(value < limit);

    value
}

pub fn word_boolean(word: u64) -> bool {
    word >> 63 == 1
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_word_maps_below_a_limit_monotonically() {
        assert_eq!(word_below(0, 10), 0);
        assert_eq!(word_below(u64::MAX, 10), 9);
        assert_eq!(word_below(1 << 63, 10), 5);
        assert!(!word_boolean(0));
        assert!(word_boolean(1 << 63));

        let mut previous = 0;

        for shift in 0..64 {
            let value = word_below(1u64 << shift, 1000);

            assert!(value >= previous);

            previous = value;
        }
    }

    #[test]
    fn a_message_collapses_whitespace_and_loses_its_separators() {
        let line = line_build("DST ALWAYS ", "FAIL", "  money |\tis\n conserved ", "{}");

        assert_eq!(line, "DST ALWAYS FAIL money / is conserved | {}");
    }

    #[test]
    fn an_event_renders_its_enumerated_fields_by_name() {
        let mut event = Event { words: [0; 22] };

        event.words[0] = 4;
        event.words[3] = 6;
        event.words[7] = (-5i64) as u64;

        let rendered = event.render().expect("a valid event renders");

        assert!(rendered.starts_with("kind=kill delay_ns=0 duration_ns=0 target=redis_server"));
        assert!(rendered.contains(" clock_jump_ns=-5 "));
        assert!(rendered.ends_with(" throttle_permille=0"));

        event.words[0] = KINDS.len() as u64;

        assert!(event.render().is_err());
    }

    #[test]
    fn the_crc_matches_the_iso_hdlc_check_value() {
        assert_eq!(crc32(b"123456789"), 0xcbf4_3926);
    }
}
