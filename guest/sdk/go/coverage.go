package dst

/*
#cgo CFLAGS: -I${SRCDIR}/../c
#include "coverage.c"
*/
import "C"

func Coverage_scan() {
    C.dst_coverage_scan()
}
