#include <cstddef>
#include <cstdint>
#include <refbook/tob_delta.h>

#include <gtest/gtest.h>

using refbook::TobDelta;

TEST(TobDelta, SizeIs32Bytes) {
  EXPECT_EQ(sizeof(TobDelta), 32u);
}

TEST(TobDelta, AlignmentIs1) {
  EXPECT_EQ(alignof(TobDelta), 1u);
}

TEST(TobDelta, FieldOffsetsMatchSpec) {
  EXPECT_EQ(offsetof(TobDelta, ingress_ts),     0x00u);
  EXPECT_EQ(offsetof(TobDelta, emit_ts),        0x08u);
  EXPECT_EQ(offsetof(TobDelta, symbol_id),      0x10u);
  EXPECT_EQ(offsetof(TobDelta, side),           0x12u);
  EXPECT_EQ(offsetof(TobDelta, reason),         0x13u);
  EXPECT_EQ(offsetof(TobDelta, new_best_price), 0x14u);
  EXPECT_EQ(offsetof(TobDelta, new_best_size),  0x18u);
  EXPECT_EQ(offsetof(TobDelta, flags),          0x1Cu);
}

TEST(TobDelta, ReasonEnumValuesStable) {
  EXPECT_EQ(static_cast<uint8_t>(refbook::TobReason::Add),           0u);
  EXPECT_EQ(static_cast<uint8_t>(refbook::TobReason::Cancel),        1u);
  EXPECT_EQ(static_cast<uint8_t>(refbook::TobReason::Delete),        2u);
  EXPECT_EQ(static_cast<uint8_t>(refbook::TobReason::Exec),          3u);
  EXPECT_EQ(static_cast<uint8_t>(refbook::TobReason::ExecPx),        4u);
}
