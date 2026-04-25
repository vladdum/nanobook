#include <refbook/order_pool.h>

#include <stdexcept>

namespace refbook {

OrderPool::OrderPool(std::size_t capacity) : records_(capacity) {
  // Build the initial free list: record[i].next_slot = i + 1, last -> kNullSlot.
  for (std::size_t i = 0; i + 1 < capacity; ++i) {
    records_[i].next_slot = static_cast<uint32_t>(i + 1);
  }
  if (capacity > 0) {
    records_[capacity - 1].next_slot = kNullSlot;
    free_head_ = 0;
  }
}

uint32_t OrderPool::allocate() {
  if (free_head_ == kNullSlot) {
    throw std::runtime_error("OrderPool: pool exhausted");
  }
  uint32_t slot = free_head_;
  free_head_ = records_[slot].next_slot;
  records_[slot] = OrderRecord{};
  records_[slot].flags = 0x01;  // active bit
  ++active_;
  return slot;
}

void OrderPool::release(uint32_t slot) {
  records_[slot] = OrderRecord{};
  records_[slot].next_slot = free_head_;
  free_head_ = slot;
  --active_;
}

OrderRecord& OrderPool::at(uint32_t slot) {
  return records_[slot];
}

const OrderRecord& OrderPool::at(uint32_t slot) const {
  return records_[slot];
}

}  // namespace refbook
