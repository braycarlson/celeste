package celeste

import (
    "math"
    "math/bits"
    "strings"
    "testing"
)

func Test_a_word_maps_below_a_limit_monotonically(t *testing.T) {
    if got := Word_below(0, 10); got != 0 {
        t.Fatalf("minimal word mapped to %d", got)
    }

    if got := Word_below(math.MaxUint64, 10); got != 9 {
        t.Fatalf("maximal word mapped to %d", got)
    }

    if got := Word_below(1<<63, 10); got != 5 {
        t.Fatalf("the half word mapped to %d", got)
    }

    var previous uint64

    for shift := 0; shift < 64; shift++ {
        value := Word_below(uint64(1)<<shift, 1000)

        if value < previous {
            t.Fatalf("the mapping fell from %d to %d", previous, value)
        }

        previous = value
    }
}

func Test_the_high_product_matches_the_reference(t *testing.T) {
    words := []uint64{0, 1, 0xffffffff, 0x100000000, math.MaxUint64, 0x123456789abcdef0}

    for _, a := range words {
        for _, b := range words {
            high, low := multiply_high(a, b)
            reference_high, reference_low := bits.Mul64(a, b)

            if high != reference_high {
                t.Fatalf("%d * %d gave high %d, not %d", a, b, high, reference_high)
            }

            if low != reference_low {
                t.Fatalf("%d * %d gave low %d, not %d", a, b, low, reference_low)
            }
        }
    }
}

func Test_a_message_collapses_whitespace_and_loses_its_separators(t *testing.T) {
    line := line_build("CELESTE ALWAYS ", "FAIL", "  money |\tis\n conserved ", "{}")

    if line != "CELESTE ALWAYS FAIL money / is conserved | {}" {
        t.Fatalf("the line was %q", line)
    }
}

func Test_an_event_renders_its_kind_by_name_and_its_roster_indices_as_numbers(t *testing.T) {
    var event Event

    event.Words[0] = 4
    event.Words[3] = 6
    event.Words[7] = uint64(math.MaxUint64) - 4

    rendered, err := event.Render()
    if err != nil {
        t.Fatal(err)
    }

    if !strings.HasPrefix(rendered, "kind=kill delay_ns=0 duration_ns=0 target=6 ") {
        t.Fatalf("the render began %q", rendered)
    }

    if !strings.Contains(rendered, " network_link=0 ") {
        t.Fatalf("the link index was lost in %q", rendered)
    }

    event.Words[3] = 17

    unlisted, err := event.Render()
    if err != nil {
        t.Fatal(err)
    }

    if !strings.Contains(unlisted, " target=17 ") {
        t.Fatalf("an index past every name table was refused or renamed in %q", unlisted)
    }

    if !strings.Contains(rendered, " clock_jump_ns=-5 ") {
        t.Fatalf("the signed field was lost in %q", rendered)
    }

    event.Words[0] = uint64(len(kinds()))

    if _, err := event.Render(); err == nil {
        t.Fatal("an unknown kind rendered")
    }
}

func Test_a_step_line_carries_the_workload_message(t *testing.T) {
    line := line_build("CELESTE STEP ", "", " place\torder ", "")

    if line != "CELESTE STEP place order" {
        t.Fatalf("the line was %q", line)
    }
}
