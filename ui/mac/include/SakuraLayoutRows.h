// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#ifndef SAKURA_LAYOUT_ROWS_H_
#define SAKURA_LAYOUT_ROWS_H_
#import <Foundation/Foundation.h>
#include "sakura/core/layout/IndexedLayout.h"

// Value-like indexed view, not a materialized table of absolute offsets. Copies
// retain the immutable layout root, including old row positions after an edit.
class SakuraLayoutRows {
 public:
  sakura::core::IndexedLayout index;
  [[nodiscard]] std::size_t size() const noexcept { return index.size(); }
  [[nodiscard]] bool empty() const noexcept { return index.empty(); }
  [[nodiscard]] NSRange operator[](std::size_t row) const {
    const auto range = index.row(row).range;
    return NSMakeRange(static_cast<NSUInteger>(range.location), static_cast<NSUInteger>(range.length));
  }
  [[nodiscard]] std::size_t logicalLine(std::size_t row) const { return index.row(row).visual.logicalLine; }
  struct Iterator {
    const SakuraLayoutRows* rows;
    std::size_t row;
    NSRange operator*() const { return (*rows)[row]; }
    Iterator& operator++() { ++row; return *this; }
    friend bool operator==(const Iterator&, const Iterator&) = default;
  };
  Iterator begin() const { return {this, 0}; }
  Iterator end() const { return {this, size()}; }
};
#endif
