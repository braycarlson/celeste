use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::thread;
use std::time::Duration;

use dst::{Kind, Reporter};

const ACKS_COUNT: u32 = 8;
const ACKS_PATH: &str = "/var/lib/conformance/acks";
const DRAW_LIMIT: u64 = 10;
const DRAWS_COUNT: u32 = 64;
const EVENTS_MAX: u32 = 64;
const IDENTIFIER_LENGTH: usize = 36;
const LIVE_MESSAGE: &str = "the guest is live after the faults stop";

const PROPERTIES: [(Kind, &str); 6] = [
    (Kind::Always, "every draw is below its limit"),
    (Kind::Always, LIVE_MESSAGE),
    (Kind::Maximize, "the largest draw"),
    (Kind::Reachable, "the guest reached ready"),
    (Kind::Sometimes, "a coin came up heads"),
    (Kind::Unreachable, "a draw reached its limit"),
];

fn acks_write() -> Result<(), Box<dyn std::error::Error>> {
    let mut text = String::new();

    for index in 1..=ACKS_COUNT {
        text.push_str(&format!("00000000-0000-4000-8000-0000000000{index:02}\n"));
    }

    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(ACKS_PATH)?;

    file.write_all(text.as_bytes())?;
    file.sync_all()?;

    for line in text.lines() {
        dst::ack(line)?;
    }

    Ok(())
}

fn check() -> Result<(), Box<dyn std::error::Error>> {
    let mut held = String::new();

    if let Ok(mut file) = File::open(ACKS_PATH) {
        file.read_to_string(&mut held)?;
    }

    for line in held.lines() {
        if line.len() == IDENTIFIER_LENGTH {
            dst::present(line)?;
        }
    }

    dst::checked()?;

    Ok(())
}

fn draws(reporter: &mut Reporter) -> Result<(), Box<dyn std::error::Error>> {
    let mut largest = 0;

    for _ in 0..DRAWS_COUNT {
        let word = dst::random()?;
        let value = dst::word_below(word, DRAW_LIMIT);

        dst::console(&format!("DST DRAWS 0 {word:x}"))?;
        reporter.always(value < DRAW_LIMIT, "every draw is below its limit", "")?;
        reporter.sometimes(dst::word_boolean(word), "a coin came up heads")?;

        if value >= DRAW_LIMIT {
            reporter.never("a draw reached its limit", "")?;
        }

        if word > largest {
            largest = word;

            dst::maximize("the largest draw", word)?;
        }
    }

    assert!(largest > 0);

    Ok(())
}

fn events() -> Result<(), Box<dyn std::error::Error>> {
    for _ in 0..EVENTS_MAX {
        let delay_ns = dst::event_wait()?;

        thread::sleep(Duration::from_nanos(delay_ns));

        let event = dst::event_due()?;

        if event.kind() == 0 {
            return Ok(());
        }

        dst::console(&format!("DST EVENT {} END", event.render()?))?;
    }

    Err("the timeline served more events than the guest holds".into())
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let mut reporter = Reporter::default();

    dst::declare(&PROPERTIES)?;

    let seed = dst::ready(false)?;

    dst::console(&format!("DST SEED {seed:x}"))?;
    reporter.reachable("the guest reached ready")?;
    draws(&mut reporter)?;
    acks_write()?;
    events()?;

    if dst::eventually_ns() > 0 {
        let quiet = dst::quiet_wait();

        reporter.eventually(quiet, LIVE_MESSAGE, "")?;
    }

    dst::power_loss()?;

    Ok(())
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let checking = std::env::args().nth(1).as_deref() == Some("check");

    if checking {
        return check();
    }

    run()
}
