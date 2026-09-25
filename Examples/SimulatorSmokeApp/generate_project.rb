#!/usr/bin/env ruby
require 'xcodeproj'
require 'fileutils'

root = File.expand_path(__dir__)

feature_root = File.join(root, 'FeatureProject')
feature_project_path = File.join(
  feature_root,
  'SmokeFeature.xcodeproj'
)
feature_generated = File.join(
  feature_root,
  'Generated'
)
FileUtils.mkdir_p(feature_root)
FileUtils.rm_rf(feature_project_path)
FileUtils.rm_rf(feature_generated)
FileUtils.mkdir_p(feature_generated)

feature_project = Xcodeproj::Project.new(
  feature_project_path
)
feature_target = feature_project.new_target(
  :framework,
  'SmokeFeature',
  :ios,
  '16.0'
)

feature_sources = feature_project.main_group
  .new_group('Sources', 'Sources')
feature_source = feature_sources.new_file(
  'SmokeFeature.swift'
)
feature_target.source_build_phase
  .add_file_reference(feature_source)

generated_group = feature_project.main_group
  .new_group('Generated', 'Generated')
64.times do |index|
  name = format('Filler%03d.swift', index)
  File.write(
    File.join(feature_generated, name),
    "internal struct SmokeFeatureFiller#{index} { let value = #{index} }\n"
  )
  ref = generated_group.new_file(name)
  feature_target.source_build_phase
    .add_file_reference(ref)
end

feature_target.build_configurations.each do |config|
  settings = config.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] =
    'dev.agentinjection.smoke.feature'
  settings['PRODUCT_NAME'] = 'SmokeFeature'
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

feature_project.save
puts "Generated #{feature_project_path}"

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
  if %w[main.m AppDelegate.m SmokeApplication.m SmokeObjCHelper.m SmokeViewController.swift].include?(name)
    target.source_build_phase.add_file_reference(ref)
  end
end

integration = project.main_group.new_group('AgentInjectionIntegration')
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

info = project.main_group.new_file('Info.plist')

target.build_configurations.each do |config|
  settings = config.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'dev.agentinjection.smoke'
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
  settings['OTHER_LDFLAGS'] = [
    '$(inherited)',
    '-Xlinker',
    '-interposable',
    '-framework',
    'SmokeFeature'
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
puts "Generated #{project_path}"
