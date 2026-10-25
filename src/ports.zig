const std = @import("std");

const assert = std.debug.assert;

pub const control = 0x505;
pub const control_event_due = 0x05;
pub const control_event_wait = 0x03;
pub const control_power_loss = 0x01;
pub const control_quiet = 0x04;
pub const control_ready = 0x02;
pub const coverage_count = 3;
pub const coverage_first = 0x5f0;
pub const coverage_last = coverage_first + coverage_count - 1;
pub const draw_count = 9;
pub const draw_first = 0x5e0;
pub const draw_last = draw_first + draw_count - 1;
pub const draw_latch = 0x01;
pub const event_block_size = 0xd0;
pub const event_first = 0x510;
pub const event_last = event_first + event_block_size - 1;
pub const guidance_count = 12;
pub const guidance_first = 0x5f4;
pub const guidance_last = guidance_first + guidance_count - 1;
pub const seed_count = 8;
pub const seed_first = 0x508;
pub const seed_last = seed_first + seed_count - 1;
pub const word_bytes = 8;

comptime {
    assert(control < seed_first);
    assert(seed_last < event_first);
    assert(event_last < draw_first);
    assert(draw_last < coverage_first);
    assert(coverage_last < guidance_first);
    assert(guidance_last == 0x5ff);
    assert(draw_count == word_bytes + 1);
    assert(seed_count == word_bytes);
    assert(guidance_count == 4 + word_bytes);
}
