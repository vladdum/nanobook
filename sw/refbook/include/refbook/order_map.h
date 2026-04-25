// SPDX-License-Identifier: Apache-2.0
// Hash table from order_id (u64) to slot index (u32).
// Behavioral component — collision handling is internal and not observable at TOB.
#pragma once

#include <cstdint>
#include <optional>
#include <unordered_map>

namespace refbook {

class OrderMap {
 public:
  // Returns false if the order_id was already present.
  bool insert(uint64_t order_id, uint32_t slot);

  // Returns nullopt if absent.
  std::optional<uint32_t> lookup(uint64_t order_id) const;

  // Returns false if the order_id was absent.
  bool erase(uint64_t order_id);

  std::size_t size() const { return table_.size(); }
  void clear() { table_.clear(); }

 private:
  std::unordered_map<uint64_t, uint32_t> table_;
};

inline bool OrderMap::insert(uint64_t order_id, uint32_t slot) {
  auto [_, ok] = table_.try_emplace(order_id, slot);
  return ok;
}

inline std::optional<uint32_t> OrderMap::lookup(uint64_t order_id) const {
  auto it = table_.find(order_id);
  if (it == table_.end()) return std::nullopt;
  return it->second;
}

inline bool OrderMap::erase(uint64_t order_id) {
  return table_.erase(order_id) > 0;
}

}  // namespace refbook
