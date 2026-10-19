#ifndef RUNNER_ADMINISTRATOR_LAUNCH_H_
#define RUNNER_ADMINISTRATOR_LAUNCH_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

class AdministratorLaunch {
 public:
  AdministratorLaunch(HWND owner, flutter::BinaryMessenger* messenger);
 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_ADMINISTRATOR_LAUNCH_H_
