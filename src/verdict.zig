const std = @import("std");

const faults_module = @import("faults.zig");

const assert = std.debug.assert;
const Event = faults_module.Event;
const Writer = std.Io.Writer;

pub const Catalog = struct {
    count: u32 = 0,
    kinds: [properties_max]Kind = undefined,
    lengths: [properties_max]u16 = undefined,
    offsets: [properties_max]u32 = undefined,
    text: [catalog_text_max]u8 = undefined,
    text_length: u32 = 0,

    fn add(catalog: *Catalog, kind: Kind, message: []const u8) error{CatalogFull}!void {
        if (catalog.find(kind, message) != null) return;
        if (catalog.count == properties_max) return error.CatalogFull;
        if (message.len > message_max) return error.CatalogFull;
        if (catalog.text_length + message.len > catalog_text_max) return error.CatalogFull;

        const index = catalog.count;

        @memcpy(catalog.text[catalog.text_length..][0..message.len], message);

        catalog.kinds[index] = kind;
        catalog.lengths[index] = @intCast(message.len);
        catalog.offsets[index] = catalog.text_length;
        catalog.text_length += @intCast(message.len);
        catalog.count += 1;

        assert(std.mem.eql(u8, catalog.message_at(index), message));
        assert(catalog.text_length <= catalog_text_max);
    }

    pub fn find(catalog: *const Catalog, kind: Kind, message: []const u8) ?u32 {
        assert(catalog.count <= properties_max);

        for (0..catalog.count) |index| {
            const candidate: u32 = @intCast(index);
            if (catalog.kinds[candidate] != kind) continue;
            if (std.mem.eql(u8, catalog.message_at(candidate), message)) return candidate;
        }

        return null;
    }

    pub fn message_at(catalog: *const Catalog, index: u32) []const u8 {
        assert(index < catalog.count);
        assert(catalog.offsets[index] + catalog.lengths[index] <= catalog.text_length);

        return catalog.text[catalog.offsets[index]..][0..catalog.lengths[index]];
    }

    pub fn parse(catalog: *Catalog, transcript: []const u8) error{CatalogFull}!void {
        assert(catalog.count == 0);

        var lines = std.mem.splitScalar(u8, transcript, '\n');

        for (0..transcript.len + 2) |_| {
            const raw = lines.next() orelse break;
            const line = std.mem.trimEnd(u8, raw, "\r");
            const declared = prefix_strip(line, "DST DECLARE ") orelse continue;
            const space = std.mem.findScalar(u8, declared, ' ') orelse continue;
            const kind = std.meta.stringToEnum(Kind, declared[0..space]) orelse continue;

            try catalog.add(kind, declared[space + 1 ..]);
        } else unreachable;

        assert(catalog.count <= properties_max);
    }

    pub fn unreached(catalog: *const Catalog, hits: *const Hits, index: u32) bool {
        assert(index < catalog.count);

        const hit = hits[index / 64] & bit(index) != 0;

        return switch (catalog.kinds[index]) {
            .always, .reachable, .sometimes => !hit,
            .maximize, .@"unreachable" => false,
        };
    }
};

pub const Eventually = enum {
    unreached,
    passed,
    failed,
};

pub const Hits = [hits_words]u64;

pub const Kind = enum {
    always,
    maximize,
    reachable,
    sometimes,
    @"unreachable",
};

pub const Scratch = struct {
    acknowledged: [transfer_ids_max][]const u8,
    event_echoes: [faults_module.events_max][]const u8,
    present: [transfer_ids_max][]const u8,
};

