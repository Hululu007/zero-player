#include "reader_fonts.h"

#include <windows.h>
#include <dwrite.h>
#include <wrl/client.h>
#include <string>

namespace {
using Microsoft::WRL::ComPtr;
flutter::EncodableList SystemFamilies() {
  flutter::EncodableList result;
  ComPtr<IDWriteFactory> factory;
  if (FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED,
      __uuidof(IDWriteFactory), reinterpret_cast<IUnknown**>(factory.GetAddressOf())))) {
    return result;
  }
  ComPtr<IDWriteFontCollection> fonts;
  if (FAILED(factory->GetSystemFontCollection(&fonts, TRUE))) return result;
  for (UINT32 i = 0; i < fonts->GetFontFamilyCount(); ++i) {
    ComPtr<IDWriteFontFamily> family;
    ComPtr<IDWriteLocalizedStrings> names;
    if (FAILED(fonts->GetFontFamily(i, &family)) ||
        FAILED(family->GetFamilyNames(&names)) || names->GetCount() == 0) continue;
    UINT32 index = 0;
    BOOL exists = FALSE;
    names->FindLocaleName(L"zh-cn", &index, &exists);
    if (!exists) names->FindLocaleName(L"en-us", &index, &exists);
    if (!exists) index = 0;
    UINT32 length = 0;
    if (FAILED(names->GetStringLength(index, &length)) || length > 256) continue;
    std::wstring wide(length + 1, L'\0');
    if (FAILED(names->GetString(index, wide.data(), length + 1))) continue;
    const int size = WideCharToMultiByte(CP_UTF8, 0, wide.data(),
        static_cast<int>(length), nullptr, 0, nullptr, nullptr);
    if (size <= 0) continue;
    std::string name(size, '\0');
    WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(length),
        name.data(), size, nullptr, nullptr);
    result.emplace_back(name);
  }
  return result;
}
}  // namespace

ReaderFonts::ReaderFonts(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "zero_player/reader_fonts", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() == "systemFamilies") {
      result->Success(flutter::EncodableValue(SystemFamilies()));
    } else {
      result->NotImplemented();
    }
  });
}
ReaderFonts::~ReaderFonts() { channel_->SetMethodCallHandler(nullptr); }
