const std = @import("std");

const assert = std.debug.assert;

pub const Choices = struct {
    counts: [stream_count]u32 = @splat(0),
    guest_seed: u64 = 0,
    seed: u64 = 0,
    words: [stream_count][]u64 = @splat(&.{}),

    pub fn copy(target: *Choices, source: *const Choices) void {
        for (target.words, source.words, source.counts) |target_words, source_words, count| {
            assert(count <= source_words.len);
            assert(count <= target_words.len);

            @memcpy(target_words[0..count], source_words[0..count]);
        }

        target.counts = source.counts;
        target.guest_seed = source.guest_seed;
        target.seed = source.seed;
    }

    pub fn init_capacity(
        choices: *Choices,
        arena: std.mem.Allocator,
        capacities: *const [stream_count]u32,
    ) error{OutOfMemory}!void {
        choices.* = .{};

        for (&choices.words, capacities) |*words, capacity| {
            assert(capacity <= words_max);

            words.* = try arena.alloc(u64, capacity);

            @memset(words.*, 0);
        }

        assert(choices.total() == 0);
    }

    pub fn init_reproducer(
        choices: *Choices,
        arena: std.mem.Allocator,
        source: *const Reproducer,
    ) error{ OutOfMemory, ReproducerTooLong }!void {
        var capacities: [stream_count]u32 = undefined;

        inline for (comptime std.enums.values(StreamName), 0..) |name, index| {
            const words = @field(source, @tagName(name));
            if (words.len > words_max) return error.ReproducerTooLong;

            capacities[index] = @intCast(words.len);
        }

        try choices.init_capacity(arena, &capacities);

        inline for (comptime std.enums.values(StreamName), 0..) |name, index| {
            @memcpy(choices.words[index], @field(source, @tagName(name)));
        }

        choices.counts = capacities;
        choices.guest_seed = source.guest_seed;
        choices.seed = source.seed;

        assert(choices.total() == reproducer_total(source));
    }

    pub fn record(
        choices: *Choices,
        stream_seeds: *const [stream_count]u64,
        counts: *const [stream_count]u32,
    ) void {
        for (choices.words, stream_seeds, counts) |words, stream_seed, count| {
            assert(count <= words.len);

            var prng: std.Random.DefaultPrng = .init(stream_seed);

            for (words[0..count]) |*word| word.* = prng.next();
        }

        choices.counts = counts.*;

        assert(choices.total() == total_of(counts));
    }

    pub fn reproducer(choices: *const Choices) Reproducer {
        var result: Reproducer = .{ .guest_seed = choices.guest_seed, .seed = choices.seed };

        inline for (comptime std.enums.values(StreamName)) |name| {
            @field(result, @tagName(name)) = choices.slice(name);
        }

        assert(reproducer_total(&result) == choices.total());

        return result;
    }

    pub fn slice(choices: *const Choices, name: StreamName) []const u64 {
        const index = @backingInt(name);

        assert(choices.counts[index] <= choices.words[index].len);

        return choices.words[index][0..choices.counts[index]];
    }

    pub fn smaller(choices: *const Choices, other: *const Choices) bool {
        const count = choices.total();
        const other_count = other.total();
        if (count != other_count) return count < other_count;

        for (std.enums.values(StreamName)) |name| {
            const order = std.mem.order(u64, choices.slice(name), other.slice(name));
            if (order != .eq) return order == .lt;
        }

        return choices.guest_seed < other.guest_seed;
    }

    pub fn splice(
        choices: *Choices,
        name: StreamName,
        prefix: []const u64,
        fork_position: u64,
        fork_seed: u64,
    ) void {
        const index = @backingInt(name);
        const words = choices.words[index];
        const kept = @min(prefix.len, fork_position);
        var prng: std.Random.DefaultPrng = .init(fork_seed);

        assert(fork_position <= words.len);

        @memcpy(words[0..kept], prefix[0..kept]);
        @memset(words[kept..fork_position], 0);

        for (words[fork_position..]) |*word| word.* = prng.next();

        choices.counts[index] = @intCast(words.len);

        assert(choices.counts[index] >= fork_position);
    }

    pub fn stream(choices: *const Choices, name: StreamName) Stream {
        return .replay(choices.slice(name));
    }

    pub fn total(choices: *const Choices) u64 {
        return total_of(&choices.counts);
    }

    pub fn trim(choices: *Choices) void {
        for (&choices.counts, choices.words) |*count, words| {
            assert(count.* <= words.len);

            for (0..words.len) |_| {
                if (count.* == 0) break;
                if (words[count.* - 1] != 0) break;

                count.* -= 1;
            }
        }
    }
};