pub const Verdict = struct {
    acknowledged: u32 = 0,
    agent_errors: u32 = 0,
    checked: bool = false,
    detail: []const u8 = "",
    event_echoes: u32 = 0,
    eventually: Eventually = .unreached,
    failures: u32 = 0,
    hits: Hits = @splat(0),
    lost: u32 = 0,
    present: u32 = 0,
    undeclared: u32 = 0,

    fn assertion(
        verdict: *Verdict,
        catalog: *const Catalog,
        kind: Kind,
        reported: []const u8,
        failed: bool,
    ) void {
        const separator = std.mem.find(u8, reported, details_separator);
        const message = if (separator) |index| reported[0..index] else reported;

        if (failed) {
            if (verdict.failures == 0) verdict.detail = reported;
        }

        verdict.failures += @intFromBool(failed);

        const index = catalog.find(kind, message) orelse {
            verdict.undeclared += 1;

            return;
        };

        verdict.hits[index / 64] |= bit(index);

        assert(verdict.hits[index / 64] & bit(index) != 0);
    }

    fn line_judge(
        verdict: *Verdict,
        catalog: *const Catalog,
        line: []const u8,
        scratch: *Scratch,
    ) error{TooManyTransfers}!void {
        if (prefix_strip(line, "DST ACK ")) |id| {
            return id_add(&scratch.acknowledged, &verdict.acknowledged, id);
        }

        if (prefix_strip(line, "DST PRESENT ")) |id| {
            return id_add(&scratch.present, &verdict.present, id);
        }

        for (assertion_lines) |entry| {
            const reported = prefix_strip(line, entry.prefix) orelse continue;
            return verdict.assertion(catalog, entry.kind, reported, entry.failed);
        }

        if (std.mem.eql(u8, line, "DST CHECK DONE")) verdict.checked = true;
        if (std.mem.eql(u8, line, "DST EVENTUALLY PASS")) verdict.eventually = .passed;
        if (std.mem.eql(u8, line, "DST EVENTUALLY FAIL")) verdict.eventually = .failed;
        if (std.mem.startsWith(u8, line, "DST AGENT ERROR")) verdict.agent_errors += 1;
        if (!event_echo_whole(line)) return;

        const echo = line[event_echo_prefix.len .. line.len - event_echo_suffix.len];

        if (verdict.event_echoes < scratch.event_echoes.len) {
            scratch.event_echoes[verdict.event_echoes] = echo;
        }

        verdict.event_echoes += 1;
    }

    pub fn passed(verdict: *const Verdict) bool {
        return verdict.checked and verdict.failures == 0 and verdict.lost == 0;
    }
};

const AssertionLine = struct {
    failed: bool,
    kind: Kind,
    prefix: []const u8,
};

pub const event_text_max = 2048;
const catalog_text_max = 32 << 10;
const details_separator = " | ";
const event_echo_prefix = "DST EVENT ";
const event_echo_suffix = " END";
const hits_words = properties_max / 64;
const message_max = 1024;
const properties_max = 256;
const transfer_id_length = 36;
const transfer_ids_max = 8192;

const assertion_lines = [_]AssertionLine{
    .{ .failed = false, .kind = .always, .prefix = "DST ALWAYS PASS " },
    .{ .failed = true, .kind = .always, .prefix = "DST ALWAYS FAIL " },
    .{ .failed = false, .kind = .reachable, .prefix = "DST REACHABLE " },
    .{ .failed = false, .kind = .sometimes, .prefix = "DST SOMETIMES " },
    .{ .failed = true, .kind = .@"unreachable", .prefix = "DST UNREACHABLE " },
};

comptime {
    assert(properties_max % 64 == 0);
    assert(message_max <= std.math.maxInt(u16));
    assert(catalog_text_max <= std.math.maxInt(u32));
}

fn bit(index: u32) u64 {
    assert(index < properties_max);

    return @as(u64, 1) << @intCast(index % 64);
}

fn event_echo_whole(line: []const u8) bool {
    if (line.len < event_echo_prefix.len + event_echo_suffix.len) return false;
    if (!std.mem.startsWith(u8, line, event_echo_prefix)) return false;
    return std.mem.endsWith(u8, line, event_echo_suffix);
}

fn id_add(ids: [][]const u8, count: *u32, id: []const u8) error{TooManyTransfers}!void {
    if (!transfer_id_valid(id)) return;
    if (count.* == ids.len) return error.TooManyTransfers;

    ids[count.*] = id;
    count.* += 1;
}

fn id_find(ids: []const []const u8, id: []const u8) bool {
    for (ids) |candidate| {
        if (std.mem.eql(u8, candidate, id)) return true;
    }

    return false;
}

fn prefix_strip(line: []const u8, prefix: []const u8) ?[]const u8 {
    assert(prefix.len > 0);

    if (!std.mem.startsWith(u8, line, prefix)) return null;
    return line[prefix.len..];
}

fn transfer_id_valid(id: []const u8) bool {
    if (id.len != transfer_id_length) return false;

    for (id, 0..) |byte, index| {
        const dash = index == 8 or index == 13 or index == 18 or index == 23;
        if (dash != (byte == '-')) return false;
        if (dash) continue;
        if (!std.ascii.isHex(byte)) return false;
    }

    return true;
}

