package celeste

/*
#cgo CFLAGS: -I${SRCDIR}/../c
#include "coverage.c"
*/
import "C"

func Coverage_scan() {
    C.celeste_coverage_scan()
}
