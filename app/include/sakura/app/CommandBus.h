// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#ifndef SAKURA_APP_COMMAND_BUS_H_
#define SAKURA_APP_COMMAND_BUS_H_

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <unordered_map>
#include <utility>

#include "sakura/app/DocumentSession.h"

namespace sakura::app {

// The numeric value is intentionally compatible with the existing
// EFunctionCode IDs.  The portable layer does not depend on the generated
// Win32 header that currently declares that enum.
using FunctionCode = std::int32_t;

enum class CommandSource {
  menu,
  keyboard,
  macro,
  toolbar,
  programmatic,
};

struct CommandContext {
  DocumentSession* document{};
  CommandSource source{CommandSource::programmatic};
};

struct CommandArgs {
  std::optional<core::TextRange> range;
  core::SakuraString text;
};

struct CommandResult {
  bool handled{};
  std::string error;

  [[nodiscard]] bool succeeded() const noexcept {
    return handled && error.empty();
  }

  [[nodiscard]] static CommandResult success() { return {true, {}}; }
  [[nodiscard]] static CommandResult unhandled() { return {false, {}}; }
  [[nodiscard]] static CommandResult failure(std::string message) {
    return {true, std::move(message)};
  }
};

class ICommandHandler {
 public:
  virtual ~ICommandHandler() = default;
  virtual CommandResult execute(CommandContext& context,
                                const CommandArgs& args) = 0;
};

class CommandBus {
 public:
  // Returns false when the function code is already registered or the handler
  // is null.  Stable function IDs therefore cannot be replaced accidentally.
  bool registerHandler(FunctionCode code, std::unique_ptr<ICommandHandler> handler);
  [[nodiscard]] CommandResult execute(FunctionCode code, CommandContext& context,
                                      const CommandArgs& args = {}) const;
  [[nodiscard]] bool hasHandler(FunctionCode code) const noexcept;

 private:
  std::unordered_map<FunctionCode, std::unique_ptr<ICommandHandler>> handlers_;
};

}  // namespace sakura::app

#endif  // SAKURA_APP_COMMAND_BUS_H_
