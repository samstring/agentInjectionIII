#!/usr/bin/env ruby
require 'xcodeproj'
require 'fileutils'

root = File.expand_path(__dir__)

feature_project_count =
  Integer(ENV.fetch('SMOKE_FEATURE_PROJECT_COUNT', '6'))
swift_fillers_per_feature =
  Integer(ENV.fetch('SMOKE_SWIFT_FILLERS_PER_FEATURE', '160'))
objc_fillers_per_feature =
  Integer(ENV.fetch('SMOKE_OBJC_FILLERS_PER_FEATURE', '48'))
main_swift_fillers =
  Integer(ENV.fetch('SMOKE_MAIN_SWIFT_FILLERS', '160'))
main_objc_fillers =
  Integer(ENV.fetch('SMOKE_MAIN_OBJC_FILLERS', '80'))

unless (1..12).cover?(feature_project_count)
  raise "SMOKE_FEATURE_PROJECT_COUNT must be between 1 and 12"
end
unless (0..512).cover?(swift_fillers_per_feature)
  raise "SMOKE_SWIFT_FILLERS_PER_FEATURE must be between 0 and 512"
end
unless (0..256).cover?(objc_fillers_per_feature)
  raise "SMOKE_OBJC_FILLERS_PER_FEATURE must be between 0 and 256"
end
unless (0..1024).cover?(main_swift_fillers)
  raise "SMOKE_MAIN_SWIFT_FILLERS must be between 0 and 1024"
end
unless (0..512).cover?(main_objc_fillers)
  raise "SMOKE_MAIN_OBJC_FILLERS must be between 0 and 512"
end

feature_projects_root = File.join(root, 'FeatureProjects')
generated_root = File.join(root, 'Generated')
FileUtils.rm_rf(feature_projects_root)
FileUtils.rm_rf(generated_root)
FileUtils.mkdir_p(feature_projects_root)
FileUtils.mkdir_p(generated_root)

feature_specs = (1..feature_project_count).map do |index|
  suffix = format('%02d', index)
  module_name = "SmokeFeature#{suffix}"
  feature_root = File.join(
    feature_projects_root,
    "Feature#{suffix}"
  )
  source_dir = File.join(feature_root, 'Sources')
  swift_generated = File.join(
    feature_root,
    'GeneratedSwift'
  )
  objc_generated = File.join(
    feature_root,
    'GeneratedObjC'
  )
  project_path = File.join(
    feature_root,
    "#{module_name}.xcodeproj"
  )

  FileUtils.mkdir_p(source_dir)
  FileUtils.mkdir_p(swift_generated)
  FileUtils.mkdir_p(objc_generated)

  primary_name = "#{module_name}.swift"
  primary_path = File.join(source_dir, primary_name)
  File.write(
    primary_path,
    <<~SWIFT
      import Foundation

      public func smokeFeatureMessage#{suffix}() -> String {
          "FEATURE_#{suffix}_BEFORE"
      }
    SWIFT
  )

  project = Xcodeproj::Project.new(project_path)
  target = project.new_target(
    :framework,
    module_name,
    :ios,
    '16.0'
  )

  sources_group = project.main_group
    .new_group('Sources', 'Sources')
  primary_ref = sources_group.new_file(primary_name)
  target.source_build_phase.add_file_reference(primary_ref)

  swift_group = project.main_group
    .new_group('GeneratedSwift', 'GeneratedSwift')
  swift_fillers_per_feature.times do |filler_index|
    name = format('SwiftFiller%03d.swift', filler_index)
    File.write(
      File.join(swift_generated, name),
      "internal struct #{module_name}SwiftFiller#{filler_index} " \
      "{ let value = #{filler_index} }\n"
    )
    ref = swift_group.new_file(name)
    target.source_build_phase.add_file_reference(ref)
  end

  objc_group = project.main_group
    .new_group('GeneratedObjC', 'GeneratedObjC')
  objc_fillers_per_feature.times do |filler_index|
    stem = format('ObjCFiller%03d', filler_index)
    header_name = "#{stem}.h"
    implementation_name = "#{stem}.m"
    symbol =
      "smoke_feature_#{suffix}_objc_filler_" \
      "#{format('%03d', filler_index)}"

    File.write(
      File.join(objc_generated, header_name),
      <<~HEADER
        #import <Foundation/Foundation.h>

        FOUNDATION_EXPORT NSInteger #{symbol}(void);
      HEADER
    )
    File.write(
      File.join(objc_generated, implementation_name),
      <<~OBJC
        #import "#{header_name}"

        NSInteger #{symbol}(void) {
            return #{filler_index};
        }
      OBJC
    )

    objc_group.new_file(header_name)
    ref = objc_group.new_file(implementation_name)
    target.source_build_phase.add_file_reference(ref)
  end

  target.build_configurations.each do |config|
    settings = config.build_settings
    settings['PRODUCT_BUNDLE_IDENTIFIER'] =
      "dev.agentinjection.smoke.feature#{suffix}"
    settings['PRODUCT_NAME'] = module_name
    settings['SWIFT_VERSION'] = '5.0'
    settings['DEFINES_MODULE'] = 'YES'
    settings['GENERATE_INFOPLIST_FILE'] = 'YES'
    settings['SKIP_INSTALL'] = 'YES'
    settings['CODE_SIGNING_ALLOWED'] = 'NO'
    settings['SWIFT_OPTIMIZATION_LEVEL'] =
      config.name == 'Debug' ? '-Onone' : '-O'
    settings['DEBUG_INFORMATION_FORMAT'] = 'dwarf'
    settings['EMIT_FRONTEND_COMMAND_LINES'] = 'YES'
    settings['COMPILATION_CACHE_ENABLE_CACHING'] = 'NO'
    settings['OTHER_LDFLAGS'] = [
      '$(inherited)',
      '-Xlinker',
      '-interposable'
    ]
  end

  project.save
  puts(
    "Generated #{project_path} " \
    "(swift=#{swift_fillers_per_feature + 1}, " \
    "objc=#{objc_fillers_per_feature})"
  )

  {
    suffix: suffix,
    module: module_name,
    root: feature_root,
    project_path: project_path,
    primary_path: primary_path
  }
