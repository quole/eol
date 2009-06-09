require 'selenium/rake/tasks'

Selenium::Rake::RemoteControlStartTask.new do |rc|
  rc.port = 4444
  rc.timeout_in_seconds = 3 * 60
  rc.background = true
  rc.wait_until_up_and_running = true
  rc.additional_args << "-singleWindow"
end

Selenium::Rake::RemoteControlStopTask.new do |rc|
  rc.host = "localhost"
  rc.port = 4444
  rc.timeout_in_seconds = 3 * 60
end

require 'spec/rake/spectask'
desc 'Run acceptance tests for web application'
Spec::Rake::SpecTask.new(:'test:acceptance:web') do |t|
  t.spec_opts << '--color'
  t.spec_opts << "--require 'rubygems,selenium/rspec/reporting/selenium_test_report_formatter'"
  t.spec_opts << "--format=Selenium::RSpec::SeleniumTestReportFormatter:./tmp/acceptance_tests_report.html"
  t.spec_opts << "--format=progress"                
  t.verbose = true
  t.spec_files = FileList['spec/selenium/*_spec.rb']
end
