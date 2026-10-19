#ifndef RUNNER_DIRECTORY_PICKER_H_
#define RUNNER_DIRECTORY_PICKER_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

class DirectoryPicker {
 public:
  DirectoryPicker(HWND owner, flutter::BinaryMessenger* messenger);

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_DIRECTORY_PICKER_H_