pub const Cursor = struct {
    chunk: u32 = 0,
    pass: Pass = .clear,
    position: u32 = 0,
    stream: u8 = 0,
};

pub const Pass = enum {
    clear,
    truncate,
    delete,
    zero,
    halve,
    guest,
    done,
};

pub const Reproducer = struct {
    block: []const u64 = &.{},
    crash: []const u64 = &.{},
    events: []const u64 = &.{},
    guest_seed: u64 = 0,
    jitter: []const u64 = &.{},
    plan: []const u64 = &.{},
    schedule: []const u64 = &.{},
    seed: u64 = 0,
    workload: []const u64 = &.{},
};

pub const Shrinker = struct {
    current: *Choices,
    cursor: Cursor = .{},
    improved: bool = false,
    sweeps: u32 = 0,
    units: [stream_count]u32 = @splat(1),

    fn advance(shrinker: *Shrinker) void {
        const pass = shrinker.cursor.pass;
        const stream_index = shrinker.cursor.stream + 1;

        assert(stream_index <= stream_count);

        if (stream_index < stream_count) {
            shrinker.cursor = .{ .pass = pass, .stream = stream_index };

            return;
        }

        const pass_next: Pass = switch (pass) {
            .clear => .truncate,
            .truncate => .delete,
            .delete => .zero,
            .zero => .halve,
            .halve => .guest,
            .guest, .done => unreachable,
        };

        shrinker.cursor = .{ .pass = pass_next };

        assert(shrinker.cursor.stream == 0);
    }

    fn chunk_min(shrinker: *const Shrinker) u32 {
        const index = shrinker.cursor.stream;
        const count = shrinker.current.counts[index];

        if (shrinker.small()) return 1;
        return @max(1, count / chunk_divisions);
    }

    fn small(shrinker: *const Shrinker) bool {
        const index = shrinker.cursor.stream;

        assert(index < stream_count);

        return shrinker.current.words[index].len <= small_words_max;
    }

    fn step(shrinker: *Shrinker, candidate: *Choices) ?Cursor {
        assert(shrinker.cursor.pass != .done);
        assert(shrinker.cursor.stream < stream_count);

        return switch (shrinker.cursor.pass) {
            .clear => shrinker.step_clear(candidate),
            .truncate => shrinker.step_truncate(candidate),
            .delete => shrinker.step_delete(candidate),
            .zero => shrinker.step_zero(candidate),
            .halve => shrinker.step_halve(candidate),
            .guest => shrinker.step_guest(candidate),
            .done => unreachable,
        };
    }

    fn step_clear(shrinker: *Shrinker, candidate: *Choices) ?Cursor {
        const index = shrinker.cursor.stream;

        if (shrinker.current.counts[index] == 0) {
            shrinker.advance();

            return null;
        }

        candidate.copy(shrinker.current);
        candidate.counts[index] = 0;

        shrinker.advance();

        assert(candidate.smaller(shrinker.current));

        return shrinker.cursor;
    }

    fn step_delete(shrinker: *Shrinker, candidate: *Choices) ?Cursor {
        const index = shrinker.cursor.stream;
        const unit = shrinker.units[index];
        const count = shrinker.current.counts[index];
        const position = shrinker.cursor.position;
        const start = position * unit;

        assert(unit > 0);

        if (unit == 1) return shrinker.stream_end();
        if (start + unit > count) return shrinker.stream_end();

        const words = candidate.words[index];

        shrinker.cursor.position += 1;

        candidate.copy(shrinker.current);
        std.mem.copyForwards(u64, words[start .. count - unit], words[start + unit .. count]);
        candidate.counts[index] = count - unit;

        assert(candidate.smaller(shrinker.current));

        return .{ .pass = .delete, .position = position, .stream = index };
    }

    fn step_guest(shrinker: *Shrinker, candidate: *Choices) ?Cursor {
        assert(shrinker.cursor.pass == .guest);

        shrinker.cursor = .{ .pass = .done };

        if (shrinker.current.guest_seed == 0) return null;

        candidate.copy(shrinker.current);
        candidate.guest_seed = 0;

        assert(candidate.smaller(shrinker.current));

        return shrinker.cursor;
    }

    fn step_halve(shrinker: *Shrinker, candidate: *Choices) ?Cursor {
        const index = shrinker.cursor.stream;
        const position = shrinker.cursor.position;

        if (!shrinker.small()) return shrinker.stream_end();
        if (position >= shrinker.current.counts[index]) return shrinker.stream_end();

        const word = shrinker.current.words[index][position];

        shrinker.cursor.position += 1;

        if (word == 0) return null;

        candidate.copy(shrinker.current);
        candidate.words[index][position] = word >> 1;

        assert(candidate.smaller(shrinker.current));

        return .{ .pass = .halve, .position = position, .stream = index };
    }

    fn step_truncate(shrinker: *Shrinker, candidate: *Choices) ?Cursor {
        const index = shrinker.cursor.stream;
        const count = shrinker.current.counts[index];
        const accepted = shrinker.cursor;

        shrinker.advance();

        if (count <= 1) return null;

        candidate.copy(shrinker.current);
        candidate.counts[index] = count / 2;

        assert(candidate.smaller(shrinker.current));

        return accepted;
    }

    fn step_zero(shrinker: *Shrinker, candidate: *Choices) ?Cursor {
        const index = shrinker.cursor.stream;
        const count = shrinker.current.counts[index];

        if (count == 0) {
            shrinker.advance();

            return null;
        }

        if (shrinker.cursor.chunk == 0) shrinker.cursor.chunk = @max(1, count / 2);

        const chunk = shrinker.cursor.chunk;
        const position = shrinker.cursor.position;

        if (position >= count) {
            shrinker.cursor.chunk = chunk / 2;
            shrinker.cursor.position = 0;

            if (shrinker.cursor.chunk < shrinker.chunk_min()) shrinker.advance();

            return null;
        }

        const end = @min(position + chunk, count);

        shrinker.cursor.position = end;

        if (std.mem.allEqual(u64, shrinker.current.words[index][position..end], 0)) return null;

        candidate.copy(shrinker.current);
        @memset(candidate.words[index][position..end], 0);

        assert(candidate.smaller(shrinker.current));

        return shrinker.cursor;
    }

    fn stream_end(shrinker: *Shrinker) ?Cursor {
        shrinker.advance();

        assert(shrinker.cursor.position == 0);
        assert(shrinker.cursor.chunk == 0);

        return null;
    }

    pub fn accept(shrinker: *Shrinker, candidate: *const Choices, resume_at: Cursor) void {
        assert(candidate.smaller(shrinker.current));
        assert(resume_at.stream < stream_count or resume_at.pass == .done);

        shrinker.current.copy(candidate);
        shrinker.current.trim();
        shrinker.cursor = resume_at;
        shrinker.improved = true;
    }

    pub fn next(shrinker: *Shrinker, candidate: *Choices) ?Cursor {
        assert(shrinker.sweeps < sweeps_max);

        for (0..cursor_steps_max) |_| {
            if (shrinker.cursor.pass == .done) {
                if (!shrinker.improved) return null;
                if (shrinker.sweeps + 1 == sweeps_max) return null;

                shrinker.cursor = .{};
                shrinker.improved = false;
                shrinker.sweeps += 1;
            }

            if (shrinker.step(candidate)) |resume_at| return resume_at;
        }

        unreachable;
    }
};