end

matrix_path = File.join(
  generated_root,
  'SmokeFeatureMatrix.swift'
)
matrix_lines = [
  'import Foundation'
]
feature_specs.each do |spec|
  matrix_lines << "import #{spec[:module]}"
end
matrix_lines << ''
matrix_lines << 'func smokeFeatureMessages() -> [(id: String, message: String)] {'
matrix_lines << '    ['
feature_specs.each do |spec|
  matrix_lines <<(
    "        (\"#{spec[:suffix]}\", " \
    "smokeFeatureMessage#{spec[:suffix]}()),"
  )
end
matrix_lines << '    ]'
matrix_lines << '}'
File.write(
  matrix_path,
  matrix_lines.join("\n") + "\n"
)

project_path = File.join(root, 'SimulatorSmokeApp.xcodeproj')
FileUtils.rm_rf(project_path)

project = Xcodeproj::Project.new(project_path)
target = project.new_target(
  :application,
  'SimulatorSmokeApp',
  :ios,
  '16.0'
)

sources = project.main_group.new_group('Sources', 'Sources')
%w[
  main.m
  AppDelegate.h
  AppDelegate.m
  SmokeApplication.h
  SmokeApplication.m
  SmokeObjCHelper.h
  SmokeObjCHelper.m
  SimulatorSmokeApp-Bridging-Header.h
  SmokeViewController.swift
].each do |name|
  ref = sources.new_file(name)
  if %w[
    main.m
    AppDelegate.m
    SmokeApplication.m
    SmokeObjCHelper.m
    SmokeViewController.swift
  ].include?(name)
    target.source_build_phase.add_file_reference(ref)
  end
end

generated = project.main_group.new_group(
  'Generated',
  'Generated'
)
matrix_ref = generated.new_file('SmokeFeatureMatrix.swift')
target.source_build_phase.add_file_reference(matrix_ref)

main_swift_dir = File.join(generated_root, 'MainSwift')
main_objc_dir = File.join(generated_root, 'MainObjC')
FileUtils.mkdir_p(main_swift_dir)
FileUtils.mkdir_p(main_objc_dir)

main_swift_group = generated.new_group('MainSwift', 'MainSwift')
main_swift_fillers.times do |index|
  name = format('LegacySwift%04d.swift', index)
  File.write(
    File.join(main_swift_dir, name),
    <<~SWIFT
      import Foundation

      internal struct LegacySwift#{format('%04d', index)} {
          let identifier: Int = #{index}
          func checksum() -> Int { identifier &* 31 &+ #{index % 17} }
      }
    SWIFT
  )
  ref = main_swift_group.new_file(name)
  target.source_build_phase.add_file_reference(ref)
