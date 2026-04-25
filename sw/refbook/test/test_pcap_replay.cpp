// Placeholder for the original M02 exit criterion #2: "Same trading day replayed
// on two different hosts produces byte-identical TOB stream."
//
// Blocked: NASDAQ TotalView ITCH data is unavailable at M02 (deferred from M01).
// This file is SKIPPED and will be lit up the first month real pcaps are
// available. No structural changes required — only replace GTEST_SKIP() below
// with real pcap wiring.

#include <gtest/gtest.h>

TEST(PcapReplay, DISABLED_ThreePinnedDaysByteIdentical) {
  GTEST_SKIP() << "deferred: requires NASDAQ TVITCH 5.0 subscription; "
                  "carry-over from M02 retrospective";
}
