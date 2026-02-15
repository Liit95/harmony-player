Pod::Spec.new do |s|
  s.name           = 'HarmonyPlayer'
  s.version        = '1.0.0'
  s.summary        = 'SFBAudioEngine-based audio player for Harmony'
  s.homepage       = 'https://github.com/example'
  s.license        = 'MIT'
  s.author         = 'lit'
  s.source         = { git: '' }
  s.platform       = :ios, '16.0'
  s.swift_version  = '5.9'
  s.static_framework = true

  s.source_files = '**/*.{h,m,swift}'
  s.dependency 'ExpoModulesCore'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_COMPILATION_MODE' => 'wholemodule',
    # Allow importing SFBAudioEngine from SPM (added to project by config plugin)
    'FRAMEWORK_SEARCH_PATHS' => '$(inherited) "$(BUILT_PRODUCTS_DIR)/PackageFrameworks"',
    'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES' => 'YES',
  }
end