end

main_objc_group = generated.new_group('MainObjC', 'MainObjC')
main_objc_fillers.times do |index|
  stem = format('LegacyObjC%04d', index)
  header_name = "#{stem}.h"
  implementation_name = "#{stem}.m"
  symbol = format('agent_legacy_objc_%04d', index)

  File.write(
    File.join(main_objc_dir, header_name),
    <<~HEADER
      #import <Foundation/Foundation.h>

      FOUNDATION_EXPORT NSInteger #{symbol}(NSInteger value);
    HEADER
  )
  File.write(
    File.join(main_objc_dir, implementation_name),
    <<~OBJC
      #import "#{header_name}"

      NSInteger #{symbol}(NSInteger value) {
          return value + #{index};
      }
    OBJC
  )

  main_objc_group.new_file(header_name)
  ref = main_objc_group.new_file(implementation_name)
  target.source_build_phase.add_file_reference(ref)
end

integration = project.main_group.new_group(
  'AgentInjectionIntegration'
)
%w[
  AgentInjectionBootstrap.m
  AgentTraceBridge.m
].each do |name|
  ref = integration.new_file("../../Integration/#{name}")
  target.source_build_phase.add_file_reference(ref)
end
%w[
  AgentInjectionBootstrap.h
  AgentTraceBridge.h
].each do |name|
  integration.new_file("../../Integration/#{name}")
end

project.main_group.new_file('Info.plist')

target.build_configurations.each do |config|
  settings = config.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] =
    'dev.agentinjection.smoke'
  settings['PRODUCT_NAME'] = 'SimulatorSmokeApp'
  settings['INFOPLIST_FILE'] = 'Info.plist'
  settings['SWIFT_VERSION'] = '5.0'
  settings['SWIFT_OBJC_BRIDGING_HEADER'] =
    'Sources/SimulatorSmokeApp-Bridging-Header.h'
  settings['CLANG_ENABLE_MODULES'] = 'YES'
  settings['ENABLE_TESTABILITY'] = 'YES'
  settings['TARGETED_DEVICE_FAMILY'] = '1'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['CODE_SIGNING_ALLOWED'] = 'NO'
  settings['SWIFT_OPTIMIZATION_LEVEL'] =
    config.name == 'Debug' ? '-Onone' : '-O'
  settings['DEBUG_INFORMATION_FORMAT'] = 'dwarf'
  settings['EMIT_FRONTEND_COMMAND_LINES'] = 'YES'
  settings['COMPILATION_CACHE_ENABLE_CACHING'] = 'NO'
  settings['HEADER_SEARCH_PATHS'] = [
    '$(inherited)',
    '$(SRCROOT)/../../Integration'
  ]
  settings['FRAMEWORK_SEARCH_PATHS'] = [
    '$(inherited)',
    '$(BUILT_PRODUCTS_DIR)'
  ]
  settings['LD_RUNPATH_SEARCH_PATHS'] = [
    '$(inherited)',
    '@executable_path/Frameworks'
  ]

  framework_flags = feature_specs.flat_map do |spec|
    ['-framework', spec[:module]]
  end
  settings['OTHER_LDFLAGS'] = [
    '$(inherited)',
    '-Xlinker',
    '-interposable',
    *framework_flags
  ]
end

phase = target.new_shell_script_build_phase(
  'Embed agentInjectionIII Runtime'
)
phase.shell_script = <<~'SH'
  set -euo pipefail
  bash "$SRCROOT/../../scripts/embed-runtime.sh"
SH

project.save
puts(
  "Generated #{project_path} with " \
  "#{feature_project_count} feature project(s)"
)
feature_swift_total =
  feature_project_count * (swift_fillers_per_feature + 1)
feature_objc_total =
  feature_project_count * objc_fillers_per_feature
app_swift_total = main_swift_fillers + 2
app_objc_total = main_objc_fillers + 6

puts(
  "Stress matrix: " \
  "feature Swift=#{feature_swift_total}, " \
  "feature ObjC=#{feature_objc_total}, " \
  "app Swift=#{app_swift_total}, " \
  "app ObjC=#{app_objc_total}, " \
  "total Swift=#{feature_swift_total + app_swift_total}, " \
  "ObjC implementations=#{feature_objc_total + app_objc_total}, " \
  "ObjC headers≈#{feature_objc_total + app_objc_total}"
)