pub fn event_mismatch(events: []const Event, echoes: []const []const u8) ?u32 {
    var buffer: [event_text_max]u8 = undefined;

    assert(events.len <= faults_module.events_max);
    assert(echoes.len <= faults_module.events_max);

    for (echoes, 0..) |echo, index| {
        if (index == events.len) return @intCast(index);

        var writer: Writer = .fixed(&buffer);

        events[index].render(&writer) catch return @intCast(index);

        if (!std.mem.eql(u8, writer.buffered(), echo)) return @intCast(index);
    }

    if (events.len > echoes.len + 1) return @intCast(echoes.len);
    return null;
}

pub fn judge(
    scratch: *Scratch,
    transcript: []const u8,
    catalog: *const Catalog,
) error{TooManyTransfers}!Verdict {
    const acknowledged = &scratch.acknowledged;
    const present = &scratch.present;
    var verdict: Verdict = .{};
    var lines = std.mem.splitScalar(u8, transcript, '\n');

    for (0..transcript.len + 2) |_| {
        const raw = lines.next() orelse break;
        const line = std.mem.trimEnd(u8, raw, "\r");

        try verdict.line_judge(catalog, line, scratch);
    } else unreachable;

    assert(verdict.present <= present.len);

    for (acknowledged[0..verdict.acknowledged]) |id| {
        if (!id_find(present[0..verdict.present], id)) verdict.lost += 1;
    }

    assert(verdict.lost <= verdict.acknowledged);

    return verdict;
}

pub fn maximize_message(catalog: *const Catalog, crc: u32) ?[]const u8 {
    assert(catalog.count <= properties_max);

    for (0..catalog.count) |index| {
        const property: u32 = @intCast(index);
        const message = catalog.message_at(property);

        if (catalog.kinds[property] != .maximize) continue;
        if (std.hash.Crc32.hash(message) == crc) return message;
    }

    return null;
}

test "the contract transcript exercises every console line kind and judges as documented" {
    const scratch = try std.testing.allocator.create(Scratch);
    defer std.testing.allocator.destroy(scratch);

    const event: Event = .{ .kind = .clock_jump, .delay_ns = 7, .clock_jump_ns = 9 };
    var buffer: [event_text_max]u8 = undefined;
    var writer: Writer = .fixed(&buffer);

    try event.render(&writer);

    const echo = writer.buffered();

    const head = "DST GUEST UP\r\n" ++
        "DST DECLARE always money is conserved\r\n" ++
        "DST DECLARE sometimes a transfer is rejected\r\n" ++
        "DST DECLARE reachable a duplicate is recognised\r\n" ++
        "DST DECLARE unreachable a lease was lost\r\n" ++
        "DST DECLARE maximize the stage reached\r\n" ++
        "DST DECLARE never a kind the contract does not name\r\n" ++
        "DST CPUS 1\r\n" ++
        "DST ACK 00000000-0000-4000-8000-000000000001\r\n" ++
        "DST ACK 00000000-0000-4000-8000-000000000002\r\n" ++
        "DST ACK 00000000-0000-4000-8000-00000000\r\n" ++
        "DST EVENT ";

    const tail = " END\r\n" ++
        "DST FAULT clock jump 9 ns\r\n" ++
        "DST KERNEL EXT4-fs error\r\n" ++
        "DST ALWAYS PASS money is conserved\r\n" ++
        "DST ALWAYS FAIL money is conserved | {\"total\": 7}\r\n" ++
        "DST SOMETIMES a transfer is rejected\r\n" ++
        "DST REACHABLE a duplicate is recognised\r\n" ++
        "DST UNREACHABLE a lease was lost | {\"account\": 1}\r\n" ++
        "DST SOMETIMES a property nobody declared\r\n" ++
        "DST AGENT ERROR KeyError: target\r\n" ++
        "DST QUIET\r\n" ++
        "DST EVENTUALLY PASS\r\n" ++
        "DST WORKLOAD DONE acknowledged=2\r\n" ++
        "DST PRESENT 00000000-0000-4000-8000-000000000001\r\n" ++
        "DST CHECK DONE\r\n";

    var transcript: [head.len + event_text_max + tail.len]u8 = undefined;
    const written = try std.mem.print(&transcript, "{s}{s}{s}", .{ head, echo, tail });
    var catalog: Catalog = .{};

    try catalog.parse(written);

    const verdict = try judge(scratch, written, &catalog);
    const passed = verdict.passed();

    try test_contract_catalog(&catalog, &verdict);
    try std.testing.expectEqual(2, verdict.acknowledged);
    try std.testing.expectEqual(1, verdict.present);
    try std.testing.expectEqual(1, verdict.lost);
    try std.testing.expectEqual(2, verdict.failures);
    try std.testing.expectEqual(1, verdict.undeclared);
    try std.testing.expectEqual(1, verdict.agent_errors);
    try std.testing.expectEqual(1, verdict.event_echoes);
    try std.testing.expectEqualStrings(echo, scratch.event_echoes[0]);
    try std.testing.expectEqualStrings("money is conserved | {\"total\": 7}", verdict.detail);
    try std.testing.expect(verdict.checked);
    try std.testing.expectEqual(Eventually.passed, verdict.eventually);
    try std.testing.expect(!passed);
}

