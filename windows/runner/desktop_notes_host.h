#ifndef RUNNER_DESKTOP_NOTES_HOST_H_
#define RUNNER_DESKTOP_NOTES_HOST_H_
#include <windows.h>
#include <flutter/binary_messenger.h>
#include <functional>
#include <memory>

class DesktopNotesHost {
 public:
  DesktopNotesHost(flutter::BinaryMessenger* messenger,
                   std::function<bool()> blocked);
  ~DesktopNotesHost();
  bool HandleMessage(const MSG& message);
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
#endif
