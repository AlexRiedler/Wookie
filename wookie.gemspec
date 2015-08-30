# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'wookie/version'

Gem::Specification.new do |spec|
  spec.name          = "wookie"
  spec.version       = Wookie::VERSION
  spec.authors       = ["Alex Riedler"]
  spec.email         = ["alexriedler@gmail.com"]

  spec.summary       = %q{A simple worker implementation for Bunny.}
  spec.description   = %q{Sneakers caused a fair bit of assumptions about Bunny that I think can be resolved.}
  spec.homepage      = "riedler.ca"

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.bindir        = "bin"
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
  spec.test_files    = gem.files.grep(/^(test|spec|features)\//)

  spec.add_dependency 'serverengine', '~> 1.5.10'
  spec.add_dependency 'bunny', '~> 2.1.0'
  spec.add_dependency 'thread', '~> 0.2.2'
  spec.add_dependency 'thor'

  spec.add_development_dependency "bundler", "~> 1.10"
  spec.add_development_dependency "rake", "~> 10.0"
  spec.add_development_dependency "rspec"
end