fn test_contract_catalog(catalog: *const Catalog, verdict: *const Verdict) !void {
    const crc = std.hash.Crc32.hash("the stage reached");
    const maximize = maximize_message(catalog, crc) orelse return error.Unexpected;
    const always = catalog.find(.always, "money is conserved") orelse return error.Unexpected;
    const stage = catalog.find(.maximize, "the stage reached") orelse return error.Unexpected;
    const always_unreached = catalog.unreached(&verdict.hits, always);
    const stage_unreached = catalog.unreached(&verdict.hits, stage);

    try std.testing.expectEqual(5, catalog.count);
    try std.testing.expectEqualStrings("the stage reached", maximize);
    try std.testing.expect(!always_unreached);
    try std.testing.expect(!stage_unreached);
}

test "the verdict counts complete acknowledgments and ignores torn lines" {
    const scratch = try std.testing.allocator.create(Scratch);
    defer std.testing.allocator.destroy(scratch);

    const catalog: Catalog = .{};

    const transcript =
        "DST ACK 00000000-0000-4000-8000-000000000001\r\n" ++
        "DST ACK 00000000-0000-4000-8000-000000000002\r\n" ++
        "DST ACK 00000000-0000-4000-8000-00000000\r\n" ++
        "DST ACK 00000000-0000-4000-8000-000000000003DST GUEST UP\r\n" ++
        "DST PRESENT 00000000-0000-4000-8000-000000000001\r\n" ++
        "DST PRESENT 00000000-0000-4000-8000-000000000004\r\n" ++
        "DST CHECK DONE\r\n";

    const verdict = try judge(scratch, transcript, &catalog);

    try std.testing.expectEqual(@as(u32, 2), verdict.acknowledged);
    try std.testing.expectEqual(@as(u32, 2), verdict.present);
    try std.testing.expectEqual(@as(u32, 1), verdict.lost);
    try std.testing.expectEqual(@as(u32, 0), verdict.failures);
    try std.testing.expect(verdict.checked);
    try std.testing.expect(!verdict.passed());
}

test "a failed always or a reached unreachable fails the seed and keeps the first report" {
    const scratch = try std.testing.allocator.create(Scratch);
    defer std.testing.allocator.destroy(scratch);

    var catalog: Catalog = .{};

    const declarations = "DST DECLARE always money is conserved\n" ++
        "DST DECLARE unreachable a lease was lost\n";

    const done = "DST CHECK DONE\n";
    const conserved = "DST ALWAYS PASS money is conserved\n";
    const broken = "DST ALWAYS FAIL money is conserved | {\"total\": 7999}\n";
    const lost = "DST UNREACHABLE a lease was lost | {\"account\": \"account-1\"}\n";

    try catalog.parse(declarations);

    const passed = try judge(scratch, declarations ++ conserved ++ done, &catalog);
    const failed = try judge(scratch, conserved ++ broken ++ done, &catalog);
    const reached = try judge(scratch, lost ++ done, &catalog);
    const unchecked = try judge(scratch, conserved, &catalog);
    const lease = "a lease was lost | {\"account\": \"account-1\"}";

    try std.testing.expect(passed.passed());
    try std.testing.expect(!failed.passed());
    try std.testing.expect(!reached.passed());
    try std.testing.expect(!unchecked.passed());
    try std.testing.expectEqual(@as(u32, 1), failed.failures);
    try std.testing.expectEqualStrings("money is conserved | {\"total\": 7999}", failed.detail);
    try std.testing.expectEqualStrings(lease, reached.detail);
}

