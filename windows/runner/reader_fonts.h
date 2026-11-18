#ifndef RUNNER_READER_FONTS_H_
#define RUNNER_READER_FONTS_H_

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <memory>

class ReaderFonts {
 public:
  explicit ReaderFonts(flutter::BinaryMessenger* messenger);
  ~ReaderFonts();
 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};
#endif