pub const Stream = struct {
    fork_position: ?u64 = null,
    position: u64 = 0,
    prng: std.Random.DefaultPrng,
    words: ?[]const u64 = null,

    fn next(stream: *Stream) u64 {
        const position = stream.position;

        stream.position += 1;

        assert(stream.position > position);

        const words = stream.words orelse return stream.prng.next();
        const recorded = if (position < words.len) words[position] else 0;

        return if (recorded == 0) word_minimal else recorded;
    }

    pub fn at_most(stream: *Stream, limit: u64) u64 {
        const drawn = stream.next();
        if (limit == std.math.maxInt(u64)) return drawn;

        const result = word_below(drawn, limit + 1);

        assert(result <= limit);

        return result;
    }

    pub fn below(stream: *Stream, limit: u64) u64 {
        assert(limit > 0);

        const result = word_below(stream.next(), limit);

        assert(result < limit);

        return result;
    }

    pub fn boolean(stream: *Stream) bool {
        return word_boolean(stream.next());
    }

    pub fn fork(stream: *Stream, seed: u64) void {
        assert(stream.fork_position == null);

        stream.fork_position = stream.position;
        stream.prng = .init(seed);
        stream.words = null;

        assert(stream.fork_position.? == stream.position);
    }

    pub fn init(seed: u64) Stream {
        return .{ .prng = .init(seed) };
    }

    pub fn replay(words: []const u64) Stream {
        assert(words.len <= words_max);

        return .{ .prng = .init(0), .words = words };
    }

    pub fn shuffle(stream: *Stream, comptime T: type, items: []T) void {
        assert(items.len <= std.math.maxInt(u32));

        if (items.len < 2) return;

        for (0..items.len - 1) |index| {
            const remaining = items.len - index;
            const other = index + stream.below(remaining);

            std.mem.swap(T, &items[index], &items[other]);
        }
    }

    pub fn word(stream: *Stream) u64 {
        return stream.next();
    }
};

