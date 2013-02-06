$:.unshift "lib"
require 'redis/em-mutex/version'

Gem::Specification.new do |s|
  s.name = "redis-em-mutex"
  s.version = Redis::EM::Mutex::VERSION
  s.required_ruby_version = ">= 1.9.1"
  s.date = "#{Time.now.strftime("%Y-%m-%d")}"
  s.summary = "Cross server-process-fiber EventMachine + Redis based semaphore"
  s.email = "rafal@yeondir.com"
  s.homepage = "http://github.com/royaltm/redis-em-mutex"
  s.require_path = "lib"
  s.description = "Cross server-process-fiber EventMachine + Redis based semaphore with many features"
  s.authors = ["Rafal Michalski"]
  s.files = `git ls-files`.split("\n") - ['.gitignore']
  s.test_files = Dir.glob("spec/**/*")
  s.rdoc_options << "--title" << "redis-em-mutex" <<
    "--main" << "README.md"
  s.has_rdoc = true
  s.extra_rdoc_files = ["README.md"]
  s.requirements << "Redis server 2.4+"
  s.add_runtime_dependency "redis", ">= 3.0.1"
  s.add_runtime_dependency "hiredis", "~> 0.4.5"
  s.add_runtime_dependency "eventmachine", ">= 1.0.0.beta.1"
  s.add_development_dependency "rspec", "~> 2.8.0"
  s.add_development_dependency "eventmachine", "~> 1.0.0"
  s.add_development_dependency "em-synchrony", "~> 1.0.0"
end
