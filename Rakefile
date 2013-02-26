$:.unshift "lib"

task :default => [:test]

$gem_name = "redis-em-mutex"

namespace :test do

  task :all => [:pure, :script]

  desc "Run specs against auto-detected handler"
  task :auto do
    Dir["spec/#{$gem_name}-*.rb"].each do |spec|
      sh({'REDIS_EM_MUTEX_HANDLER' => nil}, "rspec #{spec}")
    end
  end

  desc "Run specs against pure handler"
  task :pure do
    Dir["spec/#{$gem_name}-*.rb"].each do |spec|
      sh({'REDIS_EM_MUTEX_HANDLER' => 'pure'}, "rspec #{spec}")
    end
  end

  desc "Run specs against script handler"
  task :script do
    Dir["spec/#{$gem_name}-*.rb"].each do |spec|
      sh({'REDIS_EM_MUTEX_HANDLER' => 'script'}, "rspec #{spec}")
    end
  end
end

desc "Run all specs"
task :test => [:'test:all']

desc "Run stress test WARNING: flushes database on redis-server"
task :stress do
  sh "test/stress.rb"
end

desc "Build the gem"
task :gem do
  sh "gem build #$gem_name.gemspec"
end

desc "Install the library at local machnie"
task :install => :gem do 
  sh "gem install #$gem_name -l"
end

desc "Uninstall the library from local machnie"
task :uninstall do
  sh "gem uninstall #$gem_name"
end

desc "Clean"
task :clean do
  sh "rm #$gem_name*.gem"
end

desc "Documentation"
task :doc do
  sh "yardoc - README.md BENCHMARK.md"
end