pub const StreamName = enum(u8) {
    plan,
    crash,
    block,
    jitter,
    schedule,
    workload,
    events,
};

const chunk_divisions = 16;
const cursor_steps_max = 1 << 20;
const small_words_max = 64;
const sweeps_max = 4;
const test_draw_kinds = 5;
const test_limit = 1_000_000_007;
const test_event_words = 10;
const word_minimal = 2;
pub const stream_count = @typeInfo(StreamName).@"enum".field_names.len;
pub const words_max = 1 << 18;

comptime {
    assert(small_words_max < words_max);
    assert(chunk_divisions > 1);
    assert(stream_count == @typeInfo(Reproducer).@"struct".field_names.len - 2);
}

fn reproducer_total(reproducer: *const Reproducer) u64 {
    var result: u64 = 0;

    inline for (comptime std.enums.values(StreamName)) |name| {
        result += @field(reproducer, @tagName(name)).len;
    }

    return result;
}

fn test_draws(stream: *Stream, out: []u64) void {
    const position = stream.position;

    for (out, 0..) |*value, index| {
        value.* = switch (index % test_draw_kinds) {
            0 => @intFromBool(stream.boolean()),
            1 => stream.at_most(test_limit),
            2 => stream.below(test_limit),
            3 => stream.at_most(std.math.maxInt(u64)),
            else => stream.word(),
        };
    }

    assert(stream.position - position == out.len);
}

fn test_expected(word_drawn: u64, index: usize) u64 {
    const scaled: u64 = @intCast((@as(u128, word_drawn) * (test_limit + 1)) >> 64);
    const below: u64 = @intCast((@as(u128, word_drawn) * test_limit) >> 64);

    return switch (index % test_draw_kinds) {
        0 => word_drawn >> 63,
        1 => scaled,
        2 => below,
        else => word_drawn,
    };
}

fn test_predicate(choices: *const Choices) bool {
    const plan = choices.slice(.plan);
    const crash = choices.slice(.crash);
    const jitter = choices.slice(.jitter);

    if (plan.len <= 5) return false;
    if (plan[5] < 1 << 40) return false;
    if (crash.len == 0) return false;
    if (crash[0] < 1000) return false;
    if (jitter.len <= 100) return false;
    if (jitter[100] == 0) return false;
    return true;
}

fn test_timeline_jumps(choices: *const Choices) bool {
    var stream = choices.stream(.events);

    for (0..words_max / test_event_words) |_| {
        const first = stream.next();

        for (1..test_event_words) |_| _ = stream.next();

        if (first < 1 << 40) return false;
        if (first >= 1 << 63) return true;
    }

    unreachable;
}

fn total_of(counts: *const [stream_count]u32) u64 {
    var result: u64 = 0;

    for (counts) |count| result += count;

    return result;
}

pub fn word_below(word_drawn: u64, limit: u64) u64 {
    const product = @as(u128, word_drawn) * limit;
    const value: u64 = @intCast(product >> 64);

    assert(limit > 0);
    assert(value < limit);

    return value;
}

pub fn word_boolean(word_drawn: u64) bool {
    return word_drawn >> 63 == 1;
}

test "a stream without a buffer draws one default-generator word per value" {
    for (0..32) |seed| {
        var prng: std.Random.DefaultPrng = .init(seed);
        var stream: Stream = .init(seed);
        var actual: [96]u64 = undefined;

        test_draws(&stream, &actual);

        for (actual, 0..) |value, index| {
            const expected = test_expected(prng.next(), index);

            try std.testing.expectEqual(expected, value);
        }

        try std.testing.expectEqual(actual.len, stream.position);
    }
}

