Pod::Spec.new do |s|
  s.name           = 'HarmonyPlayer'
  s.version        = '1.0.0'
  s.summary        = 'SFBAudioEngine-based audio player for Harmony'
  s.homepage       = 'https://github.com/Liit95/harmony-player'
  s.license        = 'MIT'
  s.author         = 'Liit95'
  s.source         = { http: "https://github.com/Liit95/harmony-player/archive/refs/tags/#{s.version}.tar.gz" }
  s.platform       = :ios, '16.0'
  s.swift_version  = '5.9'
  s.static_framework = true

  s.source_files = 'ios/**/*.{h,m,swift}'
  s.private_header_files = 'ios/DeezerInputSource.h', 'ios/ProgressiveInputSource.h', 'ios/HarmonyDecoderFactory.h'
  s.dependency 'ExpoModulesCore'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_COMPILATION_MODE' => 'wholemodule',
    'FRAMEWORK_SEARCH_PATHS' => '$(inherited) "$(BUILT_PRODUCTS_DIR)/PackageFrameworks"',
    'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES' => 'YES',
  }
end
