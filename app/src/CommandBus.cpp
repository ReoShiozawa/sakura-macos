// Copyright (c) 2026 Unofficial Sakura macOS port contributors
// SPDX-License-Identifier: Zlib

#include "sakura/app/CommandBus.h"

namespace sakura::app {

bool CommandBus::registerHandler(FunctionCode code,
                                 std::unique_ptr<ICommandHandler> handler) {
  if (!handler || handlers_.contains(code)) {
    return false;
  }
  handlers_.emplace(code, std::move(handler));
  return true;
}

CommandResult CommandBus::execute(FunctionCode code, CommandContext& context,
                                  const CommandArgs& args) const {
  const auto found = handlers_.find(code);
  if (found == handlers_.end()) {
    return CommandResult::unhandled();
  }
  return found->second->execute(context, args);
}

bool CommandBus::hasHandler(FunctionCode code) const noexcept {
  return handlers_.contains(code);
}

}  // namespace sakura::app
