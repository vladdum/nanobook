#include <cstddef>
#include <cstdint>
#include <refbook/book_event.h>

#include <gtest/gtest.h>

using refbook::BookEvent;
using refbook::EventType;

TEST(BookEvent, SizeIs32Bytes) {
  EXPECT_EQ(sizeof(BookEvent), 32u);
}

TEST(BookEvent, FieldOffsetsStable) {
  EXPECT_EQ(offsetof(BookEvent, type),       0x00u);
  EXPECT_EQ(offsetof(BookEvent, side),       0x01u);
  EXPECT_EQ(offsetof(BookEvent, symbol_id),  0x02u);
  EXPECT_EQ(offsetof(BookEvent, price),      0x04u);
  EXPECT_EQ(offsetof(BookEvent, shares),     0x08u);
  EXPECT_EQ(offsetof(BookEvent, order_id),   0x10u);
  EXPECT_EQ(offsetof(BookEvent, ingress_ts), 0x18u);
}

TEST(BookEvent, TypeEnumValuesStable) {
  EXPECT_EQ(static_cast<uint8_t>(EventType::Add),            0u);
  EXPECT_EQ(static_cast<uint8_t>(EventType::Cancel),         1u);
  EXPECT_EQ(static_cast<uint8_t>(EventType::Delete),         2u);
  EXPECT_EQ(static_cast<uint8_t>(EventType::Exec),           3u);
  EXPECT_EQ(static_cast<uint8_t>(EventType::ExecPx),         4u);
}
