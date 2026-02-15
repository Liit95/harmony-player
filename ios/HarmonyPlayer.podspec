Pod::Spec.new do |s|
  s.name           = 'HarmonyPlayer'
  s.version        = '2.0.0'
  s.summary        = 'SFBAudioEngine-based audio player for Harmony'
  s.homepage       = 'https://github.com/Liit95/harmony-player'
  s.license        = 'MIT'
  s.author         = 'Liit95'
  s.source         = { http: "https://github.com/Liit95/harmony-player/archive/refs/tags/#{s.version}.tar.gz" }
  s.platform       = :ios, '16.0'
  s.swift_version  = '5.9'
  s.static_framework = true

  # Download SFBAudioEngine sources + binary XCFramework dependencies during pod install
  s.prepare_command = <<-SCRIPT
    set -e
    mkdir -p vendor

    # SFBAudioEngine source (CSFBAudioEngine + SFBAudioEngine)
    curl -sL https://github.com/sbooth/SFBAudioEngine/archive/refs/tags/0.12.0.tar.gz | tar xz -C vendor
    mv vendor/SFBAudioEngine-0.12.0 vendor/SFBAudioEngine

    # Source dependencies
    curl -sL https://github.com/sbooth/AVFAudioExtensions/archive/refs/tags/0.5.0.tar.gz | tar xz -C vendor
    curl -sL https://github.com/sbooth/CXXAudioRingBuffer/archive/refs/tags/0.1.0.tar.gz | tar xz -C vendor
    curl -sL https://github.com/sbooth/CXXDispatchSemaphore/archive/refs/tags/0.4.0.tar.gz | tar xz -C vendor
    curl -sL https://github.com/sbooth/CXXRingBuffer/archive/refs/tags/0.6.0.tar.gz | tar xz -C vendor
    curl -sL https://github.com/sbooth/CXXUnfairLock/archive/refs/tags/0.3.0.tar.gz | tar xz -C vendor
    curl -sL https://github.com/sbooth/CDUMB/archive/refs/tags/2.0.3.tar.gz | tar xz -C vendor
    curl -sL https://github.com/sbooth/CXXMonkeysAudio/archive/refs/tags/12.13.0.tar.gz | tar xz -C vendor
    curl -sL https://github.com/sbooth/CXXTagLib/archive/refs/tags/2.1.1.tar.gz | tar xz -C vendor
    curl -sL https://github.com/sbooth/CSpeex/archive/refs/tags/1.2.1.tar.gz | tar xz -C vendor

    # Binary XCFramework dependencies
    mkdir -p Frameworks
    for url in \
      "https://github.com/sbooth/ogg-binary-xcframework/releases/download/0.1.3/ogg.xcframework.zip" \
      "https://github.com/sbooth/flac-binary-xcframework/releases/download/0.2.0/FLAC.xcframework.zip" \
      "https://github.com/sbooth/lame-binary-xcframework/releases/download/0.1.2/lame.xcframework.zip" \
      "https://github.com/sbooth/mpg123-binary-xcframework/releases/download/0.3.1/mpg123.xcframework.zip" \
      "https://github.com/sbooth/mpc-binary-xcframework/releases/download/0.1.2/mpc.xcframework.zip" \
      "https://github.com/sbooth/vorbis-binary-xcframework/releases/download/0.1.2/vorbis.xcframework.zip" \
      "https://github.com/sbooth/opus-binary-xcframework/releases/download/0.3.0/opus.xcframework.zip" \
      "https://github.com/sbooth/sndfile-binary-xcframework/releases/download/0.1.2/sndfile.xcframework.zip" \
      "https://github.com/sbooth/wavpack-binary-xcframework/releases/download/0.2.0/wavpack.xcframework.zip" \
      "https://github.com/sbooth/tta-cpp-binary-xcframework/releases/download/0.1.2/tta-cpp.xcframework.zip"
    do
      curl -sL "$url" -o /tmp/fw.zip && unzip -qo /tmp/fw.zip -d Frameworks && rm /tmp/fw.zip
    done
  SCRIPT

  # HarmonyPlayer sources
  s.source_files = [
    '**/*.{h,m,swift}',
    'vendor/SFBAudioEngine/Sources/CSFBAudioEngine/**/*.{h,m,c,cpp}',
    'vendor/SFBAudioEngine/Sources/SFBAudioEngine/**/*.swift',
    'vendor/AVFAudioExtensions-0.5.0/Sources/**/*.swift',
    'vendor/CXXAudioRingBuffer-0.1.0/Sources/**/*.{h,cpp}',
    'vendor/CXXDispatchSemaphore-0.4.0/Sources/**/*.{h,cpp}',
    'vendor/CXXRingBuffer-0.6.0/Sources/**/*.{h,cpp}',
    'vendor/CXXUnfairLock-0.3.0/Sources/**/*.{h,cpp}',
    'vendor/CDUMB-2.0.3/Sources/**/*.{h,c}',
    'vendor/CXXMonkeysAudio-12.13.0/Sources/**/*.{h,cpp}',
    'vendor/CXXTagLib-2.1.1/Sources/**/*.{h,cpp}',
    'vendor/CSpeex-1.2.1/Sources/**/*.{h,c}',
  ]

  s.exclude_files = 'vendor/**/Package.swift', 'vendor/**/Tests/**', 'vendor/**/Extra/**'

  s.private_header_files = 'DeezerInputSource.h', 'ProgressiveInputSource.h', 'HarmonyDecoderFactory.h'

  s.vendored_frameworks = 'Frameworks/**/*.xcframework'

  s.dependency 'ExpoModulesCore'

  s.frameworks = 'Accelerate', 'AudioToolbox', 'AVFAudio', 'ImageIO', 'UniformTypeIdentifiers'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_COMPILATION_MODE' => 'wholemodule',
    'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
    'GCC_C_LANGUAGE_STANDARD' => 'c11',
    'HEADER_SEARCH_PATHS' => [
      '$(inherited)',
      '"${PODS_TARGET_SRCROOT}/vendor/SFBAudioEngine/Sources/CSFBAudioEngine/include/SFBAudioEngine"',
      '"${PODS_TARGET_SRCROOT}/vendor/SFBAudioEngine/Sources/CSFBAudioEngine/include"',
      '"${PODS_TARGET_SRCROOT}/vendor/SFBAudioEngine/Sources/CSFBAudioEngine/Input"',
      '"${PODS_TARGET_SRCROOT}/vendor/SFBAudioEngine/Sources/CSFBAudioEngine/Decoders"',
      '"${PODS_TARGET_SRCROOT}/vendor/SFBAudioEngine/Sources/CSFBAudioEngine/Player"',
      '"${PODS_TARGET_SRCROOT}/vendor/SFBAudioEngine/Sources/CSFBAudioEngine/Output"',
      '"${PODS_TARGET_SRCROOT}/vendor/SFBAudioEngine/Sources/CSFBAudioEngine/Encoders"',
      '"${PODS_TARGET_SRCROOT}/vendor/SFBAudioEngine/Sources/CSFBAudioEngine/Utilities"',
      '"${PODS_TARGET_SRCROOT}/vendor/SFBAudioEngine/Sources/CSFBAudioEngine/Analysis"',
      '"${PODS_TARGET_SRCROOT}/vendor/SFBAudioEngine/Sources/CSFBAudioEngine/Metadata"',
      '"${PODS_TARGET_SRCROOT}/vendor/SFBAudioEngine/Sources/CSFBAudioEngine/Conversion"',
    ].join(' '),
  }
end