test "declared properties map to hit bits and undeclared reports are counted, not dropped" {
    const scratch = try std.testing.allocator.create(Scratch);
    defer std.testing.allocator.destroy(scratch);

    var catalog: Catalog = .{};

    const declarations = "DST DECLARE always money is conserved\r\n" ++
        "DST DECLARE sometimes a transfer is rejected\r\n" ++
        "DST DECLARE reachable a duplicate is recognised\r\n" ++
        "DST DECLARE sometimes a transfer is rejected\r\n" ++
        "DST DECLARE never a typo\r\n" ++
        "DST DECLARE unreachable a lease was lost\r\n";

    try catalog.parse(declarations);

    const first = try judge(scratch, "DST SOMETIMES a transfer is rejected\n", &catalog);

    const second = try judge(scratch, "DST ALWAYS PASS money is conserved\n" ++
        "DST REACHABLE a duplicat\n", &catalog);

    var union_hits: Hits = @splat(0);

    for (&union_hits, first.hits, second.hits) |*word, a, b| word.* = a | b;

    try std.testing.expectEqual(@as(u32, 4), catalog.count);
    try std.testing.expectEqualStrings("a duplicate is recognised", catalog.message_at(2));
    try std.testing.expect(!catalog.unreached(&union_hits, 0));
    try std.testing.expect(!catalog.unreached(&union_hits, 1));
    try std.testing.expect(catalog.unreached(&union_hits, 2));
    try std.testing.expect(!catalog.unreached(&union_hits, 3));
    try std.testing.expectEqual(@as(u32, 1), second.undeclared);
    try std.testing.expectEqual(@as(u32, 0), first.undeclared);
}

test "the verdict keeps only whole event echoes and the check names a misread or missing one" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const scratch = try std.testing.allocator.create(Scratch);
    defer std.testing.allocator.destroy(scratch);

    const arena = arena_state.allocator();
    const catalog: Catalog = .{};

    const events = [_]Event{
        .{ .choice = 2, .delay_ns = 40, .kind = .kill, .target = .redis_server },
        .{ .clock_jump_ns = 9, .kind = .clock_jump },
        .{ .disk_full_slack_kib = 3, .kind = .disk_full },
    };

    var buffer: [event_text_max]u8 = undefined;
    var writer: Writer = .fixed(&buffer);

    try events[0].render(&writer);

    const rendered = writer.buffered();

    const transcript = try std.mem.concat(arena, u8, &.{
        "DST EVENT ",
        rendered,
        " END\r\n",
        "DST EVENT kind=clock_ju",
        "DST CHECK DONE\r\n",
        "DST EVENT END\r\n",
    });

    const verdict = try judge(scratch, transcript, &catalog);
    const echoes = scratch.event_echoes[0..verdict.event_echoes];
    const misread = try std.mem.replaceOwned(u8, arena, rendered, "ns=40 ", "ns=41 ");
    const first = [_][]const u8{rendered};
    const misreading = [_][]const u8{misread};
    const extra = [_][]const u8{ rendered, rendered };

    try std.testing.expectEqual(@as(u32, 1), verdict.event_echoes);
    try std.testing.expectEqualStrings(rendered, echoes[0]);
    try std.testing.expect(!verdict.checked);
    try std.testing.expectEqual(null, event_mismatch(events[0..1], &first));
    try std.testing.expectEqual(null, event_mismatch(events[0..2], &first));
    try std.testing.expectEqual(1, event_mismatch(&events, &first));
    try std.testing.expectEqual(0, event_mismatch(events[0..1], &misreading));
    try std.testing.expectEqual(1, event_mismatch(events[0..1], &extra));
}

test "the eventually phase reports pass or fail and a run without it reports neither" {
    const scratch = try std.testing.allocator.create(Scratch);
    defer std.testing.allocator.destroy(scratch);

    const catalog: Catalog = .{};
    const plain = try judge(scratch, "DST CHECK DONE\n", &catalog);
    const passed = try judge(scratch, "DST EVENTUALLY PASS\r\nDST CHECK DONE\n", &catalog);
    const failed = try judge(scratch, "DST EVENTUALLY FAIL\nDST CHECK DONE\n", &catalog);
    const torn = try judge(scratch, "DST EVENTUALLY PA\nDST CHECK DONE\n", &catalog);

    try std.testing.expectEqual(Eventually.unreached, plain.eventually);
    try std.testing.expectEqual(Eventually.passed, passed.eventually);
    try std.testing.expectEqual(Eventually.failed, failed.eventually);
    try std.testing.expectEqual(Eventually.unreached, torn.eventually);
}

test "transcripts made only of line breaks parse to empty results within the loop bound" {
    const scratch = try std.testing.allocator.create(Scratch);
    defer std.testing.allocator.destroy(scratch);

    for ([_][]const u8{ "", "\n", "\n\n\n\n" }) |transcript| {
        var catalog: Catalog = .{};

        try catalog.parse(transcript);

        const verdict = try judge(scratch, transcript, &catalog);

        try std.testing.expectEqual(0, catalog.count);
        try std.testing.expectEqual(0, verdict.acknowledged);
        try std.testing.expect(!verdict.checked);
    }
}