test "a recorded stream replays its draws and reads the minimal word past its end" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const seed = 0x5eed;
    var original: Stream = .init(seed);
    var expected: [64]u64 = undefined;

    test_draws(&original, &expected);

    var choices: Choices = .{};
    var capacities: [stream_count]u32 = @splat(0);
    var counts: [stream_count]u32 = @splat(0);
    var seeds: [stream_count]u64 = @splat(0);

    capacities[@backingInt(StreamName.plan)] = @intCast(original.position);
    counts[@backingInt(StreamName.plan)] = @intCast(original.position);
    seeds[@backingInt(StreamName.plan)] = seed;

    try choices.init_capacity(arena_state.allocator(), &capacities);
    choices.record(&seeds, &counts);

    var replayed = choices.stream(.plan);
    var actual: [64]u64 = undefined;

    test_draws(&replayed, &actual);

    try std.testing.expectEqualSlices(u64, &expected, &actual);
    try std.testing.expectEqual(original.position, replayed.position);

    var empty: Stream = .replay(&.{ 0, 0, 0, 0, 0 });

    try std.testing.expect(!empty.boolean());
    try std.testing.expectEqual(0, empty.at_most(1 << 40));
    try std.testing.expectEqual(0, empty.below(1000));
    try std.testing.expectEqual(0, empty.below(3));
    try std.testing.expectEqual(word_minimal, empty.word());
    try std.testing.expect(!empty.boolean());
    try std.testing.expectEqual(0, empty.below(7));
    try std.testing.expectEqual(7, empty.position);
}

test "a shuffle draws one word per position and keeps every item" {
    var items: [8]u8 = .{ 0, 1, 2, 3, 4, 5, 6, 7 };
    var minimal: Stream = .replay(&.{});
    var stream: Stream = .init(0x5fff);

    minimal.shuffle(u8, &items);

    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 4, 5, 6, 7 }, &items);
    try std.testing.expectEqual(items.len - 1, minimal.position);

    stream.shuffle(u8, &items);

    var sorted = items;

    std.mem.sort(u8, &sorted, {}, std.sort.asc(u8));

    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 4, 5, 6, 7 }, &sorted);
    try std.testing.expectEqual(items.len - 1, stream.position);
}

test "the shrinker only proposes smaller choices and reaches the known minimum" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const capacities: [stream_count]u32 = .{ 40, 1, 1000, 3000, 0, 0, 0 };
    var current: Choices = .{};
    var candidate: Choices = .{};
    var prng: std.Random.DefaultPrng = .init(0xc0ffee);

    try current.init_capacity(arena, &capacities);
    try candidate.init_capacity(arena, &capacities);

    for (current.words) |words| {
        for (words) |*word| word.* = prng.next() | 1 << 63;
    }

    current.counts = capacities;
    current.guest_seed = 99;
    current.seed = 7;

    try std.testing.expect(test_predicate(&current));

    var shrinker: Shrinker = .{ .current = &current };
    var runs: u32 = 0;

    while (shrinker.next(&candidate)) |resume_at| {
        runs += 1;

        try std.testing.expect(runs < 4096);
        try std.testing.expect(candidate.smaller(&current));
        try std.testing.expect(!candidate.smaller(&candidate));

        if (test_predicate(&candidate)) shrinker.accept(&candidate, resume_at);
    }

    const plan = current.slice(.plan);
    const crash = current.slice(.crash);
    const jitter = current.slice(.jitter);
    var jitter_nonzero: u32 = 0;

    for (jitter) |word| jitter_nonzero += @intFromBool(word != 0);

    try std.testing.expect(test_predicate(&current));
    try std.testing.expectEqual(6, plan.len);
    try std.testing.expect(std.mem.allEqual(u64, plan[0..5], 0));
    try std.testing.expect(plan[5] >> 1 < 1 << 40);
    try std.testing.expectEqual(1, crash.len);
    try std.testing.expect(crash[0] >> 1 < 1000);
    try std.testing.expectEqual(0, current.slice(.block).len);
    try std.testing.expect(jitter.len >= 101);
    try std.testing.expect(jitter.len <= 101 + capacities[3] / chunk_divisions);
    try std.testing.expect(jitter_nonzero <= capacities[3] / chunk_divisions);
    try std.testing.expectEqual(0, current.guest_seed);
    try std.testing.expectEqual(7, current.seed);
}

