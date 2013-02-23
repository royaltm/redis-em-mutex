$:.unshift "lib"

task :default => [:test]

$gem_name = "redis-em-mutex"

desc "Run spec tests"
namespace :test do

  task :all => [:auto, :pure, :script]

  task :auto do
    Dir["spec/#{$gem_name}-*.rb"].each do |spec|
      sh({'REDIS_EM_MUTEX_HANDLER' => nil}, "rspec #{spec}")
    end
  end

  task :pure do
    Dir["spec/#{$gem_name}-*.rb"].each do |spec|
      sh({'REDIS_EM_MUTEX_HANDLER' => 'pure'}, "rspec #{spec}")
    end
  end

  task :script do
    Dir["spec/#{$gem_name}-*.rb"].each do |spec|
      sh({'REDIS_EM_MUTEX_HANDLER' => 'script'}, "rspec #{spec}")
    end
  end
end

task :test => [:'test:all']

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
  sh "yardoc"
end