test "the shrinker deletes whole events to bring the one a failure needs to the front" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const events = @backingInt(StreamName.events);
    var capacities: [stream_count]u32 = @splat(0);
    var minimal: [2]u32 = undefined;
    var prng: std.Random.DefaultPrng = .init(0xde1e7e);

    capacities[events] = 5 * test_event_words;

    for (&minimal, [_]u32{ test_event_words, 1 }) |*count, unit| {
        var current: Choices = .{};
        var candidate: Choices = .{};

        try current.init_capacity(arena, &capacities);
        try candidate.init_capacity(arena, &capacities);

        for (current.words[events]) |*word| word.* = (1 << 40) + (prng.next() >> 2);

        current.words[events][3 * test_event_words] |= 1 << 63;
        current.counts = capacities;

        try std.testing.expect(test_timeline_jumps(&current));

        var shrinker: Shrinker = .{ .current = &current };
        var runs: u32 = 0;

        shrinker.units[events] = unit;

        while (shrinker.next(&candidate)) |resume_at| {
            runs += 1;

            try std.testing.expect(runs < 4096);

            if (test_timeline_jumps(&candidate)) shrinker.accept(&candidate, resume_at);
        }

        count.* = current.counts[events];

        try std.testing.expect(test_timeline_jumps(&current));
    }

    try std.testing.expectEqual(1, minimal[0]);
    try std.testing.expect(minimal[1] > 3 * test_event_words);
}

test "a forked stream replays its prefix, then draws fresh words that a splice records" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const prefix = [_]u64{ 11, 0, 13 };
    const fork_seed = 0xf0f0;
    var forked: Stream = .replay(&prefix);
    var expected: [12]u64 = undefined;

    for (expected[0..5]) |*value| value.* = forked.word();

    forked.fork(fork_seed);

    for (expected[5..]) |*value| value.* = forked.word();

    const replayed_prefix = [_]u64{ 11, word_minimal, 13, word_minimal, word_minimal };
    var fresh: std.Random.DefaultPrng = .init(fork_seed);

    try std.testing.expectEqualSlices(u64, &replayed_prefix, expected[0..5]);
    const fresh_word = fresh.next();

    try std.testing.expectEqual(fresh_word, expected[5]);
    try std.testing.expectEqual(5, forked.fork_position.?);
    try std.testing.expectEqual(12, forked.position);

    var choices: Choices = .{};
    var capacities: [stream_count]u32 = @splat(0);

    capacities[@backingInt(StreamName.jitter)] = @intCast(forked.position);

    try choices.init_capacity(arena_state.allocator(), &capacities);
    choices.splice(.jitter, &prefix, forked.fork_position.?, fork_seed);

    var replayed = choices.stream(.jitter);
    var actual: [12]u64 = undefined;

    for (&actual) |*value| value.* = replayed.word();

    try std.testing.expectEqualSlices(u64, &expected, &actual);
}

test "a reproducer survives a round trip through ZON" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const plan = [_]u64{ 0, 3, 1 << 63, 42 };
    const jitter = [_]u64{ 0, 0, 9 };

    const original: Reproducer = .{
        .guest_seed = 11,
        .jitter = &jitter,
        .plan = &plan,
        .seed = 1 << 40,
    };

    var choices: Choices = .{};

    try choices.init_reproducer(arena, &original);

    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();

    try std.zon.stringify.serialize(choices.reproducer(), .{}, &text.writer);

    const source = try arena.dupeSentinel(u8, text.written(), 0);
    var diagnostics: std.zon.parse.Diagnostics = undefined;

    const parsed = try std.zon.parse.fromSlice(Reproducer, .{
        .arena = arena,
        .diagnostics = &diagnostics,
        .gpa = std.testing.allocator,
        .source = source,
    });

    try std.testing.expectEqual(original.seed, parsed.seed);
    try std.testing.expectEqual(original.guest_seed, parsed.guest_seed);
    try std.testing.expectEqualSlices(u64, &plan, parsed.plan);
    try std.testing.expectEqualSlices(u64, &jitter, parsed.jitter);
    try std.testing.expectEqual(0, parsed.crash.len);
    try std.testing.expectEqual(0, parsed.block.len);

    var other: Choices = .{};

    try other.init_reproducer(arena, &parsed);

    try std.testing.expect(!other.smaller(&choices));
    try std.testing.expect(!choices.smaller(&other));
}
